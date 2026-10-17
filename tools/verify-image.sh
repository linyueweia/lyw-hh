#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# Hinlink H88K / iNextOS 镜像自证（构建产物级判据，不依赖上板）
#
# 每条断言都对应一个真实踩过的坑：
#   · 口序反了         → /etc/eth_order 必须与实机口径一致（判据在 tools/net-pin-check.py）
#   · 后台进不去       → fake-hwclock-load 必须被 mask，fake-hwclock.data 不得回退到构建月
#   · 后台是空页面     → roceos 载荷必须落盘 + nginx 站点启用 + wants 链接存在
#   · AI 崩溃循环      → roceos-ai 必须带 ConditionPathExists 门禁
#   · 两个 2.5G 口没了 → 内核 config 里 R8125 / STMMAC_ETH 不能丢
#   · 前面板灯全灭     → admin-ip/LED 守护脚本与 wants 链接必须存在
#
# 用法：tools/verify-image.sh <image.img>   （需要 root 做 loop 挂载）
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

IMG="${1:-}"
[[ -n "$IMG" && -f "$IMG" ]] || { echo "用法: $0 <image.img>"; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  !!   $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  WARN $*"; }

MNT="$(mktemp -d)"
BOOTMNT="$(mktemp -d)"
LOOP=""
cleanup() {
	[[ -n "$LOOP" ]] && { umount "$BOOTMNT" 2>/dev/null; umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
	rmdir "$BOOTMNT" "$MNT" 2>/dev/null
}
trap cleanup EXIT

echo "== 挂载镜像 =="
LOOP="$(losetup --find --show --partscan "$IMG")" || { echo "losetup 失败"; exit 1; }
sleep 1
PARTS=("$LOOP"p*)
[[ -e "${PARTS[0]}" ]] || PARTS=("$LOOP"*[0-9])
[[ ${#PARTS[@]} -ge 2 ]] || { bad "镜像里少于两个分区"; exit 1; }

BOOTDEV="${PARTS[0]}"
ROOTDEV="${PARTS[1]}"
mount -o ro "$ROOTDEV" "$MNT" || { bad "rootfs 挂载失败 ($ROOTDEV)"; exit 1; }
mount -o ro "$BOOTDEV" "$BOOTMNT" 2>/dev/null || warn "boot 分区挂载失败（可能不是 FAT/ext4）"

BOOTDIR="$BOOTMNT"
[[ -f "$BOOTDIR/armbianEnv.txt" ]] || { BOOTDIR="$MNT/boot"; }
ok "已挂载：rootfs=$ROOTDEV boot=$BOOTDEV"

echo "== 1. 引导与 DTB =="
if [[ -f "$BOOTDIR/armbianEnv.txt" ]]; then
	grep -q 'rk3588-hinlink-h88k.dtb' "$BOOTDIR/armbianEnv.txt" \
		&& ok "armbianEnv.txt 指向 rk3588-hinlink-h88k.dtb" \
		|| bad "armbianEnv.txt 未指向 H88K 的 DTB"
	grep -q 'cma=1G' "$BOOTDIR/armbianEnv.txt" \
		&& ok "cma=1G" || bad "armbianEnv.txt 缺 cma=1G（与用户镜像口径不一致）"
else
	bad "找不到 armbianEnv.txt"
fi

DTB=""
for c in "$BOOTDIR/dtb/rockchip/rk3588-hinlink-h88k.dtb" \
	"$MNT/boot/dtb/rockchip/rk3588-hinlink-h88k.dtb" \
	"$MNT/boot/firmware/dtb/rockchip/rk3588-hinlink-h88k.dtb"; do
	[[ -f "$c" ]] && { DTB="$c"; break; }
done
if [[ -n "$DTB" ]]; then
	ok "DTB 存在：${DTB#/mnt/}"
	if command -v dtc >/dev/null 2>&1; then
		dtc -I dtb -O dts "$DTB" -o /tmp/h88k.dts 2>/dev/null
		grep -qi 'hinlink' /tmp/h88k.dts && ok "DTB 含 hinlink 标识" || bad "DTB 不含 hinlink 标识（拷错板子）"
		grep -q 'gpio-leds' /tmp/h88k.dts && ok "DTB 有 gpio-leds（前面板四颗灯）" || bad "DTB 缺 gpio-leds"
		grep -q 'fe1b0000' /tmp/h88k.dts && ok "DTB 有 fe1b0000 GMAC（千兆口）" || warn "DTB 里没找到 fe1b0000 字面量"
	else
		warn "环境无 dtc，跳过 DTB 内容检查"
	fi
else
	bad "镜像里找不到 rk3588-hinlink-h88k.dtb"
fi

echo "== 2. 网口口径（eth_order）=="
if python3 "$ROOT/tools/net-pin-check.py" --conf "$MNT" 2>&1 | sed 's/^/     /'; then
	ok "eth_order / .default-network 符合本板口径"
else
	bad "网口口径不合格（见上面 !! 行；判据=tools/net-pin-check.py）"
fi

echo "== 3. 时钟（后台登录即退的根因）=="
if [[ -e "$MNT/lib/systemd/system/fake-hwclock-load.service" ]]; then
	[[ "$(readlink "$MNT/etc/systemd/system/fake-hwclock-load.service" 2>/dev/null)" == "/dev/null" ]] \
		&& ok "fake-hwclock-load 已 mask" \
		|| bad "fake-hwclock-load 未 mask（开机用构建日期覆盖 RTC → roceos JWT 立刻过期）"
else
	warn "镜像无 fake-hwclock-load.service（无需 mask）"
fi
if [[ -s "$MNT/etc/fake-hwclock.data" ]]; then
	[[ "$(cat "$MNT/etc/fake-hwclock.data")" > "2026-09-01 00:00:00" ]] \
		&& ok "fake-hwclock.data 时间不早于 2026-09" \
		|| bad "fake-hwclock.data 回退到构建月（$(cat "$MNT/etc/fake-hwclock.data")）"
else
	bad "缺 /etc/fake-hwclock.data"
fi

echo "== 4. roceos 后台 =="
for f in opt/roceos/roceos opt/roceos/www/index.html opt/roceos-ai/server.py \
	etc/systemd/system/roceos.service etc/nginx/sites-available/roceos.conf \
	etc/nginx/ssl/roceos.crt etc/nginx/ssl/roceos.key; do
	[[ -e "$MNT/$f" ]] && ok "$f" || bad "缺 $f"
done
[[ -L "$MNT/etc/nginx/sites-enabled/roceos.conf" ]] && ok "nginx 站点已启用" || bad "nginx roceos 站点未启用"
[[ -e "$MNT/etc/nginx/sites-enabled/default" ]] && bad "default 站点仍在（会抢 default_server）" || ok "default 站点已移除"
for s in roceos.service roceos-ai.service roceos-vision.service; do
	[[ -L "$MNT/etc/systemd/system/multi-user.target.wants/$s" ]] && ok "wants: $s" || bad "缺 wants 链接 $s"
done
grep -q '^RestartPreventExitStatus=3' "$MNT/etc/systemd/system/roceos-ai.service" 2>/dev/null \
	&& ok "roceos-ai 无模型时退出 3 不被重启（官方语义）" \
	|| bad "roceos-ai 缺 RestartPreventExitStatus=3（缺模型会每 5 秒崩溃）"
grep -q 'sys.exit(3)' "$MNT/opt/roceos-ai/server.py" 2>/dev/null \
	&& ok "roceos-ai server.py 为官方新版（exit 3）" \
	|| bad "roceos-ai server.py 是旧版（exit 1 → 崩溃循环）"

echo "== 5. 管理地址 + 前面板 LED 守护 =="
if [[ -x "$MNT/usr/local/sbin/h88k-admin-ip.sh" ]]; then
	ok "h88k-admin-ip.sh 存在且可执行"
	grep -q '192\.168\.100\.1' "$MNT/usr/local/sbin/h88k-admin-ip.sh" && ok "守护 192.168.100.1" || bad "脚本不维护 192.168.100.1"
	grep -q 'blue:net/trigger' "$MNT/usr/local/sbin/h88k-admin-ip.sh" && ok "驱动 blue:net" || bad "脚本不驱动 blue:net"
	grep -q 'amber:sata/trigger' "$MNT/usr/local/sbin/h88k-admin-ip.sh" && ok "驱动 amber:sata" || bad "脚本不驱动 amber:sata"
else
	bad "缺 /usr/local/sbin/h88k-admin-ip.sh"
fi
[[ -L "$MNT/etc/systemd/system/multi-user.target.wants/h88k-admin-ip.service" ]] \
	&& ok "h88k-admin-ip.service 已启用" || bad "h88k-admin-ip.service 未启用"

echo "== 6. 内核驱动（三口命门）=="
KVER="$(ls "$MNT/lib/modules" 2>/dev/null | head -1)"
if [[ -n "$KVER" ]]; then
	ok "内核版本目录：$KVER"
	CFG="$BOOTDIR/config-$KVER"
	[[ -f "$CFG" ]] || CFG="$MNT/boot/config-$KVER"
	if [[ -f "$CFG" ]]; then
		grep -qx 'CONFIG_STMMAC_ETH=y' "$CFG" && ok "STMMAC_ETH=y（千兆口）" || bad "STMMAC_ETH 不是 y（eth2 会消失）"
		grep -qx 'CONFIG_DWMAC_ROCKCHIP=y' "$CFG" && ok "DWMAC_ROCKCHIP=y" || bad "DWMAC_ROCKCHIP 不是 y"
		grep -qE '^CONFIG_R8125=(y|m)$' "$CFG" && ok "R8125 内建/模块（两个 2.5G 口）" || bad "R8125 未启用（两个 2.5G 口没有驱动）"
		grep -qx 'CONFIG_LEDS_TRIGGER_NETDEV=y' "$CFG" && ok "LEDS_TRIGGER_NETDEV=y" || bad "缺 LEDS_TRIGGER_NETDEV（blue:net 绑不了网口）"
		grep -qx 'CONFIG_LEDS_TRIGGER_HEARTBEAT=y' "$CFG" && ok "LEDS_TRIGGER_HEARTBEAT=y" || warn "缺 heartbeat 触发器"
		grep -qx 'CONFIG_BLK_DEV_NVME=y' "$CFG" && ok "BLK_DEV_NVME=y" || warn "NVMe 未内建"
	else
		warn "找不到 /boot/config-$KVER"
	fi
	R8125KO="$(find "$MNT/lib/modules/$KVER" -name 'r8125.ko*' 2>/dev/null | head -1)"
	[[ -n "$R8125KO" ]] && ok "r8125.ko 已安装（${R8125KO##*/}）" || bad "镜像内没有 r8125.ko"
else
	bad "镜像内没有 /lib/modules（内核未装）"
fi

echo "== 7. 反断言 =="
if ls "$MNT"/etc/udev/rules.d/*.rules >/dev/null 2>&1; then
	if grep -qE 'NAME:="(wan1|lan1|lan2)"' "$MNT"/etc/udev/rules.d/*.rules 2>/dev/null; then
		bad "上游 wan1/lan1/lan2 命名残留（iNextOS 拿不到 eth* 口名）"
	else
		ok "无 wan1/lan1/lan2 残留命名"
	fi
fi

echo
if [[ $FAIL -eq 0 ]]; then
	echo "== 全部通过 =="
	exit 0
fi
echo "== 失败 $FAIL 项 =="
exit 1
