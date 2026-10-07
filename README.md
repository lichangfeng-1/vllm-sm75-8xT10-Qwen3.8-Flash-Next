# vLLM-SM75 0.1.7 自包含部署包（8 × Tesla T10 / sm_75）

在 **G292-Z20 / 8 × Tesla T10（sm_75，纯 PCIe、无 NVLink）** 上，把 Flash-Next 27B MoE 档
（TP8＋EP、256K 上下文、FP8 KV、QSA 全开、无 MTP）从"能跑"做到"跑满"。
每一步都写了**怎么算成功**，不满足就停在那一步，不靠"看起来差不多了"往下走。

对应上游 vLLM-SM75 **0.1.7-beta**。照做完大约 20–40 分钟（大头是模型加载）。

---

## 1. 先给结论：这台机上量到了什么

同一台机、同一个档、同一把尺（Ultra 控制台自带「模型测试」，并发 1），差别只是多一层 PCIe-IPC 回填 ＋ 一个环境变量：

| 指标 | 装之前 | 装之后 | 变化 |
|---|---|---|---|
| 每 token 步时 ITL | 22.89–23.25 ms | **17.22–17.61 ms** | 每步省 ≈5.5 ms |
| 输出 tok/s | 43.15–43.95 | **57.03–58.36** | ＋30.5%～＋33.1%（逐档配对） |
| 预填充 tok/s / TTFT | — | — | 动 1% 以内（噪声） |

省下来的时间与上下文长度无关 ⇒ 是"每步一次全卡通信"被换掉了的形状。**不是提频、不是解锁功率墙**
（两次 SM 时钟都是 1590 MHz；每 token 能量 2.06 → 2.03 J，此数为功耗÷吞吐算出的计算值）。

完整数据、口径与未闭环项：`docs/实测-面板测速对照-v1.md`。
用官方随包尺子复核过 8K 档：decode 44.55 → 58.01（＋30.2%），`passed=true`、零抢占、零缓存命中、无投机。

## 2. 五步装完（可直接粘贴）

```bash
# ① 构建镜像。层0 是官方镜像（本包不含源码树：已有基座标签就只补层1、层2；没有就用 SM75_SRC= 指一份 0.1.7 源码树）
bash docker/build.sh
# ② 机器体检（只读）。有 BLOCK 会以 4 退出，先解决再继续
bash run/env-check-v1.sh /你的/权重目录
# ③ 起控制台容器（先 --dry-run 看组装出来的 docker run，它不写任何东西）
DATA=/var/lib/sm75-console MODELS=/var/lib/sm75-models/Flash-Next-FP8PLE bash run/start-here-v1.sh --dry-run
DATA=/var/lib/sm75-console MODELS=/var/lib/sm75-models/Flash-Next-FP8PLE bash run/start-here-v1.sh
# ④ 从官方模板建档，并给这个档加上那条开关（不加就是白建：后端仍是 FIREFLY_AR）
docker exec <容器> node /console-data/tmp/console-driver-v1.cjs setup         # 打印 PROFILE_ID
docker exec <容器> node /console-data/tmp/console-edit-profile-v1.cjs <profileId> \
  setenv VLLM_ALLREDUCE_USE_FLASHINFER_PCIE_IPC 1
# ⑤ 起引擎并看签名
docker exec <容器> node /console-data/tmp/console-driver-v1.cjs start <profileId>
docker exec <容器> node /console-data/tmp/console-driver-v1.cjs status <profileId>
```

嫌命令行麻烦：④ 直接在网页上注册权重、选模板 `flash-next-tp8-256k-nomtp`、在档的 env 里加那一行；
也可以拿包里的 `run/profiles/flash-next-tp8-256k-nomtp-pcieipc.json`（＝官方模板 ＋ 那一条开关）导入。
**判成功的终态**（`start-here` 自己会断言，不过就非零退出）：

- `RUN_DONE 全部终态断言通过`，退出码 0；
- 引擎日志里 `Using ['FLASHINFER_PCIE_IPC', 'FIREFLY_AR', 'PYNCCL'] … for group 'tp:0'` —— 后端在**第一位**；
- 有 `Initialized FlashInfer PCIe IPC all-reduce`，且**没有** `does not provide PcieIpcAllReduceWorkspace`；
- `GPU KV cache size: 339,110 tokens`、`FP8 layout verified` 恰好 **96 条**、`backend=p2p` 8 条、无 `Traceback`。

逐步操作、每步判据、失败与处置对照表：**`部署文档-v1.md`**。

## 3. 这层 PCIe-IPC 回填是什么（请读完这一节再用）

- 它**不是官方能力**：官方镜像钉 FlashInfer 0.6.18，而 `PcieIpcAllReduceWorkspace` 是 0.7 才有的类。
  我们把 0.7.0.post1 里的 6 个文件与 3 处导出补进已装的 0.6.18，**不升级 FlashInfer、不动 attention 内核与 cubin、vLLM 树一个字节不改**。
- 一键退回官方形态：`SKIP_PCIEIPC=1 bash docker/build.sh`（或 ④ 那一步不加那条 env）。
- 上游一旦自带这个 workspace，**这层应当撤除**，别长期叠加。
- 默认会带上这一层（本机增益量级明确），这是本包对"默认值锁基线"的一处破例，其余破例见 §5。

