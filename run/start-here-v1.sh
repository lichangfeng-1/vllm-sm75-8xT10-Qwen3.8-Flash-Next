#!/bin/bash
# start-here-v1.sh —— vLLM-SM75 0.1.7 自包含部署包的唯一启动入口
#
# 为什么要有这个脚本：控制台容器的启动参数一旦少一条（内存上限、shm、ulimit、某条缓存 bind），
# 表现不是"起不来"，而是"看起来一样但行为不同"——重付编译费，或者引擎被 OOM 杀。
# 所以全部显式化、每条进门禁；机器专属路径一律走环境变量，脚本里不写死。
#
# 用法：
#   DATA=/var/lib/sm75-console MODELS=/var/lib/sm75-models/Flash-Next-FP8PLE bash run/start-here-v1.sh
#   先看组装出来的命令、且确认零副作用：  ... bash run/start-here-v1.sh --dry-run
#
# 起完之后引擎不会自起（生产惯例，自起会在开机时抢卡）：去面板点「启动」，或
#   docker exec "$NAME" node /console-data/tmp/console-driver-v1.cjs start <profileId>
#   profileId 现取：docker exec "$NAME" node /console-data/tmp/console-driver-v1.cjs probe
#   （profiles.json 是 root 0600，只能走面板 API，别去读文件。这两个 .cjs 由本脚本从 tools/panel/ 摆到 $DATA/tmp/）
set -u

P=$(cd "$(dirname "$0")/.." && pwd)          # 包根，tools/panel/ 相对它

# ---------- 可覆盖参数（默认值＝官方 0.1.7 文档口径；本机漂移见 基线与口径说明-v1.md） ----------
NAME=${NAME:-sm75-017-console}
IMG=${IMG:-vllm-sm75:v0.1.7-ultra-beta-to20s-pcieipc}
DATA=${DATA:-/var/lib/sm75-console}                       # 面板数据目录（宿主侧，容器内是 /console-data）
MODELS=${MODELS:-/var/lib/sm75-models/Flash-Next-FP8PLE}  # 权重目录，只读挂成 /models
CACHE=${CACHE:-/var/lib/sm75-cache}                       # 四条 JIT/编译缓存的宿主根
# NVAPI 默认用包内这一份：文件天然在位、sha 门现成能过。
# （指到 $DATA 下那种写法会卡死人：没人先把文件拷过去，而拷文件算写操作、门禁之前又不能做。）
# 用自己从驱动里取的那份就显式 NVAPI=/你的路径；不带 P-State 就 NVAPI=none。
NVAPI=${NVAPI:-$P/docker/libnvidia-api.so.1}
ENVFILE=${ENVFILE:-$DATA/console.env}                     # 有则用它；没有则用 BOOTSTRAP_ENV
BIND_HOST=${BIND_HOST:-127.0.0.1}                         # 端口默认只绑回环；要局域网访问显式改成 0.0.0.0 并自行加鉴权
PANEL_PORT=${PANEL_PORT:-1615}                            # 控制台 Web 对外端口
API_PORT=${API_PORT:-8000}                                # 引擎 OpenAI 兼容端口对外（基线 8000；本机 18001 属漂移项）
MEM_LIMIT=${MEM_LIMIT:-120259084288}                      # 112 GiB＝官方文档值；权重加载峰值实测 110.7/112，别调低
SHM_SIZE=${SHM_SIZE:-17179869184}                         # 16 GiB＝官方文档值
RESTART=${RESTART:-no}                                    # 生产惯例：用完即停、不自起
NVAPI_SHA=4a199f9b259a1098ab9c01d31c67f882a2531a0fbb9c3595ad3d016c7d131d8c

