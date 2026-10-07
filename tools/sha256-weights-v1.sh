#!/bin/bash
# sha256-weights-v1.sh — 用官方 docs/models/flash-next-tested.sha256 全量对拍权重目录的 34 项
#
# 34 项的构成（2026-10-07 在官方 tested 修订 ef55414 上实数）：
#   15 张主分片（model-*-of-00017 里在场 15 张，编号 00002/00016 本来就不在这份清单里，不是缺件）
#   ＋ 10 张 model-plefp8-*.safetensors
#   ＋ 9 项其它（根层 config/tokenizer/tokenizer_config/chat_template/index，runtime/mtp-int4-g32/ 下 4 项）
#
# 只读：只对哈希，不写权重目录；nice+ionice 降优先级，避免抢正在跑的引擎。
# 用法：bash tools/sha256-weights-v1.sh /你的/权重目录
#       也支持 MODELS=/路径 MANIFEST=/路径/flash-next-tested.sha256 bash tools/sha256-weights-v1.sh
# 退出码：0=全部逐字节相同；非 0=目录/清单/缺件/哈希任何一环不对（别让"INCOMPLETE"变成成功）
set -u
P=$(cd "$(dirname "$0")" && pwd)           # tools/
D=$(cd "$P/.." && pwd)                     # 包根

case "${1:-}" in
  -h|--help) echo "用法：bash tools/sha256-weights-v1.sh [权重目录]（或 MODELS=/路径）"; exit 0 ;;
  "") : ;;
  -*|--*) echo "ARGS_BAD 位置参数只接受权重目录，收到：$1"; exit 2 ;;
  *) M="$1" ;;
esac
M=${M:-${MODELS:-/var/lib/sm75-models/Flash-Next-FP8PLE}}
# 清单路径必须**在 cd 之前**定成绝对路径：上一版默认 tools/flash-next-tested.sha256 是相对包根的，
# 脚本中途 cd 到权重目录后再把相对路径交给 sha256sum -c，就变成"从权重目录里找 tools/…"＝必然读不到。
MAN=${MANIFEST:-$D/tools/flash-next-tested.sha256}
case "$MAN" in
  /*) : ;;
  *) MAN=$(cd "$(dirname "$MAN")" 2>/dev/null && pwd)/$(basename "$MAN") ;;
esac
OUT=${OUT:-/tmp/weights-sha256-v1}
LOG="$OUT/run.log"
EXPECT_N=${EXPECT_N:-34}

[ -d "$M" ] || { echo "NO_MODEL_DIR $M"; exit 1; }
[ -f "$MAN" ] || { echo "NO_MANIFEST $MAN"; exit 1; }
[ -s "$MAN" ] || { echo "EMPTY_MANIFEST $MAN"; exit 1; }

# 清单形状先验：每行必须是 "<64 位十六进制>  <相对路径>"（两个空格），路径不得是绝对路径或含 ..
badfmt=$(awk 'NF<2 || $1 !~ /^[0-9a-fA-F]{64}$/ {print NR": "$0}' "$MAN" | head -4)
[ -z "$badfmt" ] || { echo "MANIFEST_FORMAT_BAD 以下行不像 sha256sum 清单：$badfmt"; exit 2; }
badpath=""
while IFS= read -r line; do
  f=$(printf '%s' "$line" | sed -E 's/^[0-9a-fA-F]{64}[ \t]+//; s/^\*//')
  [ -n "$f" ] || { badpath="$badpath [空路径]"; continue; }
  case "$f" in /*|../*|*"/../"*) badpath="$badpath [$f]" ;; esac
done < "$MAN"
[ -n "$badpath" ] && { echo "MANIFEST_PATH_BAD 清单里出现绝对路径或 .. （会把校验引到目录外）：$badpath"; exit 2; }

N=$(grep -c . "$MAN")
echo "manifest=$MAN"
echo "manifest_lines=$N"
if [ "$N" != "$EXPECT_N" ]; then echo "MANIFEST_UNEXPECTED 期望 $EXPECT_N 项，先别跑（清单被改过或版本不同）"; exit 2; fi

# 每一项都得在场，否则 sha256sum -c 会把 "Could not open" 当噪声混进失败计数
MISSING=0
while IFS= read -r line; do
  f=$(printf '%s' "$line" | sed -E 's/^[0-9a-fA-F]{64}[ \t]+//; s/^\*//')
  [ -f "$M/$f" ] || { echo "ABSENT_IN_DIR $f"; MISSING=$((MISSING + 1)); }
done < "$MAN"
echo "missing_before_run=$MISSING"
if [ "$MISSING" != "0" ]; then echo "FILES_MISSING 先停，别把缺件当成对拍失败"; exit 3; fi

mkdir -p "$OUT" || exit 1
cd "$M" || exit 1
du -sb . | awk '{printf "dir_gib=%.2f\n", $1/1073741824}'

t0=$(date +%s)
if command -v ionice >/dev/null 2>&1; then
  nice -n 19 ionice -c3 sha256sum -c "$MAN" > "$LOG" 2>&1
else
  nice -n 19 sha256sum -c "$MAN" > "$LOG" 2>&1
fi
rc=$?
t1=$(date +%s)

ok=$(grep -c ': OK$' "$LOG")
# 只数"某文件 FAILED"的行；sha256sum 自己那行汇总（sha256sum: WARNING: 1 computed ...）单独计数，
# 否则 1 个坏文件会报成 bad=2，看着像对不上账。
bad=$(grep -c ': FAILED$' "$LOG")
sumwarn=$(grep -c '^sha256sum: WARNING' "$LOG")
err=$(grep -cE ': FAILED open or read|Could not (open|read)' "$LOG")
secs=$((t1 - t0))
echo "rc=$rc ok=$ok bad=$bad unreadable=$err summary_warning_lines=$sumwarn secs=$secs log=$LOG"
grep -E ': FAILED|Could not (open|read)' "$LOG" | head -12
if [ "$ok" = "$N" ] && [ "$bad" = "0" ] && [ "$err" = "0" ] && [ "$rc" = "0" ]; then
  echo "SHA_VERIFY_PASS $ok/$N 全部逐字节相同"
  exit 0
fi
echo "SHA_VERIFY_INCOMPLETE ok=$ok/$N bad=$bad err=$err rc=$rc —— 权重不是官方 tested 修订，后面所有吞吐数字都失去可比性"
exit 6
