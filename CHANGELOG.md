# CHANGELOG

## v1.0 — 2026-10-07（首个 0.1.7 版）

### 发布前修复（三轮隔离审查的 11 条阻塞，全部修完才对外）

包从未对外发过，所以这些改动并成 v1.0 的一部分，不单开版本号；脚本文件名仍带 `-v1`。

| 条 | 症状（别人照包跑会怎样） | 修法 |
|---|---|---|
| B1 | 层2 引用了包内不存在的文件名 ⇒ **根本构建不出来** | 文件名对齐，并让 `tools/lint-package-v1.sh` 校验 build.sh 与 Dockerfile COPY 自洽 |
| B2 | `SM75_CONSOLE_ROOT` 写成 `/opt/sm75-workbench/console` ⇒ profiles.json 与登录 key 落进容器可写层，**重建即丢** | 改成在役实测的 `/console-data`，并把 `POWER_MODE/PSTATE_GPUS/PSTATE_IDLE_TIMEOUT/NCCL_P2P_LEVEL/VLLM_FIREFLY` 等按在役容器实读补齐（注明哪些是镜像自带的） |
| B3 | 把镜像 `ENTRYPOINT` 又当命令传一遍 ⇒ 参数被当 vllm 参数吃 | `docker run` 只传镜像名（ENTRYPOINT 已是 `python3 runtime-entrypoint.py`、CMD 空） |
| B4 | 说"可重建"却没有 `rm` 路径 ⇒ 第二次必 name conflict | 同名容器一律 BLOCK＋给人工处置命令；**本包不自动删/停任何容器** |
| B5 | "终态自检"只 print 不判定 ⇒ `hasattr=False` 也报 RUN_DONE | 改成四条真断言（端口映射、hasattr、timeout:20000、容器内看得见 CLI 工具），不过 ⇒ `DONE_WITH_FAILS` 退出 7；断言按镜像标签决定该不该跑，避免"干净现场必然失败"的假阻断 |
| B6 | `mkdir`/`chmod` 跑在门禁结论之前 ⇒ "未执行任何写操作"是假话，`--dry-run` 也建目录 | 写操作全部挪到门禁通过之后；`--dry-run` 全程只读 |
| B7 | `BOOTSTRAP_ENV` 用 `tr ',' ' '` 切分 ⇒ `PSTATE_GPUS=0,1,…` 碎成静默丢值 | 默认集改成 bash 数组；覆盖口改用分号分隔，并逐片验 `KEY=VALUE` 形状，不合规直接 BLOCK |
| B8 | `env-check` 有 BLOCK 也 `exit 0`，而文档教的是 `env-check && …` | 计数 BLOCK，非零退出（4），并在文档里要求看退出码 |
| B9 | 权重校验：位置参数被忽略、清单相对路径在 `cd` 后失效、"25 主分片"口径错、`INCOMPLETE` 不退非零 | 接受位置参数；清单先解析成绝对路径再 `cd`；口径改成实数的 **15 主＋10 plefp8＋9 其它＝34**（编号 00002/00016 本就不在这份修订里）；失败退出 6，另加清单形状与"路径不得越出目录"两道预检 |
| B10 | 面板两个 CLI 工具没随包发、profile 里也没那个变量 ⇒ **拿不到 ＋31%** | 随包发 `tools/panel/console-driver-v1.cjs` 与 `console-edit-profile-v1.cjs`（sha 与在役容器里真用过的两份逐字节一致），`start-here` 自动摆到 `$DATA/tmp/`；新增推荐档 `run/profiles/flash-next-tp8-256k-nomtp-pcieipc.json`（＝官方模板＋那一条 env），官方原样档保留为基线；README 上手改成四步把这一步显式写进去 |
| B11 | 防泄露检查器自己的黑名单写着真实姓名/用户名/呼号/宿主路径，还被 `--exclude` 免检 | 身份清单移到仓外（`PRIVACY_PATTERNS` 指过去），包内只留通用形态；清单缺失从"软提示"改成 BLOCK；lint 不再排除自身；另修两处新假放行（通用密钥正则自匹配、把 `0.0.0.0`/`127.0.0.1` 当泄露） |
| B12 | `SKIP_NVAPI=1` 文档里是退路、`build.sh` 里没实现 | 实现真开关＋讲清 0.1.7 形态（这库本来不进镜像）；退路要**三处一起改**（build SKIP_NVAPI / start-here NVAPI=none / profile power.mode=sleep）；`NVAPI-获取说明` 同步重写 |
| B13 | 引擎端口默认发 `0.0.0.0` 且档内无 api-key | 默认 `BIND_HOST=127.0.0.1`，端口对外默认回落到基线 8000（18001 进漂移项）；README/部署文档写明"要局域网访问请显式改并自行加鉴权" |