# 最小 env 集（没有 console.env 时用）。值来自 2026-10-07 在役容器实读，不是抄文档：
#   镜像自己已带 SM75_EDITION/NCCL_P2P_LEVEL/VLLM_FIREFLY/NVIDIA_VISIBLE_DEVICES，这里只补面板行为项。
# SM75_CONSOLE_ROOT 必须是 /console-data（= bind 目标）。写成镜像默认的 /data 或别的路径，
# profiles.json 与登录 key 就会落在容器可写层里，重建容器即丢。
BOOTSTRAP_DEFAULT=(
  SM75_EDITION=ultra
  SM75_SINGLE_CONTAINER=1
  SM75_CONSOLE_ROOT=/console-data
  SM75_CONSOLE_HOST=0.0.0.0
  SM75_CONSOLE_PORT=1615
  POWER_MODE=pstate
  PSTATE_GPUS=0,1,2,3,4,5,6,7
  PSTATE_IDLE_TIMEOUT=86400
  TZ=Asia/Shanghai
  NVIDIA_VISIBLE_DEVICES=all
)
# 覆盖口用分号而不是逗号：PSTATE_GPUS 这类值本来就含逗号，用逗号当分隔符会把值切碎，
# 碎出来的 "-e 1" 变成"透传宿主变量 1"＝静默丢值。切完还逐片验形状，不合规就 BLOCK。
# 约定：BOOTSTRAP_ENV="" 或没设 ⇒ 用包内默认集（这是安全侧，不是"什么都不发"）；
#       设了内容但不合规（例如只有分号）⇒ 门禁 BLOCK。静默零 env 起跑是最坏的形态。
BOOTSTRAP=()
if [ -n "${BOOTSTRAP_ENV:-}" ]; then
  IFS=';' read -ra BOOTSTRAP <<< "$BOOTSTRAP_ENV"
else
  BOOTSTRAP=("${BOOTSTRAP_DEFAULT[@]}")
fi
# NVAPI=none 却仍带 POWER_MODE=pstate ＋ PSTATE_* 是自相矛盾（面板会拒绝启引擎）。
# 显式不带 P-State 库时，默认集跟着换成 sleep——不留"记得手工改"的坑。
if [ "$NVAPI" = "none" ]; then
  nb=()
  for kv in "${BOOTSTRAP[@]}"; do
    case "$kv" in
      POWER_MODE=*) nb+=(POWER_MODE=sleep) ;;
      PSTATE_*) : ;;
      *) nb+=("$kv") ;;
    esac
  done
  BOOTSTRAP=("${nb[@]}")
fi
# 注意：BOOTSTRAP_ENV=""（或只有分号）会切出空数组 ⇒ 一个 -e 都不发。这个后果留到门禁里判
# （见下面"最小 env 集"那一项），不在这里报错——那时 bad()/fail 还没定义，写了也不算数。

DRY=no
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=yes ;;
    *) echo "用法：bash run/start-here-v1.sh [--dry-run]"; exit 2 ;;
  esac
done

fail=no
good() { echo "  PASS $*"; }
bad() { echo "  BLOCK $*"; fail=yes; }
warn() { echo "  WARN  $*"; }
# --dry-run 什么都不写、什么都不起，所以只把"拦的是真起容器这一步"的两项（同名容器在册、卡被占用）
# 降级成 WARN，方便在生产机上半夜预演命令；其余门禁在 dry-run 里照样 BLOCK。
msg() { if [ "$DRY" = "yes" ]; then warn "$*"; else bad "$*"; fi; }

echo "=== 1) 门禁（任一 BLOCK ⇒ 立刻退出，本脚本一次写操作都不会做）==="
if docker image inspect "$IMG" >/dev/null 2>&1; then
  good "镜像 $(docker image inspect -f '{{.Id}}' "$IMG" | cut -c8-19) $IMG"
else bad "镜像不在位 $IMG（先跑 docker/build.sh；绝不隐式拉取）"; fi

# 同名容器：本包**不删、不停任何容器**（哪怕同名）。想复用名字就人工删掉再跑，或换个 NAME。
if docker inspect "$NAME" >/dev/null 2>&1; then
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ]; then
    msg "同名容器 $NAME 正在跑。处置：docker stop $NAME（确认它不是别人在用的），或换 NAME=新名字"
  else
    msg "同名容器 $NAME 已停但仍在册，docker run 必然 name conflict。处置：docker rm $NAME 后重跑，或换 NAME=新名字"
  fi
else good "容器名 $NAME 空闲"; fi

# 共存门：同一份 DATA 只能有一个控制台实例（profiles.json 会被整体重写覆盖）
sib=""
for cid in $(docker ps -q 2>/dev/null); do
  if docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$cid" 2>/dev/null | grep -q "^$DATA:"; then
    nm=$(docker inspect -f '{{.Name}}' "$cid" | sed 's|^/||')
    [ "$nm" = "$NAME" ] && continue
    sib="$sib $nm"
  fi
done
if [ -n "$sib" ]; then bad "已有容器占着 $DATA（同时跑会互相覆盖 profiles.json）:$sib"; else good "无其它控制台实例共享 $DATA"; fi

