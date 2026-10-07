#!/bin/bash
# lint-package-v1.sh —— 分享包出厂自检（只读，不改文件；CI 式一票否决）
#
# 为什么要有：0.1.6 那轮吃过"补丁叠加自造 bug"与"清单过期当真值"的亏。
# 这个脚本每次改包后重跑，六类检查任一失败就非零退出：
#   A 语法：所有 .sh 过 bash -n，所有 .py 过 compile
#   B 行尾/编码：文本文件必须 LF（CR=0）、UTF-8 可解码
#   C 凭据与隐私：密钥形态、用户名、内网 IP、机器专属路径 一律零命中
#   D 断链：README 与文档里引用的包内相对路径必须真实存在（含嵌图）
#   E 清单：SHA256SUMS.txt 与包内实际文件对得上（--fix 才重写）
#   F COPY 自洽：Dockerfile 里 COPY 的源，在 build.sh 组的上下文里必须真的在位
# 用法：PRIVACY_PATTERNS=../privacy-patterns.txt bash tools/lint-package-v1.sh [--fix]
set -u
D=$(cd "$(dirname "$0")/.." && pwd)
cd "$D" || exit 2
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1
fail=0
bad() { echo "  FAIL $*"; fail=1; }
ok() { echo "  ok   $*"; }

# A/B 两段要跑 python 做 ast.parse 与字节级 CR/UTF-8 判定。Windows 上 `python3` 往往是
# 微软商店的空壳（跑起来返回 rc=49、什么都不输出），拿它当解释器会让 25 个文件全部"假失败"，
# 看起来像"全包都是 CRLF"。这里先探活，选一个真能跑的，探不到就直接 FAIL 而不是给假绿/假红。
PY=""
for c in ${SM75_PY_CANDIDATES:-python3 python py}; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c "import sys; sys.exit(0)" >/dev/null 2>&1 || continue
  PY="$c"; break
done
[ -n "$PY" ] || { echo "LINT_FAIL 找不到能用的 python 解释器（试过 ${SM75_PY_CANDIDATES:-python3 python py}）"; exit 3; }
echo "  解释器=$PY ($("$PY" -c 'import sys;print(sys.version.split()[0])' 2>/dev/null))"

TXT_EXT='sh|py|md|json|txt|cuh|cu|gitignore|gitattributes|LICENSE|NOTICE'

echo "=== A) 语法 ==="
n_sh=0
while IFS= read -r f; do
  n_sh=$((n_sh + 1))
  bash -n "$f" || bad "bash -n 失败: $f"
done < <(find . -type f -name "*.sh" -not -path "./.git/*")
ok ".sh 文件 $n_sh 个全部过 bash -n"
n_py=0
while IFS= read -r f; do
  n_py=$((n_py + 1))
  "$PY" -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" || bad "py 语法失败: $f"
done < <(find . -type f -name "*.py" -not -path "./.git/*")
ok ".py 文件 $n_py 个全部过 ast.parse"

echo "=== B) 行尾与编码 ==="
cr=0
while IFS= read -r f; do
  if "$PY" -c "
import sys
d=open(sys.argv[1],'rb').read()
if b'\r' in d: sys.exit(1)
d.decode('utf-8')
" "$f" 2>/dev/null; then :; else cr=$((cr + 1)); bad "含 CR 或非 UTF-8: $f"; fi
done < <(find . -type f \( -name "*.sh" -o -name "*.py" -o -name "*.md" -o -name "*.json" -o -name "*.txt" -o -name "*.cu" -o -name "*.cuh" \) -not -path "./.git/*")
[ "$cr" = "0" ] && ok "全部文本文件 LF + UTF-8"