### 三轮隔离审查之后的追加修复（同一批发布前，每条尽量带反向对照）

| 提出方 | 症状（别人照包跑会怎样） | 修法 |
|---|---|---|
| R1 | 自检脚本的"本机路径"门里，盘符分支经 bash 递给 grep 后反斜杠把竖线转义成了**字面竖线** ⇒ 那条分支永不为真，盘符路径整个失明 | 反斜杠改写成字符类；反向对照：盘符样本旧写法放行、新写法命中。这道门修好后第一件事就是抓到我自己写在注释里的样例路径（它本就该抓这个） |
| R1 | `bench-official` 抓到 `cached_tokens/preemptions/drafted` 异常时只往行尾拼一句提示，照样打 `BENCH_OK` 并退 0 ⇒ 把不可比的数当可比基线发出去 | 记 `bad_cases` ⇒ 末行改打 `BENCH_NOT_COMPARABLE` 并 `exit 8`；`exit $((rc+rc2))` 换成"两个都 0 才算过"（两码相加凑成 256 倍数会被 shell 归零） |
| R1 | README 教的 `--dry-run` 在"面板正在跑"的机器上必然 BLOCK（端口门按 bad 判），预演根本跑不动 | 端口门与同名容器一样在 dry-run 降为 WARN（它们拦的都是"真起"那一步），真跑形态仍 BLOCK＋退出 4 |
| R1 | B2 的保护只覆盖 `BOOTSTRAP` 分支：走 `--env-file` 时不验 `SM75_CONSOLE_ROOT`，而镜像默认是 `/data`（容器可写层，重建即丢） | env-file 分支同判（缺这个键或值不是 `/console-data` ⇒ BLOCK）；终态自检再加一条"`/console-data` 在挂载表里"（看 `docker inspect .Mounts`，不看"我 --volume 过"） |
| R1 | `NVAPI=none` 时默认 env 集仍发 `POWER_MODE=pstate`＋`PSTATE_*`，自己跟自己矛盾（面板会拒绝启引擎） | `NVAPI=none` 时默认集自动换成 `POWER_MODE=sleep` 并去掉 `PSTATE_*`，不留"记得手工改"的坑 |
| R1 | 照 README 粘第二步必撞门：`NVAPI` 默认指 `$DATA/nvapi/…`，可没人把包内文件拷到那儿，而 `$DATA` 又要门禁通过后才建 ⇒ 死结 | 默认改成包内 `docker/libnvidia-api.so.1`（sha 门现成能过）；用自己从驱动取的那份再显式 `NVAPI=` |
| R1 | `BOOTSTRAP_ENV=""`（或只有分号）切出空数组 ⇒ 一个 `-e` 都不发，其余门禁全绿，正是 B2 的"重建即丢"形状 | 空集当错误：BLOCK 并提示 unset 用默认集。（审查员判为 `set -u` 崩溃，本机 bash 5.3 与服务器 bash 5.2 都复现不了崩溃 ⇒ 按其真实性质修） |
| R1 | `docker run -e KEY=值` 的取值同时进本脚本 stdout 与宿主 `ps`；密钥类变量没人拦 | 最小 env 集的 PASS 行**只报变量名**；名字含 API_KEY/TOKEN/SECRET/PASSWORD/PRIVATE_KEY/CREDENTIAL 直接 BLOCK 并引导改用 `--env-file` |
| R2 | 测速脚本把**面板登录 token** 当引擎 api-key 发出去（跨信任边界复用） | 只读 `engine-key.current`；取不到就不发 Authorization，并写明"要配的是引擎那个密钥，不是面板 token" |
| R2 | 随包发的两枚 CLI 脱敏是锚定全匹配 ⇒ `apiKey`/`OPENAI_API_KEY`/`HF_TOKEN` 这类写法漏网；`engineenv` 的 argv 是裸打印（`--api-key` 的值能进 stdout） | 名字改按"包含"判＋值形状兜底；argv 三种形态（`--api-key 值`、`--api-key=值`、值本身像密钥）都遮；`keys`/`env_keys` 这类"变量名清单"字段豁免，否则遮到看不见档里有哪些 env |
| R1/R3 | 自检脚本 F) 门用 glob：Dockerfile 全改名时循环拿到的是字面量、计数照加 ⇒ 假通过；B) 段没覆盖 `.cjs`；`#!/bin/sh` 脚本只过 `bash -n`（容器里 `RUN sh` 用的是 dash） | F) 改用 `find` ＋"一个都没检查到就 FAIL"（反向对照：改名后确实 FAIL）；B) 补 `.cjs/.mjs`；A) 对 `#!/bin/sh` 追加 `sh -n` |
| R1 | 权重清单坏行只报前 4 行（第 5 到第 N 行被隐掉）；安装脚本对"追加块末行无换行"这一合法形状会假失败 | 报告带 `TOTAL=`；`install-pcieipc.sh` 的行数增量按形状给下限并出声说明（不改三个块的字节） |
| R1/R3 | 磁盘余量只查根盘（`$DATA`/`$CACHE` 可能在别的盘）；`gen-console-env` 的 mkdir 跑在密钥门之前；`build.sh` usage 教了并不存在的 `BASE_IMAGE=`；`SKIP_PCIEIPC=1` 时还先打"层2 自动取名"；`--model-path /models` 写死 | `df` 按最近存在祖先分别查根盘与 `$DATA`/`$CACHE` 所在盘；mkdir 挪到密钥门之后；usage 改 `OFFICIAL=`/`BASE_IMAGE_ID=`；打印顺序按分支走；`MODEL_PATH=` 可覆盖 |
| R3 | 文档与脚本对不齐若干：dry-run 的降级理由漏写"端口"；"四处破例"标题下只列了两处；`--restart no` 与四条缓存 bind 属本机漂移却当默认发出去；"9 档"易被读成包内只有 9 个提示词长度；权重步骤枚举 33 项却写"合计 34"；推荐档差集说成一行（实差 `id`、`name` ＋ env 三行）；跑自检必须自备仓外清单却没说明；`基线与口径说明` 把 44.14 与 44.55 当同一批；README 的内存/权重阈值与 `env-check` 的门不一致 | 逐条改文并把判据串与脚本原文逐字对齐；破例补齐为四条（推荐档、默认带回填层、`--restart no`、四条缓存 bind）并各写理由与出处；数字标批次与来源；默认值与门禁阈值对齐；README 目录树补 `install-pcieipc.sh`/`obligations.txt` 与仓外清单要求 |
| R3（**驳回**） | "推荐档的 cache 根不在四条 bind 内 ⇒ `setup` 必失败" | 不成立：`start-here` 把 `$CACHE/root-cache` 绑到 `/root/.cache`，而 `BENCH_CACHE_ROOT` 默认 `/root/.cache/sm75-017` 正在它下面；实测容器内 uid=0、`accessSync(/root/.cache, W_OK)` 通过、现役面板 `settings.cacheRoot` 就是这个值 ⇒ 未改默认值 |

