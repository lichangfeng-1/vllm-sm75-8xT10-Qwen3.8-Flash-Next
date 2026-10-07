#!/bin/bash
# bench-official-v1.sh —— 用官方随包尺子 benchmark_flash_next.py 测速，参数锁死成"与文档同口径"
#
# 为什么固定这些参数：官方文档那张表的口径是 2 次预热 + 7 次正式取中位、长档各 1 次、输出 512、mixed 组，
# 换任何一项数字都不可比。脚本把尺子钉住，只让你传容器与标签。
#
# 用法：LABEL=mine-01 bash tools/bench-official-v1.sh
#   CONTAINER=<容器名>  默认 sm75-017-console
#   TOOL=<容器内路径>   默认自动探测（镜像里没装就按提示拷进去）
#   SIZES=8192,130560,261632  OUT_TOKENS=512  WARMUPS=2  REPEATS=7  LONG_REPEATS=1
#
# 判成功的终态（不是"跑完了"）：
#   末行 JSON 里 passed=true；每行 cached_tokens=0、preemptions=0、drafted=0（无投机）；
#   任一不满足就报 BENCH_NOT_COMPARABLE，不给你可比的数字。
set -u
CONTAINER=${CONTAINER:-sm75-017-console}
LABEL=${LABEL:?必须给 LABEL（官方尺子拒绝覆盖同名标签，正好当防重跑保险）}
SIZES=${SIZES:-8192,130560,261632}
OUT_TOKENS=${OUT_TOKENS:-512}
WARMUPS=${WARMUPS:-2}
REPEATS=${REPEATS:-7}
LONG_REPEATS=${LONG_REPEATS:-1}
MODEL=${MODEL:-http://127.0.0.1:8000}
MODEL_NAME=${MODEL_NAME:-Flash-Next-TP8}
ROOT=${ROOT:-/console-data/bench-official}
OUTDIR=${OUTDIR:-/tmp/bench-official}
mkdir -p "$OUTDIR" || exit 2
chmod 700 "$OUTDIR" 2>/dev/null            # 里面是测速原始输出，别留 644 给同机其他人

docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "BLOCK 容器不在 $CONTAINER"; exit 2; }
h=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' "$MODEL/health" 2>/dev/null)
[ "$h" = "200" ] || { echo "BLOCK 引擎未就绪（$MODEL/health=$h），先起引擎"; exit 3; }

echo "=== 1) 定位尺子 ==="
if [ -n "${TOOL:-}" ]; then cands="$TOOL"; else
  cands="/opt/vllm-sm75/tools/benchmark_flash_next.py /opt/vllm-sm75/benchmark_flash_next.py /console-data/tmp/tools/benchmark_flash_next.py"
fi
TOOLFOUND=""
for c in $cands; do
  if docker exec "$CONTAINER" sh -c "test -f $c" 2>/dev/null; then TOOLFOUND=$c; break; fi
done
if [ -z "$TOOLFOUND" ]; then
  echo "BLOCK 容器里找不到 benchmark_flash_next.py。它随 0.1.7 源码发布（源码树 tools/ 目录），"
  echo "      拷法（走已 bind 的 /console-data，别用 docker cp）："
  echo "        docker exec $CONTAINER sh -c 'mkdir -p /console-data/tmp/tools'"
  echo "        # 然后把源码树 tools/benchmark_flash_next.py 与 tools/benchmark_v017.py 放进宿主映射的 console-data/tmp/tools/"
  echo "      两个文件都要：前者 import 后者。"
  exit 4
fi
echo "  尺子=$TOOLFOUND  sha 前 16=$(docker exec "$CONTAINER" sha256sum "$TOOLFOUND" | cut -c1-16)"
dep=$(dirname "$TOOLFOUND")/benchmark_v017.py
docker exec "$CONTAINER" test -f "$dep" || { echo "BLOCK 缺配套 $dep（尺子 import 它）"; exit 5; }
echo "  配套=$dep 在位"

echo "=== 2) 取密钥（只报长度，绝不打印值）==="
KEY=$(docker exec "$CONTAINER" sh -c 'cat /console-data/engine-key.current 2>/dev/null || cat /console-data/key 2>/dev/null' | tr -d '\r\n')
if [ -z "$KEY" ]; then
  echo "  WARN 读不到引擎密钥 ⇒ 本次不发 Authorization 头（引擎未配 api-key 时本来就不需要，不影响吞吐口径）"
else
  echo "  引擎密钥长度=${#KEY}（值不外流：走 stdin 进容器，不出现在宿主 ps 里）"
fi