echo "=== C) 凭据与隐私扫描 ==="
# 关键教训：黑名单**不能写死在包内文件里**。上一版为了防泄露，把真实姓名/用户名/呼号/宿主路径
# 当成匹配串写进了这个脚本本身 —— 于是"检查器自己就是泄露源"，而为了让它不自匹配又把它排除在扫描外，
# 等于给泄露源开了免检。现在：通用形态内置，具体身份串放仓外文件（PRIVACY_PATTERNS 指过去）。
GENERIC='(AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|[A-Za-z0-9+/]{40,}\.git|-----BEGIN CERTIFICATE-----|smtp://[^ :]+:[^ @]+@|://[^ /@ ]+:[^ @]{6,}@)'
hits=$(grep -rInE "$GENERIC" . --exclude-dir=.git --exclude=SHA256SUMS.txt --exclude=lint-package-v1.sh 2>/dev/null | cut -d: -f1,2 | head -10)
[ -n "$hits" ] && bad "疑似密钥/令牌:$(echo "$hits" | tr '\n' ' ')" || ok "无通用密钥形态命中"
PFILE=${PRIVACY_PATTERNS:-$D/../privacy-patterns.txt}
if [ -f "$PFILE" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    hits=$(grep -rInE "$pat" . --exclude-dir=.git --exclude=SHA256SUMS.txt 2>/dev/null | cut -d: -f1,2 | head -10)
    [ -n "$hits" ] && bad "命中身份/位置模式（来自仓外清单）$pat: $(echo "$hits" | tr '\n' ' ')"
  done < "$PFILE"
  ok "已按仓外 PRIVACY_PATTERNS 清单扫描"
else
  bad "缺仓外身份清单 $PFILE ⇒ 具体姓名/用户名/宿主路径/内网段没扫。补法：在该文件里逐行写 ERE（此文件必须在仓库之外）"
fi
# 通用"机器专属形状"内置（不含任何具体身份值）
hits=$(grep -rInE "(/home/|/Users/)[a-z0-9._-]{4,}|K:\\|C:\\Users|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" . --exclude-dir=.git --exclude=SHA256SUMS.txt 2>/dev/null | grep -vE "0[.]0[.]0[.]0|127[.]0[.]0[.]1|localhost" | cut -d: -f1,2 | head -12)
[ -n "$hits" ] && bad "疑似本机专属路径/IP 形状:$(echo "$hits" | tr '
' ' ')" || ok "无本机路径与 IP 形状命中"

echo "=== D) 文档引用断链 ==="
miss=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  case "$ref" in http*|https*|\#*) continue ;; esac
  # glob 与占位写法不是链接；含非 ASCII（如省略号）的是文档示例，也不算断链
  case "$ref" in *"*"*|*"?"*) continue ;; esac
  if printf '%s' "$ref" | LC_ALL=C grep -q '[^ -~]'; then continue; fi
  p=$(printf '%s' "$ref" | sed 's|^./||')
  [ -e "$p" ] || { bad "引用不存在: $p"; miss=$((miss + 1)); }
done < <(grep -rhoE '\((\.?/?)(docker|run|tools|docs|code)/[^) ]+|`(\./)?(docker|run|tools|docs)/[^` ]+`|!\[[^]]*\]\(([^)]+)\)' \
            --include='*.md' . 2>/dev/null \
          | sed -E 's/^!\[[^]]*\]\(//; s/^[\(`]//; s/[\)`]$//')
[ "$miss" = "0" ] && ok "文档内相对引用全部存在（含嵌图路径）"

echo "=== E) 清单一致性 ==="
if [ "$FIX" = "1" ]; then
  # Git Bash 的 sha256sum 会写成 "<hash> *<路径>"（二进制标记）。Linux 上谁重新生成都是两个空格，
  # 混着两种形状会让人以为清单被改过；这里统一成规范的两空格形态（Linux 上文本/二进制哈希同值，不影响校验）。
  # 还要排掉 ./内部/：那是过程件、被 .gitignore 挡着不进版本库。本地它存在所以 `-c` 过得去，
  # 可 clone 的人拿到的是**没有那个文件的清单** ⇒ 会看到 "FAILED open or read"，像是清单坏了。
  find . -type f -not -path "./.git/*" -not -path "./内部/*" -not -name SHA256SUMS.txt | sed 's|^\./||' | sort \
    | xargs -d '\n' sha256sum | sed -E 's/^([0-9a-f]{64}) \*/\1  /' > SHA256SUMS.txt
  ok "已重写 SHA256SUMS.txt（$(grep -c '^' SHA256SUMS.txt) 条，已排除 .gitignore 掉的过程件）"
