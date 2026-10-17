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
# 用法：tools/verify-image.sh <image.img>   （需要 root 做 loop 挂载）
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

IMG="${1:-}"
[[ -n "$IMG" && -f "$IMG" ]] || { echo "用法: $0 <image.img>"; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
ok()  { echo "  OK   $*"; }
bad() { echo "  !!   $*"; FAIL=$((FAIL + 1)); }

MNT="$(mktemp -d)"
BOOTMNT="$(mktemp -d)"
LOOP=""
cleanup() { [[ -n "$LOOP" ]] && { umount "$BOOTMNT" 2>/dev/null; umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }; rmdir "$BOOTMNT" "$MNT" 2>/dev/null; }
trap cleanup EXIT

echo "== 挂载镜像 =="
LOOP="$(losetup --find --show --partscan "$IMG")" || { echo "losetup 失败"; exit 1; }
sleep 1
PARTS=("$LOOP"p*); [[ -e "${PARTS[0]}" ]] || PARTS=("$LOOP"*[0-9])
[[ ${#PARTS[@]} -ge 2 ]] || { bad "镜像里少于两个分区"; exit 1; }
ROOTDEV="${PARTS[1]}"
mount -o ro "$ROOTDEV" "$MNT" || { bad "rootfs 挂载失败 ($ROOTDEV)"; exit 1; }
mount -o ro "${PARTS[0]}" "$BOOTMNT" 2>/dev/null || true
ok "已挂载：rootfs=$ROOTDEV"

echo "== 1. 静态口序（本仓写入）=="
if python3 "$ROOT/tools/net-pin-check.py" --conf "$MNT" 2>&1 | sed 's/^/     /'; then
	ok "/etc/eth_order 与实机口径一致（eth0/eth1=2.5G PCIe，eth2=千兆平台口）"
else
	bad "/etc/eth_order 不合格（判据=tools/net-pin-check.py）"
fi

echo "== 2. 时钟（本仓 mask）=="
if [[ -e "$MNT/lib/systemd/system/fake-hwclock-load.service" ]]; then
	[[ "$(readlink "$MNT/etc/systemd/system/fake-hwclock-load.service" 2>/dev/null)" == "/dev/null" ]] \
		&& ok "fake-hwclock-load 已 mask" \
		|| bad "fake-hwclock-load 未 mask（开机用构建日期覆盖 RTC → JWT 立刻过期）"
fi
if [[ -s "$MNT/etc/fake-hwclock.data" ]]; then
	[[ "$(cat "$MNT/etc/fake-hwclock.data")" > "2026-09-01 00:00:00" ]] \
		&& ok "fake-hwclock.data 不是构建月（$(cat "$MNT/etc/fake-hwclock.data")）" \
		|| bad "fake-hwclock.data 回退到构建月（$(cat "$MNT/etc/fake-hwclock.data")）"
else
	bad "缺 /etc/fake-hwclock.data"
fi

echo "== 3. roceos 载荷（本仓注入）=="
for f in opt/roceos/roceos opt/roceos/www/index.html opt/roceos-ai/server.py \
	etc/systemd/system/roceos.service etc/nginx/sites-available/roceos.conf \
	etc/nginx/ssl/roceos.crt etc/nginx/ssl/roceos.key; do
	[[ -e "$MNT/$f" ]] && ok "$f" || bad "缺 $f"
done
[[ -L "$MNT/etc/nginx/sites-enabled/roceos.conf" ]] && ok "nginx 站点已启用" || bad "nginx roceos 站点未启用"
for s in roceos.service roceos-ai.service roceos-vision.service; do
	[[ -L "$MNT/etc/systemd/system/multi-user.target.wants/$s" ]] && ok "wants: $s" || bad "缺 wants 链接 $s"
done

echo "== 4. roceos-ai 语义（本仓覆盖为官方 Easepi-r2 版）=="
grep -q '^RestartPreventExitStatus=3' "$MNT/etc/systemd/system/roceos-ai.service" 2>/dev/null \
	&& ok "无模型时退出 3 不被重启" || bad "缺 RestartPreventExitStatus=3（会每 5 秒崩溃）"
grep -q 'sys.exit(3)' "$MNT/opt/roceos-ai/server.py" 2>/dev/null \
	&& ok "server.py 为官方新版（exit 3）" || bad "server.py 是旧版（exit 1 → 崩溃循环）"

echo "== 5. 管理地址 + 前面板 LED 守护（本仓新增）=="
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

echo "== 6. 反断言 =="
if grep -qE 'NAME:="(wan1|lan1|lan2)"' "$MNT"/etc/udev/rules.d/*.rules 2>/dev/null; then
	bad "上游 wan1/lan1/lan2 命名残留（与 eth_order 口径冲突）"
else
	ok "无 wan1/lan1/lan2 残留命名"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "== 全部通过（只覆盖本仓改动项）=="; exit 0; }
echo "== 失败 $FAIL 项 =="
exit 1
