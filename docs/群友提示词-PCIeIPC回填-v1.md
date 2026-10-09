# 提示词（给群友的 AI 直接用）：把 0.1.7 的无 MTP decode 从 44 提到 58

把下面整段贴给你的 AI。

---

目标：在 vLLM-SM75 0.1.7-beta、8 张 Tesla T10（sm_75，纯 PCIe，无 NVLink）的机器上，把无 MTP 的 decode 从约 44 tok/s 提到约 58 tok/s。做法是把 FlashInfer 0.7 的 PCIe-IPC allreduce 回填进镜像里已装的 0.6.18，不升级 FlashInfer 版本、不动 attention 内核与 cubin。

先确认你处在同一个问题里。看引擎日志里 tp:0 这一行：如果候选列表里有 FLASHINFER_PCIE_IPC 但实际选用只有 FIREFLY_AR 与 PYNCCL，并且另有一行告警说 this FlashInfer build does not provide PcieIpcAllReduceWorkspace，那就是同一个卡点。这台机上四条快路都是封的：CUSTOM 以"纯 PCIe 且超过两张卡"为由禁用，SYMM_MEM 要求计算能力 8 以上，常规 FlashInfer allreduce 拒绝 world_size 等于 8，PCIe-IPC 缺 workspace 类。

核心思路：vLLM 判定这个后端能不能用，只看一句 hasattr，检查 flashinfer.comm 上有没有 PcieIpcAllReduceWorkspace 这个属性。而这个类在 flashinfer_python 0.7.0.post1 的 wheel 里有，0.6.18 里一次都没有。它自带的 JIT 生成器注释写明：内核只用普通 PTX 读写与 CUDA IPC，没有架构限制，面向的就是无 NVLink 的 PCIe 机器，与 SM 版本正交。所以 sm_75 能编能跑，缺的只是这个包没带这个文件。

做法，一共九件东西，六件原样落盘、三件纯追加。

原样落盘，从 0.7.0.post1 的 wheel 里按字节取出，放进已装 0.6.18 的包目录：
一，comm 目录下 pcie_ipc_ar.py、pcie_ipc_policy.py、pcie_ipc_topology.py、pcie_ipc_tuning.py 四个文件。
二，data/csrc 下 pcie_ipc_all_reduce.cu。
三，data/include/flashinfer/comm 下 pcie_ipc_all_reduce.cuh。

纯追加，只往文件末尾加，不改任何已有行：
四，jit/comm.py 末尾追加 0.7 的 gen_pcie_ipc_comm_module 函数。
五，trace/templates/comm.py 末尾追加 0.7 的 _pcie_ipc_all_reduce_init、_pcie_ipc_all_reduce_reference 以及 pcie_ipc_all_reduce_trace 这个 TraceTemplate 赋值。前两个函数必须一起带上，只带赋值那句会让 import flashinfer 直接 NameError，整条推理路径当场死。
六，comm/__init__.py 末尾追加 0.7 里那组 pcie 相关的 import 语句，把 PcieIpcAllReduceWorkspace 等名字导出。

依赖不用补，0.6.18 都已经有了：autotuner 是个包目录，八个符号齐全；api_logging 的 flashinfer_api 接受 trace 关键字参数；utils.py 里的 register_custom_op 藏在 if 与 else 两个分支里，按顶层 def 去找会误判成缺失；comm/cuda_ipc.py 与 0.7 版逐行零差异；jit/env.py 三个目录变量都在；nvcc 在镜像里，tvm 的 ffi 头由已装的 tvm_ffi 包提供，而且已有二十五个 cu 文件在用同一套头，说明 include 通路本来就通。

用独立镜像标签做，别改官方产物。构建期硬断言四件事：每个落盘文件的 sha256 与清单一致；三处追加的验收用"目标文件必须以该块内容逐字结尾"，不要用某个字符串出现一次的计数，因为同一句 import 在块里本来会出现三次，计数断言会把好构建判成失败；七个被改和新增的 py 文件 py_compile 要过；最后在镜像里真的执行一次 import flashinfer.comm 并打印 hasattr 的结果，这一句就是 vLLM 自己的判据。构建完做一次两镜像全树清单对拍，期望恰好六个新增、三个内容变化、删除为零，vllm 那棵树变动为零。

启动：用官方模板原样的参数，只多加一个环境变量 VLLM_ALLREDUCE_USE_FLASHINFER_PCIE_IPC 设为 1（这一步不能漏：光有镜像那一层而不置这个变量，vLLM 默认不启用该后端，dispatch 首位仍是 FIREFLY_AR，白建）。用本包 run/profiles 里那两份档就不用手工加——这一条已经写在档的 env 里；关它请走 bash run/configure-v1.sh 的"能力开关"那一题，或直接 setenv 成 0。验收看引擎日志两行，一是 tp:0 的 dispatch 列表里 FLASHINFER_PCIE_IPC 排到了第一位，二是出现 Initialized FlashInfer PCIe IPC all-reduce。同时确认 GPU KV cache size 仍是 339110 tokens、FP8 layout verified 仍是 96 条（12 个 full_attention 层乘 8 个 worker）、QSA 那组开关值一个都没变、没有 Traceback。计数类判据只取本次启动新增的字节切片，面板的档日志是跨次追加的，整份去数会翻倍。

我这台的实测结果（@150 W 工况）：8K decode 中位 44.55 提到 58.01，加 30.2%，步时从 22.45 毫秒降到 17.24 毫秒；128K 与 256K 同向，分别 17.12 与 17.03 毫秒；prefill 三档分别是 −0.03%、−0.09%、−0.13%（也就是没动）。面板自带的那把尺上，同长度逐档配对输出吞吐 加 30.5% 到 33.1%。省下来的约 5 毫秒与上下文长度无关，正是每步一次 allreduce 的形状。功耗从每卡 90 瓦升到 118 瓦（基线那侧的 90 瓦来自面板性能监控页的逐卡读数 87.8 到 92.5 瓦），但每 token 能量几乎没变（2.06 对 2.03 焦耳，这两个数是功耗除以吞吐算出来的计算值，不是仪器实测），也就是功耗上涨完全由步数增加解释，不是提频或解锁功率墙，别把这个当机制。

几个坑：不要整体升级到 0.7.0，官方镜像钉 0.6.18 有它的理由，面太大；0.6.18 的 comm/__init__.py 末尾有个 __getattr__ 会抛 AttributeError，别指望惰性属性兜住，导出要显式写；如果直接用 docker run 加 vllm serve 参数起容器，派生镜像继承的是 node 控制台的 entrypoint，整条命令会被吞掉、容器空转成控制台服务，必须显式指定 entrypoint；首次启动会现场 nvcc 编译这个模块，我这台冷缓存实测 9.1 秒，不用预留几分钟，但 JIT 缓存目录要挂到宿主，别每次重编。

诚实的保留：官方文档里无 MTP 的 49.93 是在这个后端没启用的情况下测的（作者的镜像同样钉 0.6.18，日志里这个后端也只出现在候选列表），所以这条不是"解释我们为什么比文档慢"的答案，而是一条官方产物拿不到的额外增益。我这边还欠一次同参数只把这个变量设回 0 的反向单变量对照，以及一次跨会话复现。上游一旦带上这个 workspace，这层回填就应该撤掉。