echo "=== 3) 开测（预热 $WARMUPS 正式 $REPEATS 长档 $LONG_REPEATS 输出 $OUT_TOKENS mixed）==="
# 接口注意：base url / 模型名 / 结果根目录都走**环境变量**（VLLM_BASE_URL、VLLM_MODEL、
# VLLM_BENCH_ROOT、LABEL），不是命令行参数——这是从已验证过的测速包装脚本抄下来的形态。
# 密钥单独走 stdin：`docker exec -e VLLM_API_KEY=xxx` 会把值写在宿主的 docker 进程 argv 上，
# 同机任何人 ps 一下就看到了；管道进去只存在于这个 exec 会话里。
: > "$OUTDIR/$LABEL.out" && chmod 600 "$OUTDIR/$LABEL.out" || exit 2
if [ -n "$KEY" ]; then
  printf '%s\n' "$KEY" | docker exec -i "$CONTAINER" \
    -e LABEL="$LABEL" -e VLLM_BENCH_ROOT="$ROOT" -e VLLM_TOOL="$TOOLFOUND" \
    -e VLLM_BASE_URL="$MODEL" -e VLLM_MODEL="$MODEL_NAME" -e PYTHONIOENCODING=utf-8 \
    bash -c 'read -r K; if [ -n "$K" ]; then export VLLM_API_KEY="$K"; fi; exec python3 "$VLLM_TOOL" "$@"' \
    bench --model-path /models --expect-mtp off --label "$LABEL" \
    --sizes "$SIZES" --warmups "$WARMUPS" --repeats "$REPEATS" --long-repeats "$LONG_REPEATS" \
    --output "$OUT_TOKENS" --mixed > "$OUTDIR/$LABEL.out" 2>&1
else
  docker exec "$CONTAINER" \
    -e LABEL="$LABEL" -e VLLM_BENCH_ROOT="$ROOT" \
    -e VLLM_BASE_URL="$MODEL" -e VLLM_MODEL="$MODEL_NAME" -e PYTHONIOENCODING=utf-8 \
    python3 "$TOOLFOUND" \
    --model-path /models --expect-mtp off --label "$LABEL" \
    --sizes "$SIZES" --warmups "$WARMUPS" --repeats "$REPEATS" --long-repeats "$LONG_REPEATS" \
    --output "$OUT_TOKENS" --mixed > "$OUTDIR/$LABEL.out" 2>&1
fi
rc=$?
tail -20 "$OUTDIR/$LABEL.out" | sed 's/^/  /'
echo "BENCH_RC=$rc"

echo "=== 4) 可比性判定 ==="
python3 - "$OUTDIR" "$LABEL" <<'PY'
import glob, json, os, statistics, sys
outd, label = sys.argv[1], sys.argv[2]
txt = open(os.path.join(outd, label + ".out"), encoding="utf-8", errors="replace").read()
rows, passed = [], None
for line in txt.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("passed") is True:
        passed = True
    if o.get("case") and isinstance(o.get("decode_tok_s"), (int, float)):
        rows.append(o)
if passed is not True:
    print("  BENCH_NOT_COMPARABLE 末行没有 passed=true（尺子自己的硬门没过，别引用这轮数字）")
    sys.exit(6)
if not rows:
    print("  BENCH_NOT_COMPARABLE 解析到 passed=true 但一行数据都没有（尺子输出格式变了？逐行核对 %s）" % os.path.join(outd, label + ".out"))
    sys.exit(7)
bad = [r for r in rows if r.get("warmup")]
for case in sorted({r["case"] for r in rows}):
    sel = [r for r in rows if r["case"] == case and not r.get("warmup")]
    if not sel:
        continue
    d = [r["decode_tok_s"] for r in sel]
    p = [r["effective_prefill_tok_s"] for r in sel]
    cached = {r.get("cached_tokens") for r in sel}
    pre = {r.get("preemptions") for r in sel}
    drf = {r.get("drafted") for r in sel}
    flag = ""
    if cached != {0} or pre != {0.0} or (drf - {0}):
        flag = "   <== 口径异常：命中缓存/被抢占/有投机，不可与本文数字比较"
    print("  %-8s n=%d decode 中位 %.2f 区间 %.2f-%.2f | prefill 中位 %.2f | ITL %.2f ms%s" % (
        case, len(sel), statistics.median(d), min(d), max(d), statistics.median(p),
        1000.0 / statistics.median(d), flag))
print("  warmup 行=%d（已排除）" % len(bad))
print("BENCH_OK")
PY
rc2=$?
echo "BENCH_DONE rc=$rc judge=$rc2 原始输出=$OUTDIR/$LABEL.out"
exit $((rc + rc2))
