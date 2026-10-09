# vLLM-SM75 0.1.7 自包含部署包（8 × Tesla T10）

在 **G292-Z20 / 8 × Tesla T10（sm_75，纯 PCIe、无 NVLink）** 上，把
**Qwen3.8-Flash-Next-W4A16-FP8PLE** 这个档（TP8＋EP、256K 上下文、FP8 KV、QSA 全开、无 MTP）
从"能跑"做到"跑满"。对应上游 vLLM-SM75 **0.1.7-beta**。

每一步都写了**怎么算成功**，不满足就停在那一步。全程照做约 20–40 分钟（大头是模型加载）。

**上游项目**：<https://github.com/fishensw/VLLM-SM75>（Apache-2.0）——一个 Turing（sm_75）专用 vLLM 分支，
整合 FlashInfer 0.6.18（PR #3526）与 SM75 后端门槛补丁（PR #47949），持续同步 vLLM 主线。
**本包不是它的 fork，也不含它的源码树**：本包只是这台机（8 × T10）上的部署脚本、一层镜像补丁与一层自维护回填，
构建时要你自己把那份源码树指过去（`SM75_SRC=`）。署名与授权逐条见 `NOTICE`。

---

## 1. 有什么效果

同一台机、同一个档、同一把尺（Ultra 控制台自带「模型测试」，并发 1、超时 30 s），
差别只是镜像多一层 PCIe-IPC 回填 ＋ 档里多一个环境变量：

| 指标 | 装之前 | 装之后 | 变化 |
|---|---|---|---|
| 每 token 步时 ITL | 22.89–23.25 ms | **17.22–17.61 ms** | 每步省 ≈5.5 ms |
| 输出 tok/s | 43.15–43.95 | **57.03–58.36** | **＋30.5%～＋33.1%**（逐档配对） |
| 预填充 tok/s、TTFT | — | — | 1% 以内（噪声） |

实测截图（生产档，九个提示词长度 512→131072，2026-10-07 14:3x）：

![生产档 PCIe-IPC：ITL 17.22–17.61 ms、输出 57.03–58.36 tok/s、预填充 2405.74–3117.93 tok/s](docs/bench/20261007-pcieipc-production.png)

装之前那批（后端 FIREFLY_AR，五个长度）：[`docs/bench/20261007-baseline-firefly-ar.png`](docs/bench/20261007-baseline-firefly-ar.png)

用官方随包尺子复核过 8K 档：decode 44.55 → **58.01**（＋30.2%），`passed=true`、零抢占、零缓存命中、无投机。
完整数据与判读：`docs/实测-面板测速对照-v1.md`。
**这些数字只在"8 × T10 ＋ sm_75 ＋ @150 W ＋ 下面那份权重修订"这一组条件下成立**，换机器不可套用。

## 2. 基础条件

| 项 | 要求 |
|---|---|
| GPU | 8 × Tesla T10（sm_75，16 GiB），纯 PCIe 无 NVLink。其它 sm_75 卡需重测常量 |
| 宿主驱动 | ≥ 570（本机 580.173.02）。`nvidia-smi` 要能出八张卡 |
| 容器运行时 | Docker ＋ **NVIDIA Container Toolkit**（`docker info` 的 Runtimes 里要有 `nvidia`，否则 `--gpus all` 起不来） |
| 宿主 CUDA toolkit | **不需要**。CUDA 12.9 与 `nvcc` 都在镜像里（这台机宿主就没有 `/usr/local/cuda`）。注意别和上一行的 Container Toolkit 混——那个是必须的 |
| 内存 · FP8PLE 靶子 | 总 ≥ 128 GiB、可用 ≥ 110 GiB；容器上限 112 GiB（权重加载峰值实测 110.7/112，别调低） |
| 内存 · AutoRound 靶子 | **总 ≥ 240 GiB**（实测容器内存占用 231.4 GiB、宿主 used 153 GiB）。128 GiB 的机器跑不了这一靶，走 FP8PLE |
| 磁盘 | 权重约 120–124 GiB；根盘余量 ≥ 40 GiB |
| 面板两处必修 | ① GPU 探测超时 3 s→20 s（本包的层1 已含）② NVAPI 宿主只读 bind（缺它面板拒绝起引擎，退路见 `docker/NVAPI-获取说明-v1.md`） |

### 先把模型文件准备好（两靶子任选其一，下载要挑时间）

