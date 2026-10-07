#!/bin/bash
# env-check-v1.sh —— 装 0.1.7 之前的机器体检：只读，不改任何东西、不装任何包
#
# 判据分三档：
#   PASS   满足基线
#   WARN   能跑但会掉性能/会踩坑（附原因）
#   BLOCK  不满足基线，先解决再往下走
# 阈值来源：官方 0.1.7 文档 + 我们在 G292-Z20 / 8×T10 上的实测常量（见 基线与口径说明-v1.md）。
#
# 退出码：有 BLOCK ⇒ 非零（0=干净，4=有 BLOCK，3=用法错）。
# 这条是必须的：docker/build.sh 与 部署文档 教的是 `env-check && start-here`，
# 有 BLOCK 还 exit 0 等于把 && 的门自己拆了。
set -u
REQ_GPU_COUNT=${REQ_GPU_COUNT:-8}
REQ_GPU_MIB=${REQ_GPU_MIB:-15000}          # T10 可见 15.56 GiB ≈ 15933 MiB，留余量取 15000
REQ_RAM_G=${REQ_RAM_G:-110}                # 官方要求总内存 ≥128 GiB；这里是"宿主可用"门（容器上限 112 GiB 得压得住）
REQ_DISK_G=${REQ_DISK_G:-40}
REQ_WEIGHT_G=${REQ_WEIGHT_G:-120}
MIN_DRIVER=${MIN_DRIVER:-570}
# 权重目录：位置参数优先，其次 MODELS，最后默认（和 tools/sha256-weights-v1.sh 同一套口径）
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "用法：bash run/env-check-v1.sh [权重目录]     （或 MODELS=/路径 bash run/env-check-v1.sh）"; exit 0
fi
case "${1:-}" in
  "") : ;;
  -*|*=*) echo "ARGS_BAD 位置参数只接受权重目录，收到：$1"; exit 3 ;;
  *) MODELS="$1" ;;
esac
MODELS=${MODELS:-/var/lib/sm75-models/Flash-Next-FP8PLE}
BLOCKS=0

p() { echo "  PASS  $*"; }
w() { echo "  WARN  $*"; }
b() { echo "  BLOCK $*"; BLOCKS=$((BLOCKS + 1)); }
i() { echo "  信息  $*"; }

echo "=== 1) 操作系统与内核 ==="
if [ -r /etc/os-release ]; then . /etc/os-release; i "$PRETTY_NAME / 内核 $(uname -r) / $(uname -m)"; fi
command -v docker >/dev/null 2>&1 && i "docker $(docker --version 2>/dev/null | cut -d, -f1)" || b "没有 docker"
command -v nvidia-smi >/dev/null 2>&1 || b "没有 nvidia-smi（驱动未装或未在 PATH）"

echo "=== 2) GPU 数量、型号、显存、计算能力 ==="
if command -v nvidia-smi >/dev/null 2>&1; then
  n=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -dc '0-9')
  [ "${n:-0}" = "$REQ_GPU_COUNT" ] && p "GPU 数 $n" || b "GPU 数 ${n:-0}，期望 $REQ_GPU_COUNT"
  nvidia-smi --query-gpu=index,name,memory.total,compute_cap --format=csv,noheader 2>/dev/null | sed 's/^/        /'
  low=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk -v m="$REQ_GPU_MIB" '$1<m{c++} END{print c+0}')
  [ "${low:-0}" = "0" ] && p "所有卡显存 ≥ ${REQ_GPU_MIB} MiB" || b "$low 张卡显存低于 ${REQ_GPU_MIB} MiB"
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ' ')
  i "计算能力集合=$cc（本包按 sm_75 实测；其它架构的数字不可套用）"
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '$1>1000{c++} END{print c+0}')
  [ "${used:-0}" = "0" ] && p "八卡当前空闲" || w "$used 张卡已被占用（挖矿/其它容器会抢卡，先确认）"
  lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ' ')
  i "功耗上限=$lim（性能锚点与功耗档绑定，跨档数字不可同表比较）"
fi

echo "=== 3) 驱动与 CUDA ==="
dver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
maj=$(printf '%s' "${dver:-0}" | cut -d. -f1)
if [ "${maj:-0}" -ge "$MIN_DRIVER" ]; then p "驱动 $dver ≥ $MIN_DRIVER"; else b "驱动 $dver 低于 $MIN_DRIVER"; fi
i "引擎内 CUDA 12.9（容器自带，不依赖宿主 toolkit；宿主有 toolkit 也不要拿它当依据）"

