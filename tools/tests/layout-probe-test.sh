#!/usr/bin/env bash
# verify-image.sh 的【布局探测】自测 —— 用微型镜像覆盖真实出现过的布局。
#
# 为什么要有它：lyw-hh run #6 的镜像已经编好、artifact 也上传了，自证脚本却因为
# 写死「p1=bootfs / p2=rootfs」、在单分区镜像上直接 exit 1 —— 一条断言都没跑，
# 117 分钟构建只剩「镜像里少于两个分区」这一行日志。这类探测必须在构建前用秒级
# 微型镜像验一遍（与 lyw-rr 的做法一致）。
#
# 用法：sudo bash tools/tests/layout-probe-test.sh   （需要 root 做 loop + mount）
set -uo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/tools/verify-image.sh"
PASS=0
FAIL=0

if [[ "$(id -u)" -ne 0 ]]; then
	echo "SKIP 需要 root（loop 设备 + mount）；CI 里用 sudo 跑"
	exit 0
fi
for t in losetup sfdisk mkfs.ext4 mkfs.vfat mount umount blkid; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIP 缺工具 $t"; exit 0; }
done
[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || { echo "!! 找不到 $SCRIPT"; exit 2; }

TMP="$(mktemp -d)"
LOOPS=()
cleanup() {
	for l in "${LOOPS[@]:-}"; do [[ -n "$l" ]] && losetup -d "$l" 2>/dev/null; done
	rm -rf "$TMP"
}
trap cleanup EXIT

attach() { # $1=img → 打印 loop 设备
	local l
	l="$(losetup --find --show --partscan "$1")" || return 1
	LOOPS+=("$l")
	udevadm settle 2>/dev/null || sleep 1
	echo "$l"
}

check() { # $1=名字 $2=期望(single|dual|fail) $3=img
	local name="$1" want="$2" img="$3" out rc
	out="$(bash "$SCRIPT" --probe "$img" 2>&1)"; rc=$?
	case "$want" in
		fail)
			if [[ $rc -ne 0 ]]; then PASS=$((PASS+1)); echo "  ok   $name（如期判红）"
			else FAIL=$((FAIL+1)); echo "  !!   $name（应判红却通过）"; fi ;;
		single|dual)
			if [[ $rc -eq 0 && "$out" == *"LAYOUT=$want"* ]]; then PASS=$((PASS+1)); echo "  ok   $name（LAYOUT=$want）"
			else FAIL=$((FAIL+1)); echo "  !!   $name（期望 LAYOUT=$want，rc=$rc）"; echo "$out" | sed 's/^/       /'; fi ;;
	esac
}

echo "== 1. 单分区 ext4 rootfs（本板真实布局）=="
IMG="$TMP/single.img"
truncate -s 96M "$IMG"
sfdisk -q "$IMG" <<'EOF'
label: gpt
start=2048, size=120000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="rootfs"
EOF
L="$(attach "$IMG")" || { echo "!! losetup 失败"; exit 1; }
mkfs.ext4 -q -F "${L}p1"
mkdir -p "$TMP/m1"
mount "${L}p1" "$TMP/m1"
mkdir -p "$TMP/m1/etc" "$TMP/m1/usr" "$TMP/m1/boot"
printf 'x\n' > "$TMP/m1/boot/armbianEnv.txt"
umount "$TMP/m1"
losetup -d "$L"
check "单分区 ext4(rootfs) → single" single "$IMG"

echo "== 2. 双分区 vfat(bootfs) + ext4(rootfs)（官方 Easepi-r1 那种布局）=="
IMG="$TMP/dual.img"
truncate -s 128M "$IMG"
sfdisk -q "$IMG" <<'EOF'
label: gpt
start=2048, size=80000, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="bootfs"
start=83968, size=140000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="rootfs"
EOF
L="$(attach "$IMG")" || { echo "!! losetup 失败"; exit 1; }
mkfs.vfat -F 32 -n bootfs "${L}p1" >/dev/null
mkfs.ext4 -q -F "${L}p2"
mkdir -p "$TMP/m2"
mount "${L}p1" "$TMP/m2"
printf 'x\n' > "$TMP/m2/armbianEnv.txt"
umount "$TMP/m2"
mount "${L}p2" "$TMP/m2"
mkdir -p "$TMP/m2/etc" "$TMP/m2/usr"
umount "$TMP/m2"
losetup -d "$L"
check "双分区 bootfs+rootfs → dual" dual "$IMG"

echo "== 3. 单分区 ext4 但不像 rootfs（缺 /etc /usr）→ 必须响亮失败 =="
IMG="$TMP/notroot.img"
truncate -s 64M "$IMG"
sfdisk -q "$IMG" <<'EOF'
label: gpt
start=2048, size=80000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="data"
EOF
L="$(attach "$IMG")" || { echo "!! losetup 失败"; exit 1; }
mkfs.ext4 -q -F "${L}p1"
losetup -d "$L"
check "ext4 但缺 /etc /usr → 判红（不自欺）" fail "$IMG"

echo "== 4. 不是镜像（随机字节）→ 必须判红 =="
IMG="$TMP/garbage.img"
head -c 8M /dev/urandom > "$IMG"
check "随机字节 → 判红" fail "$IMG"

echo
echo "布局探测自测：通过 $PASS 例，失败 $FAIL 例"
[[ $FAIL -eq 0 ]] || exit 1