# 端口门：docker port 按**容器端口**列（形如 8000/tcp -> 0.0.0.0:18001），
# 所以必须匹配行尾的宿主端口；用 "^$宿主口/" 匹配永远匹配不到 —— 这是我们自己踩出的假放行。
port_holder() {
  for c in $(docker ps -q 2>/dev/null); do
    if docker port "$c" 2>/dev/null | grep -qE ":$1\$"; then
      docker inspect -f '{{.Name}}' "$c" | sed 's|^/||'; return 0
    fi
  done
}
for hp in "$PANEL_PORT" "$API_PORT"; do
  holder=$(port_holder "$hp")
  if [ -z "$holder" ] && command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]$hp[[:space:]]"; then
    holder="(宿主上有进程在听，非容器)"
  fi
  if [ -n "$holder" ]; then msg "宿主端口 $hp 被 $holder 占着（真起容器会撞端口；--dry-run 只看组装，故降为 WARN）"; else good "宿主端口 $hp 空闲"; fi
done

busy=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '$1>1000{n++} END{print n+0}')
n_gpu=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -dc '0-9')
if [ "${n_gpu:-0}" != "8" ]; then bad "nvidia-smi 读到 ${n_gpu:-0} 张卡，期望 8";
elif [ "${busy:-9}" != "0" ]; then msg "$busy 张卡仍占用>1GiB，先确认是谁在用（真起容器会和它抢卡）"; else good "八卡全空"; fi

# 权重目录：既接受"MODELS 就是模型目录"（我们生产即此形态），也接受"MODELS 是父目录"（官方模板 defaultModel 的写法）
if [ -f "$MODELS/config.json" ]; then
  good "权重目录在位（模型目录本身）$MODELS"
elif ls "$MODELS"/*/config.json >/dev/null 2>&1; then
  good "权重目录在位（父目录，内含 $(ls -d "$MODELS"/*/config.json 2>/dev/null | wc -l | tr -dc '0-9') 个模型）：$MODELS"
  warn "面板注册时要用子目录路径；官方模板 defaultModel=/models/<子目录名> 就是这种挂法"
else bad "在 $MODELS 及其一级子目录里都没找到 config.json —— 权重没就位，后面全部免谈"; fi

if [ -s "$ENVFILE" ]; then
  # 只认"变量名里带密钥类字样"的行（锚到 = 号前的名字），不按值匹配：
  # 原写法 `.*TOKEN=` 之类会被 `VLLM_SOMETHING=autoTOKEN=x` 这种值命中、也会被正常变量名误伤。
  if grep -qE '^[A-Za-z0-9_]*(API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL)=' "$ENVFILE"; then
    bad "env-file 里有密钥类变量（名字含 API_KEY/TOKEN/SECRET/PASSWORD/PRIVATE_KEY/CREDENTIAL），先剔除"
    echo "        命中项：$(grep -oE '^[A-Za-z0-9_]*(API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL)' "$ENVFILE" | tr '\n' ' ')"
  else
    perm=$(stat -c '%a' "$ENVFILE" 2>/dev/null || stat -f '%Lp' "$ENVFILE" 2>/dev/null || echo 未知)
    good "env-file $(grep -c '^' "$ENVFILE") 条、权限 $perm、无密钥类"
    root=$(grep -E '^SM75_CONSOLE_ROOT=' "$ENVFILE" | tail -1 | cut -d= -f2-)
    if [ -z "$root" ]; then
      # 没写不等于没事：镜像自带默认是 /data，那在容器可写层里，重建就把 profiles.json 与登录 key 一起丢掉
      bad "env-file 里没有 SM75_CONSOLE_ROOT ⇒ 面板会退回镜像默认的 /data（容器可写层，重建即丢）。补一行 SM75_CONSOLE_ROOT=/console-data"
    elif [ "$root" != "/console-data" ]; then
      bad "env-file 里 SM75_CONSOLE_ROOT=$root，不是 /console-data（＝$DATA 那条 bind 的目标）⇒ 档与登录 key 不落宿主"
    else good "env-file 里 SM75_CONSOLE_ROOT=/console-data（与 bind 目标一致）"; fi
  fi