### 同轮一并处理（二档）

改了的：`LICENSE/NOTICE` 重写为 0.1.7 叙述并补 FlashInfer 与"改过上游一个文件"的归属（Apache-2.0 §4(b)(c)(d)）；
`docker/NVAPI-获取说明-v1.md` 去掉 0.1.6 的镜像层叙述与 `incple` 残字；
数字表述按权威档案改正（基线是 5 档不是 9 档、逐档配对 ＋30.5%～＋33.1% 而不是 ＋31%～＋33%、
prefill 三档分别 −0.03/−0.09/−0.13%、预填充逐档 ＋0.4%～＋1.0%、`2.06 → 2.03 J/token` 标注为"功耗÷吞吐"的计算值、
90 W 的来源写成面板逐卡读数 87.8–92.5 W 并声明旧"八卡合计 89 W"作废）；
`部署文档` 的 `tail -c +1` 改成"记起始字节再从 START+1 切"，与同段"只取本次切片"不再自相矛盾；
`MODELS` 两种挂法（模型目录本身 / 父目录）都支持并写清各自怎么填；
`build.sh` 的层2 标签按实际走过的层自动取名（`SKIP_TO20S=1` 时不再挂着 `-to20s` 的名字），
层标签已在位时也照跑终态断言；`BASE_IMAGE_ID=` 支持钉 digest，manifest/构建日志写明源 wheel 的 sha 与取件页；
`.gitignore` 补 `*.env`/`*.bak-*`/`key`/`*.out`/`nohup.out`/`*.pid`；
`bench-official-v1.sh`：解析到 `passed=true` 但零行数据不再打 `BENCH_OK`、密钥改走 stdin（不进宿主 `ps`）、
结果文件与目录收成 600/700；`README` 目录树补 `tools/panel/`、`bench-official-v1.sh`、`lint-package-v1.sh`。

