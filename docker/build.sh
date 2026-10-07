#!/bin/bash
# build.sh —— 0.1.7 自包含部署包的镜像构建编排（唯一构建入口）
#
# 三层模型（每层独立标签，任一层可跳）：
#   层 0  官方 0.1.7 ultra          vllm-sm75:v0.1.7-ultra-beta            （由官方 docker/build.sh 产出，或你已有）
#   层 1  GPU 探测超时 3s→20s       …-to20s                                （本机 hardware.py 实测 6.0-6.9s，不修面板拒启）
#   层 2  FlashInfer PCIe-IPC 回填  …-to20s-pcieipc                         （默认推荐；SKIP_PCIEIPC=1 退回层 1）
#   NVAPI **不在任何层里**：0.1.7 的形态是宿主文件只读 bind 进容器（见 NVAPI-获取说明-v1.md）。
#
# 用法：
#   bash build.sh                      # 层0 若已在位则跳过，然后层1、层2
#   MODE=layers bash build.sh          # 只做层1+层2（要求层0 标签已在位）
#   SKIP_TO20S=1 bash build.sh         # 只做层2，基座用层0（层2 标签自动叫 …-ultra-beta-pcieipc）
#   SKIP_PCIEIPC=1 bash build.sh       # 只要官方形态（层0+层1）
#   SKIP_NVAPI=1 bash build.sh         # 不带 P-State 宿主库也能走完（构建本来不碰它，这里只放行前置门）
#   OFFICIAL=本地已有标签 MODE=layers bash build.sh    （层0 标签名）
#   BASE_IMAGE_ID=repo@sha256:<digest>                 （把 FROM 钉到 digest，别只信 tag）
#
# 复核要点：
#   1) 绝不隐式拉取：所有基础标签必须本地在位，缺就报错让人先建/先导。
#   2) 每层构建后做"终态断言"，不是"命令 rc=0 就算过"：
#      层1 断言 server.mjs 里那句超时真变成 20000 且 node --check 过；
#      层2 断言镜像里真能 import 出 PcieIpcAllReduceWorkspace（vLLM 的判据就是这一句）。
#      标签本来就已在位（没重建）时**同样跑断言**——否则第二次跑等于没验。
#   3) 回填物料先按 manifest 对拍 sha256 再进构建上下文，缺一件即停。
#   4) 失败不留半成品标签：docker build 失败本身不产标签，这里再显式确认一次。
set -u
D=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$D/.." && pwd)

OFFICIAL=${OFFICIAL:-vllm-sm75:v0.1.7-ultra-beta}
TO20S=${TO20S:-$OFFICIAL-to20s}
FINAL=${FINAL:-}                 # 留空=按实际层组合自动取名（SKIP_TO20S 时不该再叫 -to20s-…）
MODE=${MODE:-auto}
SKIP_TO20S=${SKIP_TO20S:-0}
SKIP_PCIEIPC=${SKIP_PCIEIPC:-0}
SKIP_NVAPI=${SKIP_NVAPI:-0}
BASE_IMAGE_ID=${BASE_IMAGE_ID:-}
NVAPI_SHA=4a199f9b259a1098ab9c01d31c67f882a2531a0fbb9c3595ad3d016c7d131d8c
NVAPI_FILE=$D/libnvidia-api.so.1
WHEEL_SHA_070=c7adf826568d61fc1b7d3aadd4cae387a35a138bfc08e2deca2f34ecfa280716
# 0.7.0.post1 的取件地址（公开 PyPI，sha256 是硬门禁，地址只是让你能自查来源）
WHEEL_URL_070=https://pypi.org/project/flashinfer-python/0.7.0.post1/

say() { echo "$*"; }
die() { echo "BUILD_FAIL $*"; exit 2; }

have() { docker image inspect "$1" >/dev/null 2>&1; }

# 真正拿去当基座的东西：给了 digest 就用 digest（tag 是可移动的，钉 digest 才知道自己建在哪之上）
base_ref() { if [ -n "$BASE_IMAGE_ID" ]; then printf '%s' "$BASE_IMAGE_ID"; else printf '%s' "$1"; fi; }