else
  if [ "${#BOOTSTRAP[@]}" = "0" ]; then
    # 手滑写成 BOOTSTRAP_ENV="" 或 ";" 时会切出空数组：一个 -e 都不发，而其余门禁照样全绿 ⇒
    # 面板把 profiles.json 写进镜像默认的 /data 而不是 bind 里的 /console-data（＝B2 那个"重建即丢"）。
    bad "BOOTSTRAP_ENV 切出来是 0 项（分隔符是分号不是逗号）。处置：给它正常内容，或 unset 它改用包内默认集（${#BOOTSTRAP_DEFAULT[@]} 条）"
  else
    badenv=""
    secretenv=""
    for kv in "${BOOTSTRAP[@]}"; do
      printf '%s' "$kv" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^;]+$' || badenv="$badenv [$(printf '%s' "$kv" | cut -c1-24)…]"
      # 名字判据与 env-file 那一条同一套，只报变量名、绝不回显值
      printf '%s' "$kv" | grep -qE '^[A-Za-z0-9_]*(API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL)='         && secretenv="$secretenv [$(printf '%s' "$kv" | cut -d= -f1)]"
    done
    if [ -n "$badenv" ]; then
      bad "BOOTSTRAP_ENV 里有不合规片段（每项须为 KEY=VALUE，分隔符是分号不是逗号；值含逗号是允许的）:$badenv"
    elif [ -n "$secretenv" ]; then
      bad "BOOTSTRAP_ENV 里有密钥类变量:$secretenv —— 走 -e 会把值写进本脚本 stdout 与宿主 docker run 的 argv（谁 ps 都看得到）。处置：把它们放进 $ENVFILE（chmod 600，本脚本走 --env-file），或从覆盖口里去掉"
    else
      good "无 env-file，本次用最小 env 集 ${#BOOTSTRAP[@]} 条：$(printf '%s ' "${BOOTSTRAP[@]}" | cut -d= -f1 | tr -s ' ' ' ' | cut -c1-160)…"
      warn "跑起来后建议用 tools/gen-console-env-v1.sh 固化成 $ENVFILE（走 --env-file 值不进 argv），别再依赖默认集"
    fi
  fi
fi

if [ "$NVAPI" = "none" ]; then
  warn "NVAPI=none：不挂 P-State 库。必须把 profile 的 power.mode 设成 sleep，否则面板拒绝启引擎"
else
  if [ -f "$NVAPI" ]; then
    got=$(sha256sum "$NVAPI" | cut -d' ' -f1)
    if [ "$got" = "$NVAPI_SHA" ]; then good "NVAPI sha256 与包内一致"; else bad "NVAPI 哈希不符 期望 $NVAPI_SHA 实为 $got"; fi
  else bad "缺 NVAPI 文件 $NVAPI（面板会拒绝启引擎；见 docker/NVAPI-获取说明-v1.md，或显式 NVAPI=none 走 sleep）"; fi
fi

# 余量分两块看：镜像层落在根盘，profiles/缓存/env-file 落在 $DATA 与 $CACHE 所在盘——
# 只查根盘会漏（DATA 指到 /data 这种另一块盘的路径时，根盘余量说明不了它能不能写）。
nearest_exists() {
  d="$1"
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d=$(dirname "$d"); done
  printf '%s' "$d"
}
avail=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
if [ "${avail:-0}" -ge 40 ]; then good "根盘余量 $avail GiB（镜像层用）"; else bad "根盘余量 $avail GiB < 40"; fi
for where in "$DATA" "$CACHE"; do
  tgt=$(nearest_exists "$where")
  a2=$(df -BG --output=avail "$tgt" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -z "$a2" ]; then warn "$where 所在盘读不到余量（df 失败），跳过这一项"
  elif [ "$tgt" = "/" ]; then good "$where 就在根盘（$a2 GiB）"
  elif [ "$a2" -ge 20 ]; then good "$where 所在盘（$tgt）余量 $a2 GiB"
  else bad "$where 所在盘（$tgt）余量只有 $a2 GiB < 20（面板数据与四条缓存都写这里）"; fi
done

# 包内面板 CLI 工具（B10：不发这两个文件，别人照包跑就点不亮那个后端）
for f in console-driver-v1.cjs console-edit-profile-v1.cjs; do
  [ -s "$P/tools/panel/$f" ] || bad "包里缺 tools/panel/$f"
done

if [ "$fail" = "yes" ]; then
  echo "GATE_FAIL 上面 BLOCK 项已清零之前，本脚本没有做过任何写操作（没建目录、没 chmod、没拷文件、没起容器）"
  exit 4
