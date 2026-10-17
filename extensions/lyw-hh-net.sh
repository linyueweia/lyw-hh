#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# Hinlink H88K 板级扩展：管理地址守护 + 前面板 LED
#
# 这些内容全部是在用户实机 192.168.10.90 上跑通、量过的（2026-10-17），不是推演：
#   · roceos 会重写 /etc/network/interfaces，把 istorenext 首次开箱放下的
#     192.168.100.1 抹掉 → 后台进不去；本扩展每 20 s 把地址补回「千兆口或它所在的桥」
#   · /proc/device-tree/leds 里只有 work 带 linux,default-trigger=default-on，
#     net/sata/user 三颗没有默认触发器 → 开机一直是灭的；本扩展负责设置触发器
#   · 两颗 2.5G 口（RTL8125）的 RJ45 灯只在链路 ≥1G 点亮，100M 不亮 —— 这是 PHY
#     行为，DTS 管不到、驱动也没开关，不要在这里"修"
#
# 为什么地址守护要跟着桥走：roceos 的 LAN 会做 br-lan1 桥，千兆口经常是桥成员；
# 直接把地址加在 eth2 上会被桥吞掉（实测），所以取 eth2 的 master。
# ══════════════════════════════════════════════════════════════════════════

function post_family_tweaks__lyw_hh_admin_ip_and_leds() {
	display_alert "Installing H88K admin-IP + front-panel LED daemon" "$EXTENSION" "info"

	install -d -m 0755 "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"

	cat > "${SDCARD}/usr/local/sbin/h88k-admin-ip.sh" <<'EOS'
#!/bin/sh
# H88K: 保持管理地址 192.168.100.1 在千兆口(或其桥)上 + 前面板 LED 触发器
L=/sys/class/leds
echo netdev >$L/blue:net/trigger 2>/dev/null
echo heartbeat >$L/green:user/trigger 2>/dev/null
echo disk-activity >$L/amber:sata/trigger 2>/dev/null
echo eth0 >$L/blue:net/device_name 2>/dev/null
echo 1 >$L/blue:net/link 2>/dev/null
while :; do
	[ -d /sys/class/net/br-lan1 ] && {
		[ "$(cat $L/blue:net/device_name 2>/dev/null)" != br-lan1 ] && echo br-lan1 >$L/blue:net/device_name
		for x in link rx tx; do echo 1 >$L/blue:net/$x; done
	}
	t=eth2
	m=$(readlink -f /sys/class/net/$t/master 2>/dev/null)
	[ -n "$m" ] && t=${m##*/}
	ip -4 addr show dev "$t" 2>/dev/null | grep -q 192.168.100.1/ || {
		ip link set "$t" up 2>/dev/null
		ip addr add 192.168.100.1/24 dev "$t" 2>/dev/null
	}
	sleep 20
done
EOS
	chmod 0755 "${SDCARD}/usr/local/sbin/h88k-admin-ip.sh"

	cat > "${SDCARD}/etc/systemd/system/h88k-admin-ip.service" <<-'EOU'
	[Unit]
	Description=H88K admin IP (192.168.100.1) + front-panel LED triggers
	After=network.target istorenext-init-network.service
	[Service]
	ExecStart=/usr/local/sbin/h88k-admin-ip.sh
	Restart=always
	RestartSec=3
	[Install]
	WantedBy=multi-user.target
	EOU

	install -d -m 0755 "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf ../h88k-admin-ip.service "${SDCARD}/etc/systemd/system/multi-user.target.wants/h88k-admin-ip.service"

	return 0
}

function post_customize_image__lyw_hh_cma_parity() {
	# cma 与官方对齐：官方 iNextOSA_26.2.1_Easepi-r2 的 armbianEnv.txt 是 extraargs=cma=256M，
	# H88K 运行系统实测也是 256M。这里只做"不得被改动"的断言 —— 不主动改值
	# （曾经把它提到 1G，属于我们自己加的，用户要求按官方来）。
	local envf="${SDCARD}/boot/armbianEnv.txt"
	[[ -f "$envf" ]] || { display_alert "armbianEnv.txt not found, skip cma check" "$EXTENSION" "warn"; return 0; }
	if grep -qE 'cma=[0-9]+[MG]' "$envf"; then
		grep -qE 'cma=256M([[:space:]]|$)' "$envf" 			|| exit_with_error "cma 不是官方口径 256M: $(grep -oE 'cma=[0-9]+[MG]' "$envf" | head -1)"
		display_alert "armbianEnv.txt cma=256M（与官方 R2 一致）" "$EXTENSION" "info"
	else
		display_alert "armbianEnv.txt 未显式给 cma（走内核默认 256M）" "$EXTENSION" "warn"
	fi
	return 0
}

function post_customize_image__lyw_hh_admin_ip_selfcheck() {
	display_alert "Self-check H88K admin-IP/LED wiring" "$EXTENSION" "info"

	local fail=0
	local s="${SDCARD}/usr/local/sbin/h88k-admin-ip.sh"
	[[ -x "$s" ]] || { display_alert "admin-ip script missing/not executable" "$EXTENSION" "err"; fail=1; }
	[[ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/h88k-admin-ip.service" ]] \
		|| { display_alert "admin-ip service not enabled (wants link missing)" "$EXTENSION" "err"; fail=1; }
	# 结构断言（不抄数值口径）：既要管地址，也要管灯，且必须是循环守护
	grep -q '192\.168\.100\.1' "$s" || { display_alert "script does not manage 192.168.100.1" "$EXTENSION" "err"; fail=1; }
	grep -q 'blue:net/trigger' "$s" || { display_alert "script does not drive blue:net" "$EXTENSION" "err"; fail=1; }
	grep -q 'amber:sata/trigger' "$s" || { display_alert "script does not drive amber:sata" "$EXTENSION" "err"; fail=1; }
	grep -q 'while :' "$s" || { display_alert "script is not a persistent loop" "$EXTENSION" "err"; fail=1; }
	sh -n "$s" 2>/dev/null || { display_alert "admin-ip script has shell syntax error" "$EXTENSION" "err"; fail=1; }

	[[ $fail == 0 ]] || exit_with_error "H88K admin-IP/LED self-check failed"
	return 0
}
