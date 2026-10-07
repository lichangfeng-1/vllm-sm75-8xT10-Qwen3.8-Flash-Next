#!/bin/bash
# gen-console-env-v1.sh —— 一次性：把在役 console 容器的 env 导出成宿主 env-file（供 run-console-pcieipc 用）
#
# 为什么要这一步：生产启动脚本不能依赖"去 inspect 某个参照容器"（参照容器哪天被删脚本就废了）。
# env 落成一个 600 的宿主文件，脚本自给自足。
#
# 复核要点：
#   1) 导出前先扫一遍有没有密钥类变量；有就**拒绝写文件**并列出名字（值不外流）。
#      （本轮实测 console 容器 env 里密钥类=0，所以正常路径会直接通过。）
#   2) 写完立刻回读计数对拍，不等则非零退出。
#   3) 目标文件已存在时先备份成 .bak-<时间戳>，不静默覆盖。
set -u
SRC=${1:-sm75-017-console}                       # 要导出的在役容器名
OUT=${OUT:-${DATA:-/var/lib/sm75-console}/console.env}   # 落地路径，OUT= 或 DATA= 覆盖

docker inspect "$SRC" >/dev/null 2>&1 || { echo "BLOCK 容器读不到 $SRC"; exit 2; }
mkdir -p "$(dirname "$OUT")" || exit 3

echo "=== 1) 密钥扫描 ==="
secret=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SRC" \
         | cut -d= -f1 | grep -iE "KEY|TOKEN|SECRET|PASS|AUTH" | tr '\n' ' ')
if [ -n "${secret// /}" ]; then
  echo "  BLOCK 容器 env 里有密钥类变量，不落盘：$secret"
  echo "  处置：把它们从导出里剔除后再生成（面板登录 token 在 /console-data/key，不需要进 env）"
  exit 4
fi
echo "  PASS 无密钥类变量"

echo "=== 2) 导出 ==="
if [ -f "$OUT" ]; then
  BAK="$OUT.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$OUT" "$BAK" && echo "  已备份旧文件 -> $BAK"
fi
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SRC" | sed '/^$/d' > "$OUT"
chmod 600 "$OUT"

echo "=== 3) 对拍 ==="
want=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SRC" | sed '/^$/d' | wc -l | tr -dc '0-9')
got=$(wc -l < "$OUT" | tr -dc '0-9')
echo "  容器内=$want 文件=$got 权限=$(stat -c '%a %U:%G' "$OUT")"
[ "$want" = "$got" ] || { echo "BLOCK 条数不等"; exit 5; }
grep -c '^' "$OUT" >/dev/null && echo "  变量名清单: $(cut -d= -f1 "$OUT" | tr '\n' ' ')"
echo "GEN_ENV_OK $OUT"