fi

echo "=== 2) 组装 docker run（纯计算，不写任何东西）==="
ENVARGS=()
if [ -s "$ENVFILE" ]; then
  ENVARGS=(--env-file "$ENVFILE")
else
  for kv in "${BOOTSTRAP[@]}"; do ENVARGS+=(-e "$kv"); done
fi
PUBS=(--publish "$BIND_HOST:$PANEL_PORT:1615/tcp" --publish "$BIND_HOST:$API_PORT:8000/tcp")
VOL=(--volume "$MODELS:/models:ro"
     --volume "$DATA:/console-data"
     --volume "$CACHE/root-cache:/root/.cache"
     --volume "$CACHE/triton:/root/.triton"
     --volume "$CACHE/nv:/root/.nv"
     --volume "$CACHE/tilelang:/root/.tilelang")
if [ "$NVAPI" != "none" ]; then
  VOL+=(--volume "$NVAPI:/usr/local/nvidia/lib64/libnvidia-api.so.1:ro")
fi
# 镜像的 ENTRYPOINT 已经是 "python3 /opt/vllm-sm75/runtime-entrypoint.py"、CMD 为空，
# 所以这里**只传镜像名**：再把那两句当命令传一遍，它们就会被当成 vllm 的参数吃掉。
CMD=(docker run -d --name "$NAME" --gpus all
     --memory "$MEM_LIMIT" --memory-swap "$MEM_LIMIT" --shm-size "$SHM_SIZE"
     --restart "$RESTART" --network bridge
     --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576
     "${PUBS[@]}" "${ENVARGS[@]}" "${VOL[@]}"
     "$IMG")
printf '  %q ' "${CMD[@]}"; echo

if [ "$DRY" = "yes" ]; then
  echo "DRY_RUN_OK 上面就是将要执行的命令。将要写的东西（本次一律没做）："
  echo "    mkdir -p $CACHE/{root-cache,triton,nv,tilelang} 与 $DATA/tmp；chmod 700 $DATA"
  echo "    cp tools/panel/*.cjs -> $DATA/tmp/"
  echo "  本次没有建目录、没有 chmod、没有拷文件、没有起容器。"
  exit 0
fi

echo "=== 3) 目录与面板 CLI 工具就绪（门禁通过且非 dry-run 才动手写）==="
# 四条缓存 bind 必须全在位，少一条重建容器就重付编译费（.tilelang 最容易漏）
for d in root-cache triton nv tilelang; do mkdir -p "$CACHE/$d" || { echo "WRITE_FAIL 建不出缓存目录 $CACHE/$d"; exit 3; }; done
mkdir -p "$DATA/tmp" || { echo "WRITE_FAIL 建不出 $DATA/tmp"; exit 3; }
chmod 700 "$DATA" 2>/dev/null
for f in console-driver-v1.cjs console-edit-profile-v1.cjs; do
  cp "$P/tools/panel/$f" "$DATA/tmp/$f" || { echo "WRITE_FAIL 拷不进 $DATA/tmp/$f"; exit 3; }
done
echo "  已就绪：$CACHE/{root-cache,triton,nv,tilelang}、$DATA(700)、$DATA/tmp/{console-driver-v1.cjs,console-edit-profile-v1.cjs}"

echo "=== 4) 起容器并等面板有响应（最多 3 分钟）==="
"${CMD[@]}" || { echo "RUN_FAIL docker run 非零退出"; exit 5; }
ok=no
for i in $(seq 1 36); do
  code=$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:1615/" 2>/dev/null)
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then ok=yes; echo "  PANEL_UP try=$i code=$code"; break; fi
  sleep 5
done
[ "$ok" = "yes" ] || { echo "BLOCK 面板 3 分钟没响应，容器日志尾 30 行："; docker logs --tail 30 "$NAME" 2>&1; exit 6; }

echo "=== 5) 终态自检（断言产物，不是打印看看）==="
check_fail=no
cf() { echo "  ASSERT_FAIL $*"; check_fail=yes; }

