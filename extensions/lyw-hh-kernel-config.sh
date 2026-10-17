#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# Hinlink H88K 板级扩展：内核配置断言（三口 + NVMe + LED 的命门）
#
# 依据 = 用户运行系统上的真值（不是猜）：
#   内核 6.1.115-vendor-rk35xx，/boot/config-6.1.115-vendor-rk35xx 实测：
#     CONFIG_STMMAC_ETH=y            ← 平台千兆 MAC（eth2 = fe1b0000）
#     CONFIG_DWMAC_ROCKCHIP=y        ← dwmac-rockchip 胶合层
#     CONFIG_R8125=m                 ← 两个 2.5G 口，树内厂商驱动
#                                      （/lib/modules/.../realtek/r8125/r8125.ko，9.016.01-NAPI-RSS）
#     CONFIG_LEDS_GPIO=y             ← 前面板四颗 LED（net/user/work/sata）
#     CONFIG_LEDS_TRIGGER_NETDEV=y   ← blue:net 绑 br-lan1 用的触发器
#     CONFIG_LEDS_TRIGGER_HEARTBEAT=y← green:user 心跳
#     CONFIG_BLK_DEV_NVME=y / CONFIG_SATA_AHCI_PLATFORM=y / CONFIG_PCIE_DW_PLAT_HOST=y
#
# 本扩展不改这些值以外的任何内核选项；它只做两件事：
#   1. 在 .config 里把上面这些符号钉成实测值（上游 select/default 改动时会纠正回来）；
#   2. Kconfig 入口逐个点名 —— 符号名写错会把自己判死，构建立刻红，而不是上板才发现
#      "两个 2.5G 口没驱动"。
# ══════════════════════════════════════════════════════════════════════════

function custom_kernel_config__lyw_hh_board_symbols() {
	kernel_config_modifying_hashes+=("lyw-hh-kernel-config")

	opts_m+=("R8125")
	opts_y+=("STMMAC_ETH" "DWMAC_ROCKCHIP" "LEDS_GPIO" "LEDS_TRIGGER_NETDEV" \
		"LEDS_TRIGGER_HEARTBEAT" "BLK_DEV_NVME" "SATA_AHCI_PLATFORM" "PCIE_DW_PLAT_HOST")

	if [[ -f .config ]]; then
		grep -qE '^config STMMAC_ETH$' drivers/net/ethernet/stmicro/stmmac/Kconfig \
			|| exit_with_error "STMMAC_ETH Kconfig entry missing (平台千兆 MAC 无驱动 → eth2 消失)"
		grep -qE '^config DWMAC_ROCKCHIP$' drivers/net/ethernet/stmicro/stmmac/Kconfig \
			|| exit_with_error "DWMAC_ROCKCHIP Kconfig entry missing (dwmac 胶合层缺失)"
		grep -qE '^config R8125$' drivers/net/ethernet/realtek/r8125/Kconfig \
			|| exit_with_error "R8125 Kconfig entry missing (两个 2.5G 口无驱动 → 只剩千兆口)"
		grep -qE '^config LEDS_GPIO$' drivers/leds/Kconfig \
			|| exit_with_error "LEDS_GPIO Kconfig entry missing (前面板四颗 LED 不亮)"
		grep -qE '^config LEDS_TRIGGER_NETDEV$' drivers/leds/trigger/Kconfig \
			|| exit_with_error "LEDS_TRIGGER_NETDEV Kconfig entry missing (blue:net 无法绑网口)"
		grep -qE '^config BLK_DEV_NVME$' drivers/nvme/host/Kconfig \
			|| exit_with_error "BLK_DEV_NVME Kconfig entry missing (M.2 NVMe 不可用)"

		display_alert "${EXTENSION}" "H88K symbols pinned: STMMAC_ETH/DWMAC_ROCKCHIP/LEDS_*/NVME/PCIE=y, R8125=m" "info"
	fi
	return 0
}
