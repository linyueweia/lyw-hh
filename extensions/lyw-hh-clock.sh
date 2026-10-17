#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# Hinlink H88K 板级扩展：时钟（后台登录即退的根因）
#
# 实机 192.168.10.90 上的故障链（已复现并修好）：
#   1. 镜像里的 /etc/fake-hwclock.data 是构建日期（2026-08-26）；
#   2. fake-hwclock-load.service 开机用它覆盖硬件 RTC 的真实时间；
#   3. roceos 后端签发的 JWT 有效期 24h，签发时系统时间比真实时间早 7 周
#      → token 一出生就过期；
#   4. 前端每 30 s 比对 exp 与本地时间 → 立刻 logout（现象＝"进后台一下就退出"）。
#
# 修法（最小改动，不动 RTC/NTP 的其余策略）：
#   · 把 fake-hwclock-load.service 屏蔽成 /dev/null（systemd 的 mask 语义）；
#   · /etc/fake-hwclock.data 写成构建时间，万一被别的路径加载也不是 2026-08；
#   · 若镜像自带 systemd-timesyncd，确保它开着（运行系统里它是 n/a，手动装过）。
# ══════════════════════════════════════════════════════════════════════════

function post_family_tweaks__lyw_hh_clock_no_fake_hwclock() {
	display_alert "Masking fake-hwclock-load (keeps RTC as time source)" "$EXTENSION" "info"

	install -d -m 0755 "${SDCARD}/etc/systemd/system"

	# systemd mask：/dev/null 软链，任何 enable/start 都不会真的跑
	if [[ -e "${SDCARD}/lib/systemd/system/fake-hwclock-load.service" ]]; then
		ln -sf /dev/null "${SDCARD}/etc/systemd/system/fake-hwclock-load.service"
	fi

	# 时间基准用构建时刻（UTC），格式与 fake-hwclock 一致：YYYY-MM-DD HH:MM:SS
	local stamp
	stamp="$(date -u '+%Y-%m-%d %H:%M:%S')"
	printf '%s\n' "$stamp" > "${SDCARD}/etc/fake-hwclock.data"

	# NTP：镜像自带就开，没装就跳过（不联网硬装，避免构建依赖外网 apt）
	if [[ -f "${SDCARD}/lib/systemd/system/systemd-timesyncd.service" ]]; then
		install -d -m 0755 "${SDCARD}/etc/systemd/system/sysinit.target.wants" \
			"${SDCARD}/etc/systemd/system/multi-user.target.wants"
		ln -sf /lib/systemd/system/systemd-timesyncd.service \
			"${SDCARD}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
	fi

	return 0
}

function post_customize_image__lyw_hh_clock_selfcheck() {
	display_alert "Self-check H88K clock wiring" "$EXTENSION" "info"

	local fail=0
	if [[ -e "${SDCARD}/lib/systemd/system/fake-hwclock-load.service" ]]; then
		[[ "$(readlink "${SDCARD}/etc/systemd/system/fake-hwclock-load.service" 2>/dev/null)" == "/dev/null" ]] \
			|| { display_alert "fake-hwclock-load not masked" "$EXTENSION" "err"; fail=1; }
	fi
	local data="${SDCARD}/etc/fake-hwclock.data"
	[[ -s "$data" ]] || { display_alert "fake-hwclock.data missing" "$EXTENSION" "err"; fail=1; }
	if [[ -s "$data" ]]; then
		grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$data" \
			|| { display_alert "fake-hwclock.data format unexpected: $(cat "$data")" "$EXTENSION" "err"; fail=1; }
		# 绝不允许回退到 2026-08（那正是 JWT 立刻过期的触发条件）
		[[ "$(cat "$data")" > "2026-09-01 00:00:00" ]] \
			|| { display_alert "fake-hwclock.data regressed to build-date 2026-08" "$EXTENSION" "err"; fail=1; }
	fi

	[[ $fail == 0 ]] || exit_with_error "H88K clock self-check failed"
	return 0
}