# 5.1 端口映射真在位，且绑的是预期地址（BIND_HOST=127.0.0.1 时外部机器连不上，这是有意的）
maps=$(docker port "$NAME" 2>/dev/null)
for cp in 1615 8000; do
  if printf '%s' "$maps" | grep -qE "^$cp/tcp -> $BIND_HOST:"; then
    echo "  PASS 映射 $cp/tcp -> $BIND_HOST:$(printf '%s' "$maps" | awk -v c="$cp" '$1 ~ "^"c"/"{split($3,a,":");print a[2]}')"
  else cf "缺少 $cp/tcp -> $BIND_HOST: 的映射（实际：$(printf '%s' "$maps" | tr '\n' ' '))"; fi
done

# 5.2 PCIe-IPC 层：镜像带 sm75.t11a.component 标签才断言 hasattr=True（不带该层的镜像 False 是正常的，不能当失败）
if [ "$(docker image inspect -f '{{index .Config.Labels "sm75.t11a.component"}}' "$IMG" 2>/dev/null)" = "flashinfer-pcie-ipc-backport" ]; then
  hv=$(docker exec "$NAME" python3 -c \
        'import flashinfer.comm as c;print("True" if hasattr(c,"PcieIpcAllReduceWorkspace") else "False")' 2>/dev/null)
  if [ "$hv" = "True" ]; then echo "  PASS hasattr(flashinfer.comm,'PcieIpcAllReduceWorkspace') = True（vLLM 的判据）"
  else cf "镜像自称带 pcie-ipc 层，但 hasattr=$hv"; fi
else
  warn "该镜像没有 sm75.t11a.component 标签（未回填 PCIe-IPC）⇒ 跳过 hasattr 断言，后端会是 FIREFLY_AR"
fi

# 5.3 20s 层：同理按标签决定断言与否
if [ "$(docker image inspect -f '{{index .Config.Labels "sm75.localpatch"}}' "$IMG" 2>/dev/null)" = "gpu-probe-timeout-3s-to-20s" ]; then
  n=$(docker exec "$NAME" grep -cE 'timeout: 20000([^0-9]|$)' /opt/sm75-workbench/console/server.mjs 2>/dev/null)
  if [ "${n:-0}" = "1" ]; then echo "  PASS server.mjs 内 timeout: 20000 恰好 1 处"
  else cf "server.mjs 的 timeout: 20000 命中 ${n:-0} 处（期望 1）"; fi
else
  warn "该镜像没有 sm75.localpatch 标签（未打 20s 层）⇒ 跳过断言；本机 hardware.py 要 6.0–6.9 s，面板可能拒启"
fi

# 5.4 容器内 /console-data 确实指向那条 bind（看挂载表，不看"我 --volume 过"）
if docker inspect -f '{{range .Mounts}}{{.Destination}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep -qx "/console-data"; then
  echo "  PASS /console-data 在挂载表里"
else cf "/console-data 不在挂载表里（面板数据会落在容器可写层）"; fi

# 5.5 面板 CLI 工具真的在容器里看得见
for f in console-driver-v1.cjs console-edit-profile-v1.cjs; do
  if docker exec "$NAME" test -s "/console-data/tmp/$f"; then echo "  PASS 容器内可见 /console-data/tmp/$f"
  else cf "/console-data/tmp/$f 在容器里看不到（bind 映射没生效？）"; fi
done

if [ "$check_fail" = "yes" ]; then
  echo "DONE_WITH_FAILS 容器起了但终态断言没过 —— 别按成功用；上面 ASSERT_FAIL 每条都要解决或显式撤回该层"
  exit 7
fi
echo "RUN_DONE 全部终态断言通过"
echo "  浏览器：http://$BIND_HOST:$PANEL_PORT　　API：http://$BIND_HOST:$API_PORT/v1"
[ "$BIND_HOST" = "127.0.0.1" ] && echo "  默认只绑回环：要局域网访问请显式 BIND_HOST=0.0.0.0 重跑，并自行加 --api-key 与网络边界控制"
echo "  起引擎：面板点「启动」，或 docker exec $NAME node /console-data/tmp/console-driver-v1.cjs probe 取 profileId 后 start"
echo "  引擎就绪判据（日志）：dispatch 列表含 FLASHINFER_PCIE_IPC、Initialized FlashInfer PCIe IPC all-reduce、"
echo "    GPU KV cache size: 339,110 tokens、FP8 layout verified 96 条、backend=p2p 8 条、无 Traceback。"
echo "  撤回填层：SKIP_PCIEIPC=1 bash docker/build.sh 重出不带该层的镜像，再用本脚本换 IMG 起。"