**靶子 A · FP8PLE（本包对外数字全部出自这一靶，默认）**
`Qwen3.8-Flash-Next-W4A16-FP8PLE`，与 0.1.6 包跑的是同一份权重谱系。
官方给的取件地址是 Hugging Face 的 `albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE`，
**必须用这个修订** `ef554143369a706525336f6b42a09094835dc077`（简写 `ef55414`）——数字对不对全看它。
魔搭 ModelScope 上我们没搜到同名档，所以取件走 HF；国内网络可在下载容器里加 `-e HF_ENDPOINT=https://hf-mirror.com` 换镜像站。
拿到后**先全量校验再往下走**：`bash tools/sha256-weights-v1.sh /你的/权重目录` ⇒ 末行 `SHA_VERIFY_PASS 34/34`。

**靶子 B · AutoRound W4A16（Intel 微调量化档，可选）**
`Intel/Qwen3.8-Flash-Next-W4A16-AutoRound`，魔搭可直下：

```bash
modelscope download --model Intel/Qwen3.8-Flash-Next-W4A16-AutoRound --local_dir /你的/权重目录
```

这一靶走包内 `run/profiles/flash-next-tp8-256k-autoround.json`（`format=custom`、`HC_GEMV=0`）。
它的实测吞吐**低于靶子 A**（九长度配对：输出 −2%～−13%，差值集中在 decode 每步），
内存要求却高得多——选它之前先对上表那一行 256 GiB。两靶子的数字不互套。
完整取件与下载命令的另一种写法在上游源码树 docs 目录下的 flash-next-tp8.md（那是源码树自带的文档，不在本包内）。

## 3. 怎么用

```bash
# ① 构建镜像（层0 官方 ultra → 层1 探测超时 20s → 层2 PCIe-IPC 回填）
#    已有官方基座标签就只补层1、层2；没有就指一份 0.1.7 源码树（本包不随附源码树）
bash docker/build.sh
SM75_SRC=/path/VLLM-SM75-0.1.7-beta bash docker/build.sh     # 需要连层0 一起建时

# ② 机器体检（只读）。有 BLOCK 会以退出码 4 结束，先解决再继续
bash run/env-check-v1.sh /你的/权重目录

# ③ 起控制台容器（先看预演：--dry-run 不写任何东西、不起容器）
DATA=/var/lib/sm75-console MODELS=/var/lib/sm75-models/Flash-Next-FP8PLE bash run/start-here-v2.sh --dry-run
DATA=/var/lib/sm75-console MODELS=/var/lib/sm75-models/Flash-Next-FP8PLE bash run/start-here-v2.sh

# ④ 注册权重＋从官方模板建档
docker exec <容器> node /console-data/tmp/console-driver-v1.cjs setup          # 打印 PROFILE_ID

# ⑤ 问答式配置：几个人用、要多长上下文、CPU KV 开多大、多久进 P8……
#    回车＝基线；先 --dry-run 看一遍将要改什么，它一条都不会写
bash run/configure-v1.sh --dry-run
bash run/configure-v1.sh
```

⑤ 是给人用的，也是给"不想记参数"的人用的：它把取值范围、内存/显存账和联动关系收在一处——
多人用会顺手抬 CPU KV 并提示容器上限要重建才生效；内存不够的机器它直接拦并告诉你最多能开多大；
把上下文往低改会二次确认（那是能力项不是性能项）。PCIe-IPC 那一题**默认开**（这台机上 decode ＋30% 就是它）。
不想用问答也行：`docker exec <容器> node /console-data/tmp/console-edit-profile-v2.cjs <profileId> dump`
先读当前值，再按 `setenv`/`setarg`/`addarg`/`setfield` 逐条改，每条自带回读断言与回滚。

```bash
# ⑥ 起引擎，看签名
docker exec <容器> node /console-data/tmp/console-driver-v1.cjs start <profileId>
docker exec <容器> node /console-data/tmp/console-driver-v1.cjs status <profileId>
```

浏览器开 `http://127.0.0.1:1615` 就是 Ultra 控制台，登录 token：`docker exec <容器> cat /console-data/key`。
⑤⑥ 在网页上点也能做（注册权重 → 选模板 `flash-next-tp8-256k-nomtp` → 改参数 → 启动）。

**怎么算成功**（`start-here` 自己会逐条断言，不过就非零退出）：

- `RUN_DONE 全部终态断言通过`
- 引擎日志 `Using ['FLASHINFER_PCIE_IPC', 'FIREFLY_AR', 'PYNCCL'] … for group 'tp:0'` —— 后端在**第一位**
- 有 `Initialized FlashInfer PCIe IPC all-reduce`，**没有** `does not provide PcieIpcAllReduceWorkspace`
- `GPU KV cache size: 339,110 tokens`、`FP8 layout verified` 恰好 **96 条**、`backend=p2p` 8 条、无 `Traceback`

