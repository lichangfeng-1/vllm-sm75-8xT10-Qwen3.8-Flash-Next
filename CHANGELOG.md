# 更新记录

## v1.0 — 2026-10-07（首个 0.1.7 版）

对应上游 **vLLM-SM75 0.1.7-beta**（upstream vLLM 0.30.0、Torch 2.13.0+cu129、CUDA 12.9、FlashInfer 0.6.18、Node 22.23.2）。
在 8 × Tesla T10（sm_75，纯 PCIe）上把 Flash-Next 档做到"从零装到跑满"，每一步都有可复核的终态判据。

**与 0.1.6 包的关系**：另起一条包线，不是原地升级。0.1.6 不再维护。

- 0.1.6 的四层补丁模型（awqple / incple / monitorfix / nvapi 烘进镜像）在 0.1.7 不适用：官方已是单镜像，NVAPI 改回**宿主只读 bind**。
- 本包**不随附源码树**（0.1.6 曾把 `code/` 一起发）；层0 由官方 `docker/build.sh` 产出，你用自己的 `SM75_SRC=` 指过去。
- 新增：三层构建编排 `docker/build.sh`、PCIe-IPC 回填层 `docker/pcieipc/`、唯一启动入口 `run/start-here-v1.sh`、
  只读机器体检 `run/env-check-v1.sh`、面板命令行驱动 `tools/panel/`、官方尺子测速封装 `tools/bench-official-v1.sh`、
  出厂自检 `tools/lint-package-v1.sh`、前后对照实测 `docs/`。
- 新增一层**我们自维护**的 FlashInfer PCIe-IPC 回填（6 个逐字文件＋3 处纯追加，不动 vLLM 树、不升级 FlashInfer）。
  官方产物点不亮这个后端；收益与撤除方式见 README §3 与 §6。

**已知限制**

- 回填层是补丁不是官方能力；上游 FlashInfer 带上 `PcieIpcAllReduceWorkspace` 后应撤除。
- 所有性能数字只适用于 **8 × Tesla T10（sm_75）@150 W** ＋ 官方 tested 权重修订 `ef55414`；权重不同则数字不可比。
- 还欠一次"同容器只把那一个环境变量设回 0"的反向单变量对照，跨会话复现未做。

> 开发过程、审查轮次与逐条修复细节不在包里（那是我们的施工记录，对使用者没用）：
> 看本仓库的提交历史与 PR，或按 `README.md` 最后一节的联系方式来问。
