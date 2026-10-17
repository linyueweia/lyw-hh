#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# Hinlink H88K / iNextOS 镜像自证 —— 只断言【本仓改过的地方】
#
# 原则（用户定）：官方默认值（DTB、armbianEnv、cma、内核符号、gpio-leds 之类）
# 一律不断言 —— 它们是上游的事，断言只会制造误报。判据只覆盖本仓真正写入/覆盖的：
#
#   1. /etc/eth_order          本仓写死的静态口序（官方在这里是空的、靠脚本猜）
#   2. fake-hwclock-load       本仓 mask 掉的（官方会用构建日期覆盖 RTC）
#   3. roceos 载荷            本仓注入的（官方镜像才带，上游框架不带）
#   4. roceos-ai 语义         本仓用官方 Easepi-r2 版覆盖的（exit 3 + 不重启）
#   5. admin-ip / LED 守护    本仓新增的服务
#   6. 反断言：不得残留 wan1/lan1/lan2 命名（与口序方案冲突）
#
# 布局：**不假设 p1=bootfs / p2=rootfs**。
#   hinlink-h88k.csc 没有声明 BOOTFS_TYPE ⇒ 本板构建出来是【单分区】：
#   p1 = rootfs(ext4)，引导文件在 rootfs 的 /boot 里（与官方 H88K 镜像同布局）。
#   只有像官方 easepi-r1.csc 那样声明 BOOTFS_TYPE="fat" 的板才是
#   p1 = bootfs(vfat) + p2 = rootfs(ext4)。
#   历史教训：写死双分区 → 单分区镜像在第一条断言就 exit 1，后面几条一条都没跑
#   （lyw-hh run #6：镜像已上传，自证只打印了「镜像里少于两个分区」）。
#
# 用法：
#   tools/verify-image.sh <image.img>            # 完整自证（需 root 做 loop 挂载）
#   tools/verify-image.sh --probe <image.img>    # 只探测布局（构建前的微型镜像自测也用它）
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

IMG=""
PROBE=0
usage() { echo "用法: $0 [--probe] <image.img>"; exit 2; }
while [[ $# -gt 0 ]]; do
	case "$1" in
		--probe) PROBE=1; shift ;;
		-h|--help) usage ;;
		*) IMG="$1"; shift ;;
	esac
done
[[ -n "$IMG" && -f "$IMG" ]] || usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  OK   $*"; PASS=$((PASS + 1)); }
bad() { echo "  !!   $*"; FAIL=$((FAIL + 1)); }

MNT="$(mktemp -d)"
BOOTMNT="$(mktemp -d)"
LOOP=""
ROOTDEV=""
ROOTLABEL=""
ROOTTYPE=""
BOOTDEV=""
BOOTDIR=""
LAYOUT=""