决定**不**改的（给理由，别当成漏项）：

- 追加块与 6 个逐字文件里**不加** per-file 版权头。理由：块字节一改，产出的镜像就和这台机上量到 ＋30.5%～＋33.1% 的那一层不是同一件东西了，
  而"包里的层＝实测的层"是本包唯一硬通货。归属改由 NOTICE（上游 FlashInfer 的 Apache-2.0、wheel sha、9 件清单与 sha、
  "追加不改任何已有行"的说明）＋ manifest 逐件 sha 承担，6 个整文件本身带着上游版权头没有被动。
- 脚本不改名（`docker/build.sh`、`docker/pcieipc/install-pcieipc.sh` 仍无版本后缀）。理由：`build.sh` 是与上游源码树
  同名的官方入口，改名会让"照官方文档走"的人找不到门；版本由包版本＋`SHA256SUMS.txt` 逐件钉住。
  `Dockerfile.to20s-v1` 自称 v3、补丁脚本是 v2 这类"文件名与内容迭代不同步"保留原样，但都各自在头部注释里写清了沿革。
- 不在包内做"自动删同名容器"。理由：删别人的容器是不可逆动作，本包的规矩是只读＋只建不删。
- `版本说明.md` 不单独建。理由：`CHANGELOG.md` 已经在讲版本沿革，两份并行必漂移。

---

## v1.0 之前的既有内容

对应上游 vLLM-SM75 **0.1.7-beta**。与 0.1.6 包（v3.6）的关系是**另起一条包线**，不是原地升级：
0.1.6 包的四层补丁模型（awqple / incple / monitorfix / nvapi 烘进镜像）在 0.1.7 这条线上不适用，
0.1.7 官方已是单镜像＋宿主只读 bind NVAPI。

新增
- `docker/build.sh`：三层构建编排（官方 ultra → 20s GPU 探测超时 → FlashInfer PCIe-IPC 回填），逐层终态断言。
- `docker/pcieipc/`：PCIe-IPC 回填物料（6 个新文件＋3 个追加块＋manifest/obligations）与门禁脚本、可重推导的解包器。
- `run/start-here-v1.sh`：唯一启动入口，含共存门（同一份 console-data 只允许一个实例）、端口门、八卡门、NVAPI 哈希门。
- `run/env-check-v1.sh`：只读机器体检（GPU/驱动/内存/磁盘/shm/权重/拓扑/端口）。
- `run/profiles/flash-next-tp8-256k-nomtp.json`：官方 0.1.7 模板原样（默认值锁基线）。
- `docs/实测-面板测速对照-v1.md` ＋ `docs/bench/*.png`：同尺同机同 profile 的前后对照实测（ITL 22.9 → 17.3 ms，decode 逐档配对 ＋30.5%～＋33.1%）。
- `docs/群友提示词-PCIeIPC回填-v1.md`：给他人 AI 直接使用的自包含做法说明。

变更（相对 0.1.6 包）
- NVAPI 从"烘进镜像层"改回"宿主只读 bind"，与官方 0.1.7 文档一致；`SKIP_NVAPI` 退路保留。
- 容器参数补齐并显式化：`--memory`、`--memory-swap`、`--shm-size`、两条 `--ulimit`、端口发布；新增第四条缓存 bind `/root/.tilelang`。
- 测速口径文档化：面板 llm_speedtest 与官方 benchmark 两把尺不得混比；@150W 功耗档标注为强制。

已知限制
- PCIe-IPC 回填层是我们自维护的，官方产物点不亮；上游带上该 workspace 后应撤除。
- 同容器只翻该变量的 CLI 反向对照未跑；跨会话复现未做。
- 所有性能数字仅适用于 8 × Tesla T10（sm_75）@150 W 这一工况。
