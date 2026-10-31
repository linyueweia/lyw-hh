# Rockchip RK3588 SoC octa core 4-16GB eMMC USB3 NVMe SATA 4G WiFi/BT HDMI DP HDMI-In
#
# ⚠️ 本文件 = 上游 jjm2473/armbian-easepi:easepi-v26.02 的
#    config/boards/hinlink-h88k.csc 的分支版本：保留原板级音频命名与 initrd 固件钩子，
#    追加/覆盖以下几处（每处都对应一处与官方发布件的偏差）：
#      ① 口序铁律：静态 /etc/eth_order（上游空白，靠厂商脚本猜 → ETH0/ETH2 反了）
#      ② RELEASE 钉死（框架无板级默认，不钉会停在交互选择）
#      ③ 桌面开关保持官方 csc 同值（FULL_DESKTOP/BOOT_LOGO）；桌面由 CI 的 BUILD_DESKTOP=no 关掉
#      ④ NETWORKING_STACK="none"（官方发布件里没有 network-manager）
#      ⑤ hold dtb + smartmontools「包在、不启用」（官方 R1/R2 同款做法）
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
# KERNEL_TARGET 与官方 csc 同值（官方 hinlink-h88k.csc = "vendor,edge"）：它只声明
# 「本板支持哪些分支」，实际编哪个分支由 CI 的 BRANCH=vendor 决定 ⇒ 不影响产物。
KERNEL_TARGET="vendor,edge"

# ── 根文件系统发行版（与 CI 的 RELEASE=trixie、README 同值）──────────────
# 框架没有板级/家族默认 RELEASE（rockchip64_common.inc 与 rk35xx.conf 都不设），
# 不传就停在交互选择 —— 漏传一次，本地产物就和 CI 产物不是同一个发行版。
# 官方 iNextOS 发布件（Easepi-r1/r2）是 Debian trixie、文件名带 `_minimal`。
declare -g RELEASE="trixie"

# 桌面开关：与官方 csc 同值（FULL_DESKTOP 是框架的废弃变量，全仓无读取者；
# BOOT_LOGO 仅在 BUILD_DESKTOP=yes 时生效，见 distro-agnostic.sh:591）。
# 官方发布件同样是「csc 写 yes + CI 传 BUILD_DESKTOP=no」⇒ CLI 产物；本仓照抄。
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3588-hinlink-h88k.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
declare -g UEFI_EDK2_BOARD_ID="h88k" # This _only_ used for uefi-edk2-rk3588 extension

# 网络栈：不装 NetworkManager（与官方发布件一致）。
# 官方 EasePi R1 镜像实测 dpkg 里根本没有 network-manager：网络由
# ifupdown-ng(networking.service) + roceos(建 br-lan1/挂口/写 dnsmasq) + dnsmasq 管。
# 框架默认（NETWORKING_STACK 为空）会按 BUILD_MINIMAL 推导，落到 NM → 把 br-lan1 的
# 端口当独立网卡跑 DHCP，45s 超时后 `released from controller device` 把口摘出桥。
# 显式置 none（框架 main-config 的正式取值，走 "Not adding networking extensions" 分支）。
declare -g NETWORKING_STACK="none"

# ── 扩展与本地构建（参数必须与 CI 完全一致）──────────────────────────────
# CI 用 ENABLE_EXTENSIONS="istorenext,lyw-hh-roceos,lyw-hh-net,lyw-hh-clock"，本地构建不带
# 就出一个没有 roceos 后台、没有口序/管理地址的镜像，且过程不报错：
#   ./compile.sh build BOARD=hinlink-h88k BRANCH=vendor RELEASE=trixie \
#     ENABLE_EXTENSIONS="istorenext,lyw-hh-roceos,lyw-hh-net,lyw-hh-clock" \
#     BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no EXPERT=yes
#
# BUILD_MINIMAL=yes 是官方口径（不是性能选项）：官方发布件文件名带 `_minimal`，
# 实测 718 包；传 no 会装整份 config/cli/<rel>/main/packages.additional（实测 958 包），
# 其中 avahi-autoipd 在 DHCP 失败时塞 169.254、unattended-upgrades 后台升级并重启网络服务
# —— 都会表现成「网口灯亮、下级设备拿不到 IP / 用几小时就掉」，官方 minimal 完全没有。
# CI 已加硬断言：镜像名含 _minimal + 上述包不得出现在 dpkg 状态里。

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

# ── 对齐官方发布件：钉住本板 DTB + smartmontools「包在、不启用」─────────────
# ① hold dtb：官方 easepi-r1.csc / easepi-r2.csc 都有同名钩子
#      chroot_sdcard apt-mark hold linux-dtb-vendor-rk35xx
#    本板 family=rockchip-rk3588 的 vendor 分支 LINUXFAMILY=rk35xx ⇒ 包名正是这个。
#    作用：armbian-upgrade 不会把本板 DTB 删掉/换掉（换掉＝口序/PCIe/加速器全丢）。
function post_family_tweaks__lyw_hh_hold_dtb() {
	display_alert "$BOARD" "Prevent armbian-upgrade from removing our dtb" "info"
	chroot_sdcard apt-mark hold linux-dtb-vendor-rk35xx || true
	return 0
}

# ② smartmontools：官方 R1 发布件实测「/usr/lib/systemd/system/smartmontools.service 存在，
#    但 multi-user.target.wants 里没有它的启用链接」（官方 wants 共 30 个）。
#    我们的镜像因 Debian trixie 的 preset（smartmontools: enabled）构建期自动生成链接，
#    每次开机必 failed —— eMMC 不支持 SMART，smartd 退出码 17「No devices to monitor」。
#    修法＝只删启用链接、保留包（官方 R1 同样发行这个包，卸载才是自造差异）。
function post_family_tweaks__lyw_hh_disable_smartmontools() {
	display_alert "$BOARD" "Align smartmontools with official R1 (package present, NOT enabled)" "info"
	rm -f "${SDCARD}/etc/systemd/system/multi-user.target.wants/smartmontools.service"
	rm -f "${SDCARD}/etc/systemd/system/smartd.service"
	if [ -e "${SDCARD}/etc/systemd/system/multi-user.target.wants/smartmontools.service" ] ||
	   [ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/smartmontools.service" ]; then
		exit_with_error "smartmontools enable link still present in image (official R1: package ships, NOT enabled)"
	fi
	if ! grep -q "^Package: smartmontools$" "${SDCARD}/var/lib/dpkg/status" 2>/dev/null; then
		exit_with_error "smartmontools package missing; official R1 ships it — disable only, do NOT uninstall"
	fi
	return 0
}