cleanup() {
	[[ -n "$BOOTDEV" ]] && umount "$BOOTMNT" 2>/dev/null
	[[ -n "$ROOTDEV" ]] && umount "$MNT" 2>/dev/null
	[[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
	rmdir "$BOOTMNT" "$MNT" 2>/dev/null
}
trap cleanup EXIT

print_table() {
	echo "  --- 分区表（诊断用）---"
	sfdisk -d "$IMG" 2>/dev/null | sed 's/^/     /' || true
}

# 探测分区布局：枚举 pN → blkid 取 TYPE / PARTLABEL → 定 rootfs / bootfs。
detect_layout() {
	LOOP="$(losetup --find --show --partscan "$IMG")" || { bad "losetup 失败（需要 root）"; return 1; }

	local parts=() i
	for i in $(seq 1 20); do
		mapfile -t parts < <(ls -1 "${LOOP}"p* 2>/dev/null | sort -V)
		(( ${#parts[@]} > 0 )) && break
		sleep 0.5
	done
	if (( ${#parts[@]} == 0 )); then
		bad "镜像里没有可识别的分区"
		print_table
		return 1
	fi

	echo "  分区（共 ${#parts[@]} 个）:"
	local p t l size best="" bestsize=0 besttype="" bestlabel=""
	for p in "${parts[@]}"; do
		t="$(blkid -s TYPE -o value "$p" 2>/dev/null || true)"
		l="$(blkid -s PARTLABEL -o value "$p" 2>/dev/null || true)"
		size="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
		printf '     %-10s TYPE=%-6s LABEL=%-8s SIZE=%s\n' "${p##*/}" "${t:-?}" "${l:-?}" "$size"
		# rootfs：优先 GPT 分区名 rootfs，其次"最大的可挂载文件系统分区"
		if [[ -z "$ROOTDEV" && "$l" == "rootfs" ]]; then
			ROOTDEV="$p"; ROOTLABEL="$l"; ROOTTYPE="$t"
		fi
		if [[ -z "$BOOTDEV" && ( "$l" == "bootfs" || "$t" == "vfat" || "$t" == "msdos" ) ]]; then
			BOOTDEV="$p"
		fi
		if [[ "$t" =~ ^(ext4|ext3|ext2|xfs|btrfs)$ ]] && (( size > bestsize )); then
			best="$p"; bestsize="$size"; besttype="$t"; bestlabel="$l"
		fi
	done
	if [[ -z "$ROOTDEV" ]]; then
		ROOTDEV="$best"; ROOTTYPE="$besttype"; ROOTLABEL="$bestlabel"
	fi
	[[ -n "$ROOTDEV" ]] || { bad "找不到根文件系统分区"; print_table; return 1; }
	[[ "$ROOTDEV" == "$BOOTDEV" ]] && BOOTDEV=""

	echo "  判定：rootfs=${ROOTDEV} (${ROOTTYPE:-?}${ROOTLABEL:+ /$ROOTLABEL})${BOOTDEV:+，bootfs=${BOOTDEV}}"
	return 0
}

mount_root() {
	mount -o ro,noload "$ROOTDEV" "$MNT" 2>/dev/null || mount -o ro "$ROOTDEV" "$MNT" \
		|| { bad "rootfs 挂载失败 ($ROOTDEV)"; print_table; return 1; }

	# 自保：挂上的必须真的像根文件系统。宁可"探测失败"并打印分区表，
	# 也不要输出一屏与本产物无关的假断言（lyw-rr #4 / lyw-hh #6 都是这么被带偏的）。
	if [[ ! -d "$MNT/etc" || ! -d "$MNT/usr" ]]; then
		bad "挂上的分区不像 rootfs（缺 /etc 或 /usr）"
		print_table
		return 1
	fi

	if [[ -n "$BOOTDEV" ]]; then
		mount -o ro "$BOOTDEV" "$BOOTMNT" 2>/dev/null || true
	fi
	if [[ -n "$BOOTDEV" ]] && [[ -e "$BOOTMNT/armbianEnv.txt" || -d "$BOOTMNT/dtb" ]]; then
		LAYOUT="dual"
		BOOTDIR="$BOOTMNT"
	else
		LAYOUT="single"
		[[ -d "$MNT/boot" ]] && BOOTDIR="$MNT/boot"
	fi
	ok "已挂载：rootfs=$ROOTDEV（${LAYOUT} 分区布局${BOOTDIR:+，bootdir=${BOOTDIR}}）"
	return 0
}

# 解析 systemd unit 的真实文件（跳过 mask 用的 /dev/null 链接与跨根绝对链接）
unit_path() {
	local n="$1" c
	for c in "$MNT/etc/systemd/system/$n" "$MNT/usr/lib/systemd/system/$n" "$MNT/lib/systemd/system/$n"; do
		if [[ -f "$c" && ! -L "$c" ]]; then echo "$c"; return 0; fi
	done
	return 1
}

# 判 .wants 链接：必须 -L，且目标（绝对/相对）在镜像内真的存在
wants_link_ok() {
	local l="$MNT/etc/systemd/system/multi-user.target.wants/$1" t
	[[ -L "$l" ]] || return 1
	t="$(readlink "$l")"
	case "$t" in
		/*) [[ -f "$MNT$t" ]] ;;
		*)  [[ -f "$(dirname "$l")/$t" ]] ;;
	esac
}

echo "== 挂载镜像 =="
detect_layout || exit 1
mount_root || exit 1

if (( PROBE )); then
	echo
	echo "LAYOUT=$LAYOUT ROOTDEV=$ROOTDEV BOOTDIR=$BOOTDIR"
	echo "== 布局探测通过 =="
	exit 0
fi

echo "== 1. 静态口序（本仓写入）=="
if python3 "$ROOT/tools/net-pin-check.py" --conf "$MNT" --src "$ROOT/config/boards/hinlink-h88k.csc" 2>&1 | sed 's/^/     /'; then
	ok "/etc/eth_order 与实机口径一致（eth0/eth1=2.5G PCIe，eth2=千兆平台口）"
else
	bad "/etc/eth_order 不合格（判据=tools/net-pin-check.py）"
fi

echo "== 2. 时钟（本仓 mask）=="
FAKEUNIT=""
for u in lib/systemd/system/fake-hwclock-load.service usr/lib/systemd/system/fake-hwclock-load.service; do
	[[ -e "$MNT/$u" ]] && { FAKEUNIT="$u"; break; }
done
if [[ -n "$FAKEUNIT" ]]; then
	MASK="$MNT/etc/systemd/system/fake-hwclock-load.service"
	if [[ -L "$MASK" && "$(readlink "$MASK")" == "/dev/null" ]]; then
		ok "fake-hwclock-load 已 mask"
	else
		bad "fake-hwclock-load 未 mask（开机用构建日期覆盖 RTC → JWT 立刻过期）"
	fi
else
	echo "  --   镜像内没有 fake-hwclock-load.service（无需 mask）"
fi
if [[ -s "$MNT/etc/fake-hwclock.data" ]]; then
	STAMP="$(cat "$MNT/etc/fake-hwclock.data")"
	if [[ "$STAMP" > "2026-09-01 00:00:00" ]]; then
		ok "fake-hwclock.data 不是构建月（$STAMP）"
	else
		bad "fake-hwclock.data 回退到构建月（$STAMP）"
	fi
else
	bad "缺 /etc/fake-hwclock.data"
fi

echo "== 3. roceos 载荷（本仓注入）=="
for f in opt/roceos/roceos opt/roceos/www/index.html opt/roceos-ai/server.py \
	etc/nginx/sites-available/roceos.conf \
	etc/nginx/ssl/roceos.crt etc/nginx/ssl/roceos.key; do
	[[ -f "$MNT/$f" ]] && ok "$f" || bad "缺 $f"
done
for s in roceos.service roceos-ai.service roceos-vision.service; do
	if wants_link_ok "$s"; then ok "wants: $s"; else bad "缺 wants 链接 $s"; fi
	if unit_path "$s" >/dev/null; then ok "unit 在位: $s"; else bad "缺 unit 文件 $s"; fi
done
if [[ -L "$MNT/etc/nginx/sites-enabled/roceos.conf" ]]; then
	ok "nginx roceos 站点已启用"
else
	bad "nginx roceos 站点未启用"
fi
if [[ -e "$MNT/etc/nginx/sites-enabled/default" ]]; then
	bad "nginx default 站点仍存在（与 roceos.conf 抢 default_server）"
else
	ok "nginx default 站点已移除"
fi

echo "== 4. roceos-ai 语义（本仓覆盖为官方 Easepi-r2 版）=="
AIUNIT="$(unit_path roceos-ai.service || true)"
if [[ -n "$AIUNIT" ]]; then
	grep -q '^RestartPreventExitStatus=3' "$AIUNIT" \
		&& ok "无模型时退出 3 不被重启" || bad "缺 RestartPreventExitStatus=3（会每 5 秒崩溃）"
else
	bad "缺 roceos-ai.service"
fi
grep -q 'sys\.exit(3)' "$MNT/opt/roceos-ai/server.py" 2>/dev/null \
	&& ok "server.py 为官方新版（exit 3）" || bad "server.py 是旧版（exit 1 → 崩溃循环）"

echo "== 5. 管理地址 + 前面板 LED 守护（本仓新增）=="
ADMIN="$MNT/usr/local/sbin/h88k-admin-ip.sh"
if [[ -x "$ADMIN" ]]; then
	ok "h88k-admin-ip.sh 存在且可执行"
	grep -q '192\.168\.100\.1' "$ADMIN" && ok "守护 192.168.100.1" || bad "脚本不维护 192.168.100.1"
	grep -q 'blue:net/trigger' "$ADMIN" && ok "驱动 blue:net" || bad "脚本不驱动 blue:net"
	grep -q 'amber:sata/trigger' "$ADMIN" && ok "驱动 amber:sata" || bad "脚本不驱动 amber:sata"
	grep -q 'br-lan1' "$ADMIN" && ok "LED 绑 LAN 桥（br-lan1）" || bad "脚本未把 blue:net 绑到 br-lan1"
	if grep -q 'pick_iface eth2' "$ADMIN" && grep -q 'class/net/\$1/master' "$ADMIN"; then
		ok "选口逻辑已修（先判 master 是否存在，eth2 不在桥里也加得上地址）"
	else
		bad "管理地址守护仍是旧 readlink -f 逻辑（eth2 不在桥里时 192.168.100.1 永远加不上）"
	fi
else
	bad "缺 /usr/local/sbin/h88k-admin-ip.sh"
fi
if wants_link_ok h88k-admin-ip.service; then
	ok "h88k-admin-ip.service 已启用"
else
	bad "h88k-admin-ip.service 未启用"
fi
if unit_path h88k-admin-ip.service >/dev/null; then
	ok "h88k-admin-ip.service unit 在位"
else
	bad "缺 h88k-admin-ip.service 单元文件"
fi

echo "== 6. 反断言 =="
if grep -qE 'NAME:="(wan1|lan1|lan2)"' "$MNT"/etc/udev/rules.d/*.rules 2>/dev/null; then
	bad "上游 wan1/lan1/lan2 命名残留（与 eth_order 口径冲突）"
else
	ok "无 wan1/lan1/lan2 残留命名"
fi

echo
if [[ $FAIL -eq 0 ]]; then
	echo "== 全部通过（$PASS 项；只覆盖本仓改动项）=="
	exit 0
fi
echo "== 失败 $FAIL 项（通过 $PASS 项）=="
exit 1
