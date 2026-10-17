# Rockchip RK3588 SoC octa core 4-16GB eMMC USB3 NVMe SATA 4G WiFi/BT HDMI DP HDMI-In
#
# ⚠️ 本文件 = 上游 jjm2473/armbian-easepi:easepi-v26.02 的
#    config/boards/hinlink-h88k.csc 的分支版本，只做【加法】：保留原板级音频命名与
#    initrd 固件钩子，追加 lyw-hh 自己的口序铁律。
#
# 口序铁律（2026-10-17 与用户在 192.168.10.90 实测定案，见 docs/H88K-适配工作流与判据.md）：
#   eth0 = 0004:41:00.0  RTL8125  2.5G
#   eth1 = 0003:31:00.0  RTL8125  2.5G
#   eth2 = fe1b0000.ethernet  RTL8211F  千兆（DTS 里是平台 GMAC）
#
# 为什么写成静态 /etc/eth_order，而不是让官方 gen-eth-order.sh 去猜：
#   厂商脚本按「SoC 平台口优先、PCIe 口按字典序」排序，实测会把两个 2.5G 口排到
#   千兆口前面（顺序随 PCIe 枚举变动），这就是"ETH0/ETH2 反了"的根因。iNextOS 的
#   /usr/lib/istorenext/fix-ifaces-name 开机只读 /etc/eth_order 改名，所以把这份
#   文件钉死即可；同时 istorenext 首次开箱会把 192.168.100.1 落在"编号最大的 ethN"，
#   也就是 eth2 = 千兆口 —— 正是"插千兆口一定能进后台"的需求，不需要额外配置。
BOARD_NAME="Hinlink H88K"
BOARD_VENDOR="hinlink"
BOARDFAMILY="rockchip-rk3588"
BOARD_MAINTAINER="lyw"
BOARD_FIRMWARE_INSTALL="-full"
BOOTCONFIG="rock-5b-rk3588_defconfig"
# 与用户运行系统一致：6.1.115-vendor-rk35xx（r8125 在树内 drivers/net/ethernet/realtek/r8125）
KERNEL_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3588-hinlink-h88k.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
declare -g UEFI_EDK2_BOARD_ID="h88k" # This _only_ used for uefi-edk2-rk3588 extension

function post_family_tweaks__hinlink_h88k_naming_audios() {
	display_alert "$BOARD" "Renaming hinlink-h88k audios" "info"

	mkdir -p $SDCARD/etc/udev/rules.d/
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi0-sound", ENV{SOUND_DESCRIPTION}="HDMI0 Audio"' > $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi1-sound", ENV{SOUND_DESCRIPTION}="HDMI1 Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmiin-sound", ENV{SOUND_DESCRIPTION}="HDMI-In Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-dp0-sound", ENV{SOUND_DESCRIPTION}="DP0 Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-es8388-sound", ENV{SOUND_DESCRIPTION}="ES8388 Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules

	return 0
}

function post_family_tweaks_bsp__hinlink_h88k_bsp_firmware_in_initrd() {
	display_alert "Adding to bsp-cli" "${BOARD}: firmware in initrd" "info"
	declare file_added_to_bsp_destination # will be filled in by add_file_from_stdin_to_bsp_destination
	add_file_from_stdin_to_bsp_destination "/etc/initramfs-tools/hooks/hinlink-h88k-firmware" <<- 'FIRMWARE_HOOK'
		#!/bin/bash
		[[ "$1" == "prereqs" ]] && exit 0
		. /usr/share/initramfs-tools/hook-functions
		add_firmware "hinlink-h88k-240x135-lcd.bin" # firmware for 240x135 spi lcd
	FIRMWARE_HOOK
	run_host_command_logged chmod -v +x "${file_added_to_bsp_destination}"
}

# ── lyw-hh 追加：口序铁律（静态 eth_order）────────────────────────────────
# 上游这块是空白（只重命名音频），这就是"网口顺序反了"的源头。
function post_family_tweaks__lyw_hh_h88k_static_eth_order() {
	display_alert "$BOARD" "Pinning static /etc/eth_order (eth0/eth1=2.5G, eth2=Gigabit)" "info"

	install -d -m 0755 "${SDCARD}/etc"
	# 口序字面量只在这里出现一次（判据 tools/net-pin-check.py 直接读这一行，
	# 不再另抄一份期望值 —— lyw-rr run #14 就是被"第二份字面量"坑掉 117 分钟）。
	LYW_HH_ETH_ORDER="0004:41:00.0,0003:31:00.0,fe1b0000.ethernet"
	printf '%s\n' "$LYW_HH_ETH_ORDER" > "${SDCARD}/etc/eth_order"

	# 自证：写进去的就是声明的静态值，且不含厂商脚本会生成的那种"猜测顺序"
	local order
	order="$(cat "${SDCARD}/etc/eth_order")"
	[[ "$order" == "$LYW_HH_ETH_ORDER" ]] \
		|| exit_with_error "eth_order 写入内容异常: ${order}"

	return 0
}
