#!/bin/sh
# install-pcieipc.sh —— 在镜像里落 T11a backport（由 Dockerfile RUN 调用，也可手工在容器里跑）
#
# 用法: sh install-pcieipc.sh <ctx目录> [skip-import-gate]
#   默认**硬跑**运行时 import 门禁；只有宿主预检证明"基座镜像无 GPU 也 import 不了 flashinfer.comm"
#   时才允许传 skip-import-gate，此时 Dockerfile 会显式记 LABEL 并在验收里补跑（不静默放宽）。
#
# 复核要点（写之前定的规矩，逐条对应）：
#   1) 幂等门放在最前：任何"已打过"的迹象都直接退出，绝不重复追加（追加型补丁跑两次就是双份代码）。
#   2) 每条否定检查用 if/fi 而不是 `grep && exit`（set -e 与 AND-OR 列表的交互不该赌）。
#   3) 物料先 sha256 对拍再落盘；落盘后由 gate 脚本按"装完的终态"再对拍一次。
#   4) 追加三处各自记账：行数增量必须等于块行数，否则说明追加写歪。
#   5) 任一断言不过 => 非零退出，构建直接失败（不做静默放宽、不留半成品）。
set -eu

CTX="${1:-/tmp/pcieipc}"
IMPORT_GATE=1
if [ "${2:-}" = "skip-import-gate" ]; then
  IMPORT_GATE=0
  echo "WARN 运行时 import 门禁被显式跳过（应由宿主预检决定，不得默认跳过）"
fi

SP="${SM75_SITE_PACKAGES:-/usr/local/lib/python3.12/dist-packages}"
FI="$SP/flashinfer"
PYBIN="${SM75_PY:-python3}"
# SM75_SITE_PACKAGES / SM75_PY 只为本地干跑留的口（用 0.6.18 wheel 搭的迷你树，且 Windows 的 python3 是空壳）；
# 镜像里不设这两个变量，走 python3 与真实 dist-packages。

echo "=== 0) 基本目录 ==="
[ -d "$FI" ] || { echo "ASSERT_FAIL 没有 $FI"; exit 2; }
[ -f "$CTX/manifest.txt" ] || { echo "ASSERT_FAIL 缺 $CTX/manifest.txt"; exit 2; }
[ -f "$CTX/obligations.txt" ] || { echo "ASSERT_FAIL 缺 $CTX/obligations.txt"; exit 2; }
[ -f "$CTX/gate-check-v3.py" ] || { echo "ASSERT_FAIL 缺 $CTX/gate-check-v3.py"; exit 2; }
echo "FLASHINFER_TREE=$FI"
"$PYBIN" -V

echo "=== 1) 幂等 / 前置门 ==="
# 用"精确 marker"而不是宽松的 pcie_ipc 子串：宽松串可能命中 0.6.18 里无关文本，把干净构建误判成"打过两次"。
if grep -q "from .pcie_ipc_ar import" "$FI/comm/__init__.py"; then
  echo "ASSERT_FAIL comm/__init__.py 已含 'from .pcie_ipc_ar import'，拒绝重复追加"; exit 3
fi
echo "  参考信息：整棵树里含 pcie_ipc 的文件数=$(grep -rl pcie_ipc "$FI" 2>/dev/null | wc -l | tr -dc '0-9')（0.6.18 应为 0）"
for f in pcie_ipc_ar.py pcie_ipc_policy.py pcie_ipc_topology.py pcie_ipc_tuning.py; do
  if [ -e "$FI/comm/$f" ]; then echo "ASSERT_FAIL 已存在 $FI/comm/$f"; exit 4; fi
done
if [ -e "$FI/data/csrc/pcie_ipc_all_reduce.cu" ]; then echo "ASSERT_FAIL 已存在 csrc/pcie_ipc_all_reduce.cu"; exit 5; fi
if [ -e "$FI/data/include/flashinfer/comm/pcie_ipc_all_reduce.cuh" ]; then
  echo "ASSERT_FAIL 已存在 include/flashinfer/comm/pcie_ipc_all_reduce.cuh"; exit 5
fi
if grep -q "gen_pcie_ipc_comm_module" "$FI/jit/comm.py"; then
  echo "ASSERT_FAIL jit/comm.py 已有 gen_pcie_ipc_comm_module"; exit 6
fi
if grep -q "pcie_ipc_all_reduce_trace" "$FI/trace/templates/comm.py"; then
  echo "ASSERT_FAIL trace/templates/comm.py 已有 pcie_ipc_all_reduce_trace"; exit 7
