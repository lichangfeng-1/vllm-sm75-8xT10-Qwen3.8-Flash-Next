# 更新记录

## v1.1 — 2026-10-08（加交互配置层）

回应群友"不会配置"：把"多人用、内存小的机器、想省电"这三类改配置的动作收进一个问答案答器，
不再要求人去改 JSON。

- 新增 `run/configure-v1.sh`：七组问答（并发／上下文／CPU KV／电源与进 P8 秒数／权重目录与模型名／
  能力开关／端口与绑定）。**默认值＝基线，回车即落基线**；自定义值一律放行（超过本机的值只提示不拦），
  只有低于能力线（砍上下文）与内存/显存算不过账才拦。`--dry-run` 只预览、`--show` 只读、`--selftest` 验门禁。
- 新增 `tools/panel/console-edit-profile-v2.cjs`：在 v1 的三种模式上补 `addarg`/`addswitch`/`delarg`/
  `delswitch`/`setfield`/`setmodel`/`dump`/`list`。护栏一条不放宽（引擎在跑拒、写后逐字段回读、
  非声明项变了就 POST 原档回滚、密钥不回显）。
- 新增第二靶子档 `run/profiles/flash-next-tp8-256k-autoround.json`（Intel AutoRound W4A16，
  `format=custom`、`HC_GEMV=0`）。对外那组吞吐数字仍出自 FP8PLE 档，两档数字不互套。
- `start-here-v1.sh` → `run/start-here-v2.sh`：进 P8 默认 86400 s → **120 s**、读 `$DATA/config.env`
  （按行按白名单取键，不 `source`）、容器内改档工具升到 v2。**v1 已删除**（留着会让人拿到 24 小时 P8）。
- 删 `profiles/` 里那份 `…-nomtp-pcieipc.json`：取证两档只差一条
  `VLLM_ALLREDUCE_USE_FLASHINFER_PCIE_IPC=1`，现在这一条**默认在基线档里就是开的**（它是提速关键项），
  关它由 configure 的"能力开关"那一题负责。
- 两份 profile 都并入 `--auto-sleep-idle-timeout 0`（关引擎自动休眠；pstate 形态本就该关，
  在役档一直带着这一条而包内没有）。
- 纠正一处过期数字：本机容器内存上限写的是 140 GiB，实读是 **240 GiB**（AutoRound 档容器占用 231.4 GiB）。
- 补上游署名：README 与 `基线与口径说明` 加上项目地址 github.com/fishensw/VLLM-SM75；
  `NOTICE` 第 1 条原先只写"vLLM-SM75 0.1.7-beta"没给出处地址，一并补上（Apache-2.0 的出处告知义务）。
- `docs/实测-面板测速对照-v1.md` 增设"附：第二靶子 AutoRound 的九长度"表 ⇒ 两靶数字正式分表、不再互引。
- 出厂自检 `tools/lint-package-v1.sh` 加 **G 段静态分析**（shellcheck 的 error 级阻断、每个 `.cjs` 过
  `node --check`；工具不在位就明写"没扫"而不是给绿）。同时堵掉 C 段三条假绿通道：不再豁免自身、
  逐条判 grep 退出码（正则写坏不再被 `2>/dev/null` 吞掉）、扫描条数要有计数；路径与 IP 改成分两路扫
  （原来一行里混着 `0.0.0.0` 就能把同一行的真内网 IP 一起洗掉）。
- `configure-v1.sh` 语义明确化：**非交互＝基线**（不是"保持当前值"），交互时回车＝不改，
  每题同时印"基线＝X，当前档＝Y"；CPU KV 的推荐值只写在题面，不再冒充默认值。
- 新增覆盖口 `SM75_MEM="总 可用"`：`/proc/meminfo` 只有 Linux 有，非 Linux 机器读不到时 BLOCK，
  不拿默认值兜底（读不到就按 0 或按猜的放行，是最坏形态）。
- `clone` 建档规则：包内档的 `args[0]` 是模板占位符 `${MODEL}` ⇒ 现在必须再给一个模型绝对路径，
  否则会建出一档"模型目录叫 ${MODEL}"、起不来还看不出错面的配置。

**已知限制**

- CPU KV 的 4/8/16/32 GiB 阶梯按**实测 `MemAvailable`** 给推荐值，但"开了之后多人实测提升多少"
  这台机没有数据点——它是稳态保险项，不是提速项，别当收益引用。
- `configure-v1.sh` 只改档与 `config.env`；容器内存上限这类要**重建容器**才生效，脚本会在末尾把那条命令打给你。

## v1.0 — 2026-10-07（首个 0.1.7 版）

对应上游 **vLLM-SM75 0.1.7-beta**（upstream vLLM 0.30.0、Torch 2.13.0+cu129、CUDA 12.9、FlashInfer 0.6.18、Node 22.23.2）。
在 8 × Tesla T10（sm_75，纯 PCIe）上把 Flash-Next 档做到"从零装到跑满"，每一步都有可复核的终态判据。

**与 0.1.6 包的关系**：另起一条包线，不是原地升级。0.1.6 不再维护。

- 0.1.6 的四层补丁模型（awqple / incple / monitorfix / nvapi 烘进镜像）在 0.1.7 不适用：官方已是单镜像，NVAPI 改回**宿主只读 bind**。
- 本包**不随附源码树**（0.1.6 曾把 `code/` 一起发）；层0 由官方 `docker/build.sh` 产出，你用自己的 `SM75_SRC=` 指过去。
- 新增：三层构建编排 `docker/build.sh`、PCIe-IPC 回填层 `docker/pcieipc/`、唯一启动入口 `start-here-v1.sh`（v1.1 起为 v2）、
  只读机器体检 `run/env-check-v1.sh`、面板命令行驱动 `tools/panel/`、官方尺子测速封装 `tools/bench-official-v1.sh`、
  出厂自检 `tools/lint-package-v1.sh`、前后对照实测 `docs/`。
- 新增一层**我们自维护**的 FlashInfer PCIe-IPC 回填（6 个逐字文件＋3 处纯追加，不动 vLLM 树、不升级 FlashInfer）。
  官方产物点不亮这个后端；收益与撤除方式见 README §3 与 §5。

**已知限制**

- 回填层是补丁不是官方能力；上游 FlashInfer 带上 `PcieIpcAllReduceWorkspace` 后应撤除。
- 所有性能数字只适用于 **8 × Tesla T10（sm_75）@150 W** ＋ 官方 tested 权重修订 `ef55414`；权重不同则数字不可比。
- 还欠一次"同容器只把那一个环境变量设回 0"的反向单变量对照，跨会话复现未做。

> 开发过程、审查轮次与逐条修复细节不在包里（那是我们的施工记录，对使用者没用）：
> 看本仓库的提交历史与 PR，或按 `README.md` 最后一节的联系方式来问。