逐步操作、每步判据、失败与处置对照表：**`部署文档-v1.md`**。

## 4. 包里有什么

```
README.md                本文件
部署文档-v1.md            逐步操作与判据、失败处置表
基线与口径说明-v1.md       哪些值来自官方、哪些是这台机的差异、数字怎么读
CHANGELOG.md              版本沿革
LICENSE  NOTICE  SHA256SUMS.txt
run/    start-here-v2.sh  唯一启动入口（门禁＋终态断言＋读 config.env）
        configure-v1.sh   问答式配置（并发／上下文／CPU KV／进 P8 秒数／端口…，回车＝基线）
        env-check-v1.sh   只读机器体检
        profiles/         两靶档：FP8PLE（默认）与 AutoRound W4A16，PCIe-IPC 都已默认开
docker/ build.sh          唯一构建入口（三层，逐层终态断言，任一层可跳）
        Dockerfile.to20s-v1 / to20s-patch-v2.sh      层1：探测超时 3s→20s
        Dockerfile.pcieipc-v1 / pcieipc/             层2：PCIe-IPC 回填物料与门禁
        libnvidia-api.so.1 / NVAPI-获取说明-v1.md    P-State 需要的宿主库（只读 bind）
tools/  panel/            面板命令行驱动（建档/起停/改档；改档工具以 v2 为准，v1 是上一版、包内已无脚本引用）
        sha256-weights-v1.sh / flash-next-tested.sha256   权重全量校验（34 项）
        gen-console-env-v1.sh   把在役容器 env 固化成宿主 600 文件
        bench-official-v1.sh    官方尺子测速封装（口径钉死＋可比性判定）
        lint-package-v1.sh      我们自己的出厂自检（你不用跑，核对完整性用 sha256sum -c 就够）
docs/   实测-面板测速对照-v1.md ＋ 两张截图 ／ 群友提示词-PCIeIPC回填-v1.md
```

**不含**：模型权重、0.1.7 源码树、任何凭据。

## 5. 四条要知道的

1. **那层 PCIe-IPC 回填是我们自维护的补丁，不是官方能力**：把 FlashInfer 0.7.0.post1 的 6 个文件与 3 处导出补进镜像里已装的 0.6.18，
   不升级 FlashInfer、不动 attention 内核与 cubin、vLLM 树一个字节不改。官方镜像点不亮这个后端。
   一键退回官方形态：`SKIP_PCIEIPC=1 bash docker/build.sh`（或 ⑤ 那一题选"关"）。上游带上这个能力后**应当撤除**。
2. **改配置走 `run/configure-v1.sh`，别手改 JSON**。它把答案分两处落：档内的（并发、上下文、CPU KV、电源）
   通过面板 API 改并逐字段回读，容器层的（端口、内存上限、绑定）写进 `$DATA/config.env` 由 `start-here-v2.sh` 读。
   容器内存上限这类**要重建容器才生效**，脚本末尾会把那条命令打给你。
3. **端口默认只绑 127.0.0.1，包内不含凭据**。要局域网访问显式 `BIND_HOST=0.0.0.0` 并自行加鉴权；
   登录 token 与引擎 key 都在运行时生成、落在 `$DATA`（`chmod 700`），别外发那个目录、别提交进 git。
4. **两处与官方文档不同**（都写进 `基线与口径说明-v1.md` 的漂移项）：面板数据我们绑到容器内 `/console-data`（官方示例绑 `/data`，
   两者都行，硬要求是 `SM75_CONSOLE_ROOT` 与 bind 目标一致）；编译缓存我们用四条 home 目录 bind
   （`.cache`/`.triton`/`.nv`/`.tilelang`，官方是 `/data/cache` ＋ 一组 `*_CACHE` 环境变量），
   多出来的 `.tilelang` 是实测落在可写层、重建会重付编译费才补的。

## 6. 许可

代码部分 Apache-2.0（见 `LICENSE`、`NOTICE`）。`docker/libnvidia-api.so.1` 是 NVIDIA 驱动侧运行库，
仅为让 P-State 托管可用而随包附送（720104 字节，sha256 `4a199f9b…131d8c`，驱动 580.173.02），
仍受 NVIDIA 驱动许可约束、不由本包授权再分发；不想带它就按 `docker/NVAPI-获取说明-v1.md` 走 sleep 退路。
模型权重不在包内，第三方量化档有自己的许可与基座模型条款，用前请自行核对。