fi
echo "IDEMPOTENCE_OK 六个目标文件均不存在、三处追加点均未打过"

echo "=== 2) 安装前门禁（0.6.18 是否喂饱待落文件的 import） ==="
"$PYBIN" "$CTX/gate-check-v3.py" "$CTX" pre

echo "=== 3) 落六个逐字节文件（先对拍 sha256） ==="
awk -F'\t' '$5=="verbatim"{print $1"\t"$4}' "$CTX/manifest.txt" > /tmp/pcieipc.verbatim
n=0
while IFS="$(printf '\t')" read -r rel want; do
  case "$rel" in newfiles/*) : ;; *) echo "ASSERT_FAIL manifest 路径异常 $rel"; exit 8 ;; esac
  src="$CTX/$rel"
  [ -f "$src" ] || { echo "ASSERT_FAIL 物料缺失 $src"; exit 8; }
  got=$(sha256sum "$src" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "ASSERT_FAIL sha 不符 $rel 期望 $want 实为 $got"; exit 8
  fi
  dst="$FI/${rel#newfiles/flashinfer/}"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  got2=$(sha256sum "$dst" | cut -d' ' -f1)
  [ "$got2" = "$want" ] || { echo "ASSERT_FAIL 落盘后 sha 变了 $dst"; exit 8; }
  n=$((n + 1))
  echo "  PLACED $dst"
done < /tmp/pcieipc.verbatim
[ "$n" = "6" ] || { echo "ASSERT_FAIL 落盘文件数=$n，期望 6"; exit 8; }
echo "PLACED_COUNT=$n"

echo "=== 4) 三处追加（逐处记账行数增量） ==="
append_block() {
  target="$1"; block="$2"; label="$3"
  [ -f "$block" ] || { echo "ASSERT_FAIL 缺追加块 $block"; exit 9; }
  before=$(wc -l < "$target" | tr -dc '0-9')
  blk=$(wc -l < "$block" | tr -dc '0-9')
  cat "$block" >> "$target"
  after=$(wc -l < "$target" | tr -dc '0-9')
  delta=$((after - before))
  if [ "$delta" != "$blk" ]; then
    echo "ASSERT_FAIL $label 行数增量 $delta != 块行数 $blk（追加写歪）"; exit 9
  fi
  echo "  APPEND $label before=$before blk=$blk after=$after"
}
append_block "$FI/jit/comm.py"                "$CTX/append/jit_comm.txt"   "jit/comm.py"
append_block "$FI/trace/templates/comm.py"    "$CTX/append/trace_comm.txt" "trace/templates/comm.py"
append_block "$FI/comm/__init__.py"           "$CTX/append/comm_init.txt"  "comm/__init__.py"

echo "=== 5) 语法必须仍可编译 ==="
"$PYBIN" -m py_compile \
  "$FI/comm/pcie_ipc_ar.py" "$FI/comm/pcie_ipc_policy.py" \
  "$FI/comm/pcie_ipc_topology.py" "$FI/comm/pcie_ipc_tuning.py" \
  "$FI/jit/comm.py" "$FI/trace/templates/comm.py" "$FI/comm/__init__.py"
echo "PY_COMPILE_OK 7 个文件"

echo "=== 6) 安装后门禁（终态对拍） ==="
"$PYBIN" "$CTX/gate-check-v3.py" "$CTX" post

echo "=== 7) 运行时门禁（vLLM 判据就是这一句 hasattr） ==="
if [ "$IMPORT_GATE" = "1" ]; then
  if "$PYBIN" - <<'PY'
import sys
import flashinfer.comm as c
ok = hasattr(c, "PcieIpcAllReduceWorkspace")
print("  hasattr(flashinfer.comm,'PcieIpcAllReduceWorkspace') =", ok)
if not ok:
    sys.exit(11)
import flashinfer.comm.pcie_ipc_ar as ar
print("  pcie_ipc_ar 已导入，类 =", ar.PcieIpcAllReduceWorkspace.__name__)
import flashinfer.trace.templates.comm as tc
print("  trace 模板已导入，符号 =", type(tc.pcie_ipc_all_reduce_trace).__name__)
from flashinfer.jit.comm import gen_pcie_ipc_comm_module as g
print("  jit 生成器可解析 =", callable(g))
PY
then
  echo "IMPORT_GATE_OK"
else
  echo "ASSERT_FAIL 运行时 import 门禁未过（看上方 traceback 或 hasattr=False）"
  exit 11
fi
else
  echo "IMPORT_GATE_SKIPPED 由验收步骤在带 GPU 的容器里补跑"
fi

echo "INSTALL_PCIEIPC_OK"