fi
if [ -f SHA256SUMS.txt ]; then
  if sha256sum -c SHA256SUMS.txt --quiet 2>/dev/null; then ok "SHA256SUMS.txt 与包内文件一致"; else
    bad "SHA256SUMS.txt 过期或不匹配（改包后请跑 bash tools/lint-package-v1.sh --fix）"; fi
  # 清单里不能出现被 .gitignore 忽略的路径（否则 clone 后 -c 必红）。
  # 这里不借 git（本地工作目录不是 git 仓，`git check-ignore` 会静默返回空＝假通过），
  # 直接拿 .gitignore 自己的条目按前缀/尾名匹配一遍。
  ghost=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in *!*) continue ;; esac
    if [ "${g: -1}" = "/" ]; then
      pre="${g%/}"
      while IFS= read -r m; do
        case "$m" in "$pre"/*|*/"$pre"/*) ghost="$ghost [$m<=gitignore:$g]" ;; esac
      done < <(awk '{print $2}' SHA256SUMS.txt)
    else
      while IFS= read -r m; do
        case "$m" in $g|*/$g) ghost="$ghost [$m<=gitignore:$g]" ;; esac
      done < <(awk '{print $2}' SHA256SUMS.txt)
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' .gitignore)
  [ -z "$ghost" ] && ok "清单里没有 .gitignore 会忽略的路径" || bad "清单里写着不会进版本库的路径（clone 后校验会报缺件）:$ghost"
else bad "缺 SHA256SUMS.txt（跑 --fix 生成）"; fi

echo "=== F) build.sh 与 Dockerfile 的 COPY 自洽（B1 那一类：引用了包内不存在的名字，层根本构建不出来）==="
# build.sh 组的上下文是固定的两个形状，这里按同一个映射去解 COPY 的源路径：
#   Dockerfile.to20s-v1   -> 上下文 = docker/            （cp Dockerfile + to20s-patch-v2.sh 进去）
#   Dockerfile.pcieipc-v1 -> 上下文 = docker/pcieipc/    （cp -r pcieipc/. 到根，Dockerfile 改名放进去）
copy_ctx() { case "$1" in *Dockerfile.to20s-v1) echo docker ;; *Dockerfile.pcieipc-v1) echo docker/pcieipc ;; *) echo "" ;; esac; }
f_copy=0
for df in docker/Dockerfile.*; do
  [ -f "$df" ] || continue
  ctx=$(copy_ctx "$df")
  [ -n "$ctx" ] || { bad "$df 不在 build.sh 的上下文映射里（改了 build.sh 就要同步改这里）"; continue; }
  # COPY 的最后一个字段是**目标**，源是中间那些；把目标当源查会必然假失败。
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    if [ "${src: -1}" = "/" ]; then
      [ -d "$ctx/$src" ] || { bad "$df 的 COPY 目录源不存在：$ctx/$src"; f_copy=$((f_copy + 1)); }
    else
      [ -e "$ctx/$src" ] || { bad "$df 的 COPY 源在上下文里不存在：$ctx/$src"; f_copy=$((f_copy + 1)); }
    fi
  done < <(grep -E '^[[:space:]]*COPY[[:space:]]' "$df" | sed -E 's/^[[:space:]]*COPY[[:space:]]+//; s/(--[a-z-]+=[^ ]+[[:space:]]+)//g; s/[[:space:]]*$//' | awk '{for(i=1;i<NF;i++) print $i}')
done
[ "$f_copy" = "0" ] && ok "Dockerfile 的 COPY 源在各自构建上下文里全部在位"

echo
[ "$fail" = "0" ] && { echo "LINT_PASS"; exit 0; } || { echo "LINT_FAIL 上面 FAIL 项必须清零才能对外发"; exit 3; }