echo "=== 4) 内存 / 磁盘 / shm ==="
freeg=$(free -g | awk 'NR==2{print $7}')
[ "${freeg:-0}" -ge "$REQ_RAM_G" ] && p "宿主可用内存 ${freeg} GiB" || b "可用内存 ${freeg} GiB < $REQ_RAM_G（权重加载峰值实测 110.7 GiB）"
dg=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "${dg:-0}" -ge "$REQ_DISK_G" ] && p "根盘余量 $dg GiB" || b "根盘余量 $dg GiB < $REQ_DISK_G"
wg=$(df -BG --output=avail "$(dirname "$MODELS")" 2>/dev/null | tail -1 | tr -dc '0-9')
i "权重所在盘余量 ${wg:-?} GiB（权重约 $REQ_WEIGHT_G GiB）"
sm=$(df -BG --output=avail /dev/shm 2>/dev/null | tail -1 | tr -dc '0-9')
i "/dev/shm 容量 ${sm:-?} GiB（容器 shm-size 16 GiB，宿主 tmpfs 要够）"

echo "=== 5) 权重目录完整性（只查存在与分片数，不读内容）==="
if [ -f "$MODELS/config.json" ]; then
  p "config.json 在位"
  # 口径（2026-10-07 在官方 tested 修订 ef55414 的目录里实数）：
  #   15 张主分片 + 10 张 plefp8 + 9 项其它（根层 5 个 json/jinja + runtime/mtp-int4-g32/ 下 4 项）= 清单 34 项。
  #   文件名里的 -of-00017 是官方编号；这一修订在场的是 15 张，编号 00002 与 00016 本来就不在里面，
  #   不是缺件，别按"25 张主分片"去判（那是另一条线的账）。
  nm=$(ls "$MODELS"/model-[0-9]*-of-*.safetensors 2>/dev/null | wc -l | tr -dc '0-9')
  np=$(ls "$MODELS"/model-plefp8-*.safetensors 2>/dev/null | wc -l | tr -dc '0-9')
  [ "${nm:-0}" -ge 15 ] && p "主分片 $nm 张（官方 tested 修订在场 15 张，清单里没有 00002/00016）" \
                        || b "主分片只有 ${nm:-0} 张，少于清单里的 15 张，先补齐再跑"
  [ "${np:-0}" -ge 10 ] && p "plefp8 分片 $np 张" || b "plefp8 分片只有 ${np:-0} 张，期望 10"
  for f in tokenizer.json chat_template.jinja model.safetensors.index.json runtime/mtp-int4-g32/mtp-dense.safetensors; do
    [ -f "$MODELS/$f" ] && p "$f 在位" || b "缺 $f"
  done
  i "全量哈希校验：bash tools/sha256-weights-v1.sh \"$MODELS\"（34 项＝15 主＋10 plefp8＋9 其它，约 2 分钟，nice+ionice 不扰引擎）"
else
  b "缺 $MODELS/config.json —— 权重没就位，后面全部免谈"
fi

echo "=== 6) PCIe 拓扑（只读；影响 allreduce 选型）==="
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi topo -m 2>/dev/null | head -14 | sed 's/^/        /'
  i "本包那层 PCIe-IPC 回填面向的就是无 NVLink 的 PCIe 机器；有 NVLink 的机器收益结构不同"
fi

echo "=== 7) 端口与共存 ==="
for hp in ${PANEL_PORT:-1615} ${API_PORT:-8000}; do
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]$hp[[:space:]]"; then w "宿主端口 $hp 已被监听（启动入口会拦，先腾出来）"; else p "宿主端口 $hp 空闲"; fi
done
n=$(docker ps -q 2>/dev/null | wc -l | tr -dc '0-9')
i "当前在跑容器 $n 个；若其中有占八卡或共享同一份 console-data 的，启动入口会拒绝"

if [ "$BLOCKS" -gt 0 ]; then
  echo "ENV_CHECK_FAIL BLOCK=$BLOCKS（先解决这些再跑 docker/build.sh 与 run/start-here-v1.sh）"
  exit 4
fi
echo "ENV_CHECK_DONE BLOCK=0，可以跑 docker/build.sh 与 run/start-here-v1.sh"
