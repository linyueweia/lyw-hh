#!/usr/bin/env bash
# 管理地址守护的「选口」逻辑自测 —— 覆盖 2026-10-17 实机踩到的坑：
#   旧写法 `m=$(readlink -f /sys/class/net/$t/master); [ -n "$m" ] && t=${m##*/}`
#   在 eth2 不在桥里时，readlink -f 仍输出 ".../eth2/master" → t=master →
#   `ip addr add ... dev master` 静默失败 → 192.168.100.1 永远加不上。
# 期望：无 master → eth2；有 master（指向 br-lan1）→ br-lan1。
# 用法：bash tools/tests/admin-ip-iface-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$HERE/extensions/lyw-hh-net.sh"
[[ -f "$EXT" ]] || { echo "!! 找不到 $EXT"; exit 2; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t admip)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  !!   $*"; }

# 从扩展里抽出生成脚本中的 pick_iface 函数（它就在 heredoc 里，文本可直接抽）
sed -n '/^pick_iface()/,/^}/p' "$EXT" > "$TMP/pick.sh"
if [[ -s "$TMP/pick.sh" ]] && grep -q 'class/net/\$1/master' "$TMP/pick.sh"; then
	ok "扩展里能抽出 pick_iface（且先判 master 是否存在）"
else
	bad "扩展里没有 pick_iface / 仍是旧写法（redlink -f 不判存在）"
fi

# 负断言：旧的有 bug 写法必须绝迹（只匹配“代码行”，别命中注释里的示例 —— 见技能 §4）
if grep -qE '^[[:space:]]*m=\$\(readlink' "$EXT"; then
	bad "扩展里仍残留旧写法 m=\$(readlink ...)（eth2 不在桥里时会把 t 变成 master）"
else
	ok "无旧写法残留（注释里的示例不算）"
fi

# 用例 1：没有 master → 用 eth2 自己
mkdir -p "$TMP/fs1/class/net/eth2"
r1="$(SYSFS="$TMP/fs1" sh -c '. "$1"; pick_iface eth2' _ "$TMP/pick.sh" 2>&1)"
[[ "$r1" == "eth2" ]] && ok "无桥(master 不存在) → eth2" || bad "无桥时应选 eth2，实际 [$r1]"

# 用例 2：eth2 在 br-lan1 里（master → br-lan1）→ 用桥名
mkdir -p "$TMP/fs2/class/net/eth2" "$TMP/fs2/class/net/br-lan1"
ln -s ../../../class/net/br-lan1 "$TMP/fs2/class/net/eth2/master" 2>/dev/null
if [[ -L "$TMP/fs2/class/net/eth2/master" ]]; then
	r2="$(SYSFS="$TMP/fs2" sh -c '. "$1"; pick_iface eth2' _ "$TMP/pick.sh" 2>&1)"
	[[ "$r2" == "br-lan1" ]] && ok "在桥里(master→br-lan1) → br-lan1" || bad "在桥里时应选 br-lan1，实际 [$r2]"
else
	# Windows/MSYS 无建链权限时 ln -s 会退化成目录副本（不是链接），这一例只能交给 Linux CI
	rm -rf "$TMP/fs2/class/net/eth2/master"
	echo "  --   SKIP 在桥里用例（本机 ln -s 未生成真链接，由 Linux CI 覆盖）"
fi

echo
echo "选口逻辑自测：通过 $PASS 例，失败 $FAIL 例"
[[ $FAIL -eq 0 ]] || exit 1