## 4. 前提

| 项 | 要求 | 说明 |
|---|---|---|
| GPU | 8 × Tesla T10（sm_75，16 GiB），纯 PCIe | 其它 sm_75 卡需重测常量；非 sm_75 不适用 |
| 驱动 / CUDA | ≥ 570，引擎内 CUDA 12.9 | 容器自带，不依赖宿主 CUDA toolkit |
| 内存 | 总 ≥ 128 GiB、可用 ≥ 110 GiB；容器上限 112 GiB | 权重加载峰值实测 110.7/112 GiB，**别调低** |
| 磁盘 | 权重约 120–124 GiB；根盘余量 ≥ 40 GiB | 构建前 `df` 现采；`$DATA`/`$CACHE` 在别的盘时那一盘也要够 |
| 权重 | 官方 tested 修订 `ef55414`（`tools/flash-next-tested.sha256` 34 项全对） | 权重不同 ⇒ 所有吞吐数字作废 |
| 面板两处必修 | ① GPU 探测超时 3s→20s（层1）② NVAPI 宿主只读 bind | 缺①面板报「无法读取 GPU 状态」拒启；缺②面板拒绝起引擎（退路见 `docker/NVAPI-获取说明-v1.md`） |

## 5. 默认值与四处破例（别踩坑，也别以为我们偷偷改了基线）

包内默认值＝**上游官方基线**；这台机器的差异只写进 `基线与口径说明-v1.md` 的"漂移项"，不默认发出去。
明确破例四处：

1. 带 PCIe-IPC 回填层（§3，可一键退）。
2. 多一份推荐档 `flash-next-tp8-256k-nomtp-pcieipc.json`（官方档 ＋ 那一条开关）。
3. `--restart no`：开机不自起、不自起抢八卡；要常驻服务就显式改 `RESTART=`。
4. 缓存 bind 给四条（`.cache`/`.triton`/`.nv`/`.tilelang`），比官方示例多 `.tilelang`：它原本落在容器可写层，重建容器就重付一次编译费。

另外两条约定：引擎端口**默认只绑 127.0.0.1**（要局域网访问显式 `BIND_HOST=0.0.0.0` 并自行加鉴权）；
包内**不含任何凭据**，登录 token 与引擎 key 都在运行时生成、落在 `$DATA`（`chmod 700`），别外发那个目录。

## 6. 你大概会撞到的四件事

1. **直接 `docker run 镜像 vllm serve …` 起来的是控制台**：派生镜像的 ENTRYPOINT 是 node 控制台，直跑 vllm 要显式 `--entrypoint`。本包入口脚本已按镜像默认 ENTRYPOINT 处理。
2. **计数翻倍**：面板的档日志跨次追加，`FP8 layout verified 96` 这类判据只统计**本次启动新增的字节段**（`部署文档` 步骤 5 给了取法）。
3. **别整体升级到 FlashInfer 0.7**：官方钉 0.6.18 有理由（AOT cubins 不含 SM75 会让 BatchPrefill 在图预热时失败）。回填只动 9 个文件。
4. **启动慢了几分钟**：多半是四条缓存 bind 少一条（尤其 `.tilelang`），或首次现场 nvcc 编译（本机冷缓存实测 9.1 秒）。

## 7. 包里有什么

```
README.md                本文件（先看这个）
部署文档-v1.md            逐步操作、每步判据、失败处置表
基线与口径说明-v1.md       基线值 / 本机漂移项 / 数字怎么读
CHANGELOG.md              版本沿革
LICENSE  NOTICE  SHA256SUMS.txt
run/    start-here-v1.sh  env-check-v1.sh  profiles/*.json
docker/ build.sh  Dockerfile.to20s-v1  Dockerfile.pcieipc-v1  to20s-patch-v2.sh
        pcieipc/（回填物料与门禁）  libnvidia-api.so.1  NVAPI-获取说明-v1.md
tools/  panel/（两枚面板 CLI）  sha256-weights-v1.sh  flash-next-tested.sha256
        gen-console-env-v1.sh  bench-official-v1.sh  lint-package-v1.sh
docs/   实测-面板测速对照-v1.md ＋ 两张截图  群友提示词-PCIeIPC回填-v1.md
```

`tools/lint-package-v1.sh` 是给我们自己用的出厂自检，跑它需要一份**仓库之外**的身份清单
（`PRIVACY_PATTERNS=/你的清单`），没有就判 FAIL——那是有意的，防止把真实姓名/用户名/宿主路径带进公开仓库。
你不用跑它；想核对文件完整性跑 `sha256sum -c SHA256SUMS.txt` 就够。

## 8. 许可与第三方

代码部分 Apache-2.0（见 `LICENSE`、`NOTICE`）。`docker/libnvidia-api.so.1` 是 NVIDIA 驱动侧运行库，
仅为让 P-State 托管可用而随包附送（720104 字节，sha256 `4a199f9b…131d8c`，驱动 580.173.02），
仍受 NVIDIA 驱动许可约束、不由本包授权再分发——不想带它就按 `docker/NVAPI-获取说明-v1.md` 走 sleep 退路。
模型权重不在包内，第三方量化的许可请你自己核对。
