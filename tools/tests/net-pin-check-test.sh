#!/usr/bin/env bash
# net-pin-check.py 的负例自测：判据本身必须能红，否则"全绿"没有意义。
# 用法：bash tools/tests/net-pin-check-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
command -v cygpath >/dev/null 2>&1 && HERE="$(cygpath -m "$HERE")"  # Windows: 原生 python 只认 C:/... 形式

# python 探活（Windows 上 python3 常是应用商店占位符：command -v 成功、执行报错）
PY=""
for c in python3 python; do
	command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
done
[[ -n "$PY" ]] || { echo "!! 没有可用的 python"; exit 2; }
CHECK="$PY $HERE/tools/net-pin-check.py"

# 用仓库内相对目录做临时区：Windows 上原生 python 不认 /tmp 这种 MSYS 路径
TMP="$PWD/.tmp-netpin-test"
command -v cygpath >/dev/null 2>&1 && TMP="$(cygpath -m "$TMP")"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$TMP" && mkdir -p "$TMP"
PASS=0
FAIL=0

ORDER="0004:41:00.0,0003:31:00.0,fe1b0000.ethernet"

# 板级 csc 夹具（与真文件同结构：字面量只出现在 LYW_HH_ETH_ORDER 一行）
cat > "$TMP/board.csc" <<EOF
BOARD_NAME="Hinlink H88K"
KERNEL_TARGET="vendor"
BOOT_FDT_FILE="rockchip/rk3588-hinlink-h88k.dtb"
function post_family_tweaks__lyw_hh_h88k_static_eth_order() {
	LYW_HH_ETH_ORDER="$ORDER"
	printf '%s\n' "\$LYW_HH_ETH_ORDER" > "\${SDCARD}/etc/eth_order"
}
EOF

mkroot() { # $1 = eth_order 内容（空字符串＝不写文件）
	local d="$TMP/r$RANDOM"
	mkdir -p "$d/etc" "$d/root"
	[[ -n "$1" ]] && printf '%s\n' "$1" > "$d/etc/eth_order"
	echo "$d"
}

expect_ok() { # $1=名字 $2=root [$3=csc]
	local name="$1" root="$2" csc="${3:-$TMP/board.csc}"
	if $CHECK --conf "$root" --src "$csc" >/dev/null 2>&1; then
		PASS=$((PASS+1)); echo "  ok   $name"
	else
		FAIL=$((FAIL+1)); echo "  !!   $name（应通过却失败）"
	fi
}

expect_bad() {
	local name="$1" root="$2" csc="${3:-$TMP/board.csc}"
	if $CHECK --conf "$root" --src "$csc" >/dev/null 2>&1; then
		FAIL=$((FAIL+1)); echo "  !!   $name（应失败却通过）"
	else
		PASS=$((PASS+1)); echo "  ok   $name 被判红"
	fi
}

echo "== 正例 =="
expect_ok "正确的三口口径" "$(mkroot "$ORDER")"

echo "== 负例（覆盖实机上出现过的每一种错法）=="
expect_bad "空文件"                                "$(mkroot '')"
expect_bad "只有两个口"                            "$(mkroot '0004:41:00.0,fe1b0000.ethernet')"
expect_bad "千兆口排在 eth0（官方脚本的猜测顺序）"  "$(mkroot 'fe1b0000.ethernet,0004:41:00.0,0003:31:00.0')"
expect_bad "两个 2.5G 口顺序互换"                  "$(mkroot '0003:31:00.0,0004:41:00.0,fe1b0000.ethernet')"
expect_bad "重复口"                                "$(mkroot '0004:41:00.0,0004:41:00.0,fe1b0000.ethernet')"
expect_bad "PCI 地址写错一位"                      "$(mkroot '0004:41:00.1,0003:31:00.0,fe1b0000.ethernet')"
expect_bad "混入 USB 网卡名"                       "$(mkroot '0004:41:00.0,0003:31:00.0,enx00e04c680001')"

echo "== .default-network 负例 =="
R="$(mkroot "$ORDER")"; printf 'DEFAULT_INTERFACE=eth1\n' > "$R/root/.default-network"
expect_bad "默认口写成 eth1（首次开箱进不了千兆口后台）" "$R"
R="$(mkroot "$ORDER")"; printf 'DEFAULT_INTERFACE=eth2\n' > "$R/root/.default-network"
expect_ok "默认口写成 eth2（千兆口）" "$R"

echo "== csc 负例（构建前）=="
if $CHECK --src "$TMP/board.csc" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok   完整 csc"; else FAIL=$((FAIL+1)); echo "  !!   完整 csc 被判红"; fi

sed "s/$ORDER/fe1b0000.ethernet,0004:41:00.0,0003:31:00.0/" "$TMP/board.csc" > "$TMP/a.csc"
if $CHECK --src "$TMP/a.csc" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  !!   口序写反的 csc 却通过"; else PASS=$((PASS+1)); echo "  ok   口序写反的 csc 被判红"; fi

sed 's/KERNEL_TARGET="vendor"/KERNEL_TARGET="current"/' "$TMP/board.csc" > "$TMP/b.csc"
if $CHECK --src "$TMP/b.csc" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  !!   KERNEL_TARGET=current 的 csc 却通过"; else PASS=$((PASS+1)); echo "  ok   KERNEL_TARGET 不是 vendor 被判红"; fi

sed 's/post_family_tweaks__lyw_hh_h88k_static_eth_order/post_family_tweaks__other/' "$TMP/board.csc" > "$TMP/c.csc"
if $CHECK --src "$TMP/c.csc" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  !!   缺静态口序钩子的 csc 却通过"; else PASS=$((PASS+1)); echo "  ok   缺静态口序钩子被判红"; fi

# 第二份字面量（lyw-rr #14 的根因形态）：csc 里同一字面量出现两次
{ cat "$TMP/board.csc"; printf 'grep -q %s /etc/eth_order\n' "$ORDER"; } > "$TMP/d.csc"
if $CHECK --src "$TMP/d.csc" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  !!   口序字面量被抄第二份的 csc 却通过"; else PASS=$((PASS+1)); echo "  ok   口序字面量被抄第二份被判红"; fi

# 判据脚本自己不得再写死板级地址（单点化）
if grep -q '0004:41:00.0' "$HERE/tools/net-pin-check.py"; then
	FAIL=$((FAIL+1)); echo "  !!   net-pin-check.py 里又出现了板级地址字面量"
else
	PASS=$((PASS+1)); echo "  ok   net-pin-check.py 无板级地址字面量（期望值只从 csc 读）"
fi

echo
echo "通过 $PASS 例，失败 $FAIL 例"
[[ $FAIL -eq 0 ]] || exit 1