say "=== 0) 前置：物料完整性 ==="
[ -f "$D/Dockerfile.to20s-v1" ] || die "缺 docker/Dockerfile.to20s-v1"
[ -f "$D/to20s-patch-v2.sh" ] || die "缺 docker/to20s-patch-v2.sh"
[ -f "$D/Dockerfile.pcieipc-v1" ] || die "缺 docker/Dockerfile.pcieipc-v1"
if [ "$SKIP_NVAPI" = "1" ]; then
  say "  WARN SKIP_NVAPI=1：跳过 NVAPI 前置门。**注意 0.1.7 这条线本来就不把这个库烘进镜像**"
  say "       （它是宿主侧只读 bind，见 docker/NVAPI-获取说明-v1.md），这个开关放行的是构建检查与启动形态："
  say "       起容器时 run/start-here-v1.sh 要传 NVAPI=none，并把 profile 的 power.mode 改成 sleep，"
  say "       否则面板会拒绝启引擎。推理本身与这个库无关。"
else
  [ -f "$NVAPI_FILE" ] || die "缺 docker/libnvidia-api.so.1（或改走 SKIP_NVAPI=1，见 docker/NVAPI-获取说明-v1.md）"
  got=$(sha256sum "$NVAPI_FILE" | cut -d' ' -f1)
  [ "$got" = "$NVAPI_SHA" ] || die "NVAPI 哈希不符 期望 $NVAPI_SHA 实为 $got"
  say "  PASS NVAPI sha256 一致（它进的是宿主 bind，不进镜像）"
fi

n_mat=$(awk -F'\t' '!/^#/ && $5=="verbatim"' "$D/pcieipc/manifest.txt" | wc -l | tr -dc '0-9')
[ "$n_mat" = "6" ] || die "pcieipc manifest 的 verbatim 行数=$n_mat，期望 6"
while IFS="$(printf '\t')" read -r rel _l _b sha _k; do
  p="$D/pcieipc/$rel"
  [ -f "$p" ] || die "缺回填物料 $p"
  g=$(sha256sum "$p" | cut -d' ' -f1)
  [ "$g" = "$sha" ] || die "回填物料 sha 不符 $rel 期望 $sha 实为 $g"
done < <(awk -F'\t' '!/^#/ && $5=="verbatim"' "$D/pcieipc/manifest.txt")
for b in jit_comm trace_comm comm_init; do
  [ -s "$D/pcieipc/append/$b.txt" ] || die "缺追加块 $b.txt"
done
say "  PASS 回填物料 6 件 sha 全对、3 个追加块非空"
say "  提示：这 9 件由 flashinfer_python 0.7.0.post1 wheel 解出（源 wheel sha256 $WHEEL_SHA_070）"
say "        要重新推导：python3 docker/pcieipc/extract-pcieipc.py <该 wheel> <输出目录>"

say "=== 1) 层 0：官方 0.1.7 ultra ==="
if have "$OFFICIAL"; then
  say "  已在位 $OFFICIAL -> $(docker image inspect -f '{{.Id}}' "$OFFICIAL" | cut -c8-19)，不重建"
elif [ "$MODE" = "layers" ]; then
  die "MODE=layers 但官方基座不在位：$OFFICIAL（先按官方 docker/build.sh 建，或导入）"
else
  SRC=${SM75_SRC:-$PKG/code/VLLM-SM75-0.1.7-beta}
  [ -f "$SRC/docker/build.sh" ] || die "找不到 0.1.7 源码树 $SRC（设 SM75_SRC 指过去）"
  say "  用官方入口构建：$SRC/docker/build.sh（EDITION=ultra）"
  ( cd "$SRC" && EDITION=ultra bash docker/build.sh ) || die "官方构建失败"
  have "$OFFICIAL" || die "官方构建没产出 $OFFICIAL"
fi

CUR="$OFFICIAL"
[ -n "$BASE_IMAGE_ID" ] && CUR="$(base_ref "$OFFICIAL")"

say "=== 2) 层 1：GPU 探测超时 20s ==="
if [ "$SKIP_TO20S" = "1" ]; then
  say "  SKIP_TO20S=1，跳过（面板在这台机上可能拒启，见 部署文档-v1.md 的『20 秒超时』一节）"
else
  if have "$TO20S"; then
    say "  已在位 $TO20S，跳过重建，但断言照跑（不重建≠已验证）"
  else
    ctx=$(mktemp -d) || die "mktemp 失败"
    cp "$D/Dockerfile.to20s-v1" "$D/to20s-patch-v2.sh" "$ctx/" || { rm -rf "$ctx"; die "准备上下文失败"; }
    docker build -f "$ctx/Dockerfile.to20s-v1" --build-arg BASE_IMAGE="$(base_ref "$CUR")" -t "$TO20S" "$ctx" || { rm -rf "$ctx"; die "层1 构建失败"; }
    rm -rf "$ctx"
    have "$TO20S" || die "层1 没产出标签"
  fi
  docker run --rm --entrypoint sh "$TO20S" -c \
    "grep -qE 'timeout: 20000([^0-9]|\$)' /opt/sm75-workbench/console/server.mjs && node --check /opt/sm75-workbench/console/server.mjs && echo TO20S_ASSERT_OK" \
    | grep -q TO20S_ASSERT_OK || die "层1 终态断言未过（20000 没写进去或语法不过）"
  say "  PASS 层1 终态断言：server.mjs 里确为 timeout: 20000 且 node --check 过"
  CUR="$TO20S"
fi

# 层2 标签按"实际走过的层"自动命名：SKIP_TO20S=1 时基座是层0，就不该再挂 -to20s 这个名字
if [ -z "$FINAL" ] && [ "$SKIP_PCIEIPC" != "1" ]; then
  if [ "$SKIP_TO20S" = "1" ]; then FINAL="$OFFICIAL-pcieipc"; else FINAL="$TO20S-pcieipc"; fi
  say "  （层2 标签自动取名：$FINAL；要别的名字就显式 FINAL=…）"
fi

say "=== 3) 层 2：FlashInfer PCIe-IPC 回填 ==="
if [ "$SKIP_PCIEIPC" = "1" ]; then
  say "  SKIP_PCIEIPC=1，产出停在官方形态：$CUR"
  echo "BUILD_DONE IMAGE=$CUR"
  say "  这一形态下 profile 里**别**置 VLLM_ALLREDUCE_USE_FLASHINFER_PCIE_IPC；置了 vLLM 会打印"
  say "  this FlashInfer build does not provide PcieIpcAllReduceWorkspace 并退回原后端。"
  exit 0
fi
if have "$FINAL"; then
  say "  已在位 $FINAL，跳过重建，但断言照跑"
else
  ctx=$(mktemp -d) || die "mktemp 失败"
  cp -r "$D/pcieipc/." "$ctx/" || { rm -rf "$ctx"; die "拷上下文失败"; }
  cp "$D/Dockerfile.pcieipc-v1" "$ctx/Dockerfile" || { rm -rf "$ctx"; die "拷 Dockerfile 失败"; }
  # Dockerfile 里 COPY 的路径相对上下文根，这里把 pcieipc 内的子目录摆到位
  docker build -f "$ctx/Dockerfile" --build-arg BASE_IMAGE="$(base_ref "$CUR")" -t "$FINAL" "$ctx" || { rm -rf "$ctx"; die "层2 构建失败"; }
  rm -rf "$ctx"
  have "$FINAL" || die "层2 没产出标签"
fi
[ "$(docker image inspect -f '{{.Id}}' "$FINAL")" != "$(docker image inspect -f '{{.Id}}' "$CUR")" ] \
  || die "层2 与基座同 ID，说明补丁层没进去"
docker run --rm --entrypoint python3 "$FINAL" -c \
  "import flashinfer.comm as c,sys;sys.exit(0 if hasattr(c,'PcieIpcAllReduceWorkspace') else 1)" \
  || die "层2 终态断言未过：镜像里 import 不出 PcieIpcAllReduceWorkspace"
say "  PASS 层2 终态断言：镜像内 hasattr(flashinfer.comm,'PcieIpcAllReduceWorkspace') 为真"
CUR="$FINAL"

say "=== 4) 完成 ==="
docker image inspect "$CUR" --format 'IMAGE={{.Id}} SIZE={{.Size}}' | sed 's/^/  /'
echo "BUILD_DONE IMAGE=$CUR"
say "回填物料的源 wheel：flashinfer_python-0.7.0.post1（sha256 $WHEEL_SHA_070，取件页 $WHEEL_URL_070）"
[ "$SKIP_NVAPI" = "1" ] && say "注意：本次 SKIP_NVAPI=1 ⇒ 起容器用 NVAPI=none，且 profile 的 power.mode 必须是 sleep。"
say "下一步：编辑 run/start-here-v1.sh 顶部的路径（或用同名环境变量覆盖），然后 bash run/env-check-v1.sh && bash run/start-here-v1.sh"
