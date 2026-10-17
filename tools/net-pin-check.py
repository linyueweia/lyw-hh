#!/usr/bin/env python3
"""
H88K 网口口径（eth_order）单点判据 —— 构建前查仓库默认值，构建后查镜像内落盘值。

为什么要有这个文件（前车之鉴）：
  lyw-rr 的 run #14 因为 verify-image.sh 里硬编码 `grep 'lan2=eth2'` 与已变更的口径
  打架，4.7GB 镜像全部断言绿、只这一行红，117 分钟白跑。结论：**判据只能有一份**，
  构建前对仓库默认值跑、构建后对镜像内 /etc/eth_order 跑，同一段代码。

口径（用户两次确认，实机 192.168.10.90 验证）：
  eth0 = 0004:41:00.0        RTL8125  2.5G
  eth1 = 0003:31:00.0        RTL8125  2.5G
  eth2 = fe1b0000.ethernet   RTL8211F 千兆   ← 首次开箱 192.168.100.1 落这里
"""
import argparse
import os
import re
import sys

EXPECTED = ["0004:41:00.0", "0003:31:00.0", "fe1b0000.ethernet"]

problems = []


def bad(msg):
    problems.append(msg)
    print("  !! " + msg)


def parse_order(text):
    return [p.strip() for p in text.strip().split(",") if p.strip()]


def check_order(text, where):
    got = parse_order(text)
    if len(got) != 3:
        bad("%s: 期望 3 个口，实际 %d 个 (%s)" % (where, len(got), ",".join(got)))
        return
    if len(set(got)) != 3:
        bad("%s: 有重复口 (%s)" % (where, ",".join(got)))
    for i, (want, have) in enumerate(zip(EXPECTED, got)):
        if want != have:
            bad("%s: eth%d 期望 %s，实际 %s" % (where, i, want, have))
    # 前两个必须是 PCIe（含冒号）的 2.5G 口，最后一个必须是平台千兆口
    if not all(":" in got[i] for i in (0, 1)):
        bad("%s: eth0/eth1 必须是 PCIe 设备（RTL8125），实际 %s" % (where, got[:2]))
    if ":" in got[2]:
        bad("%s: eth2 必须是平台千兆口（fe1b0000），实际 %s" % (where, got[2]))


def check_csc(path):
    """构建前：仓库板级配置必须声明同样的口序 + vendor 内核 + h88k dtb。"""
    text = open(path, encoding="utf-8").read()
    if "0004:41:00.0,0003:31:00.0,fe1b0000.ethernet" not in text:
        bad("csc: 没有写入静态 eth_order 字面量（口序会退回厂商脚本的猜测顺序）")
    m = re.search(r'^KERNEL_TARGET="([^"]+)"', text, re.M)
    if not m:
        bad("csc: 缺 KERNEL_TARGET")
    elif "vendor" not in m.group(1).split(","):
        bad("csc: KERNEL_TARGET=%s 不含 vendor（运行系统是 6.1.115-vendor，r8125 只在厂商树内）" % m.group(1))
    m = re.search(r'^BOOT_FDT_FILE="([^"]+)"', text, re.M)
    if not m or "hinlink-h88k" not in m.group(1):
        bad("csc: BOOT_FDT_FILE 未指向 rk3588-hinlink-h88k.dtb")
    if "post_family_tweaks__lyw_hh_h88k_static_eth_order" not in text:
        bad("csc: 缺静态口序钩子（eth_order 不会被写进镜像）")


def check_conf(root):
    """构建后：镜像内落盘值。root 可以是挂载点或已解开的 rootfs 目录。"""
    order_path = os.path.join(root, "etc/eth_order")
    if not os.path.exists(order_path):
        bad("镜像内缺 /etc/eth_order（fix-ifaces-name 会按内核名走，口序随机）")
    else:
        check_order(open(order_path, encoding="utf-8").read(), "/etc/eth_order")

    # istorenext 首次开箱取"编号最大的 ethN"当默认口 = eth2 = 千兆口。
    # 一旦有人往 .default-network 里写了别的口，插千兆口就进不了后台了。
    dn = os.path.join(root, "root/.default-network")
    if os.path.exists(dn):
        txt = open(dn, encoding="utf-8").read()
        m = re.search(r"DEFAULT_INTERFACE=(\S+)", txt)
        if m and m.group(1) != "eth2":
            bad(".default-network: DEFAULT_INTERFACE=%s，首次开箱 192.168.100.1 会落到 %s 而不是千兆口 eth2"
                % (m.group(1), m.group(1)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", metavar="CSC", help="仓库板级配置文件（构建前）")
    ap.add_argument("--conf", metavar="ROOTFS", help="镜像 rootfs 根目录（构建后）")
    args = ap.parse_args()
    if not args.src and not args.conf:
        ap.error("至少给 --src 或 --conf")

    if args.src:
        print("[src] " + args.src)
        check_csc(args.src)
    if args.conf:
        print("[conf] " + args.conf)
        check_conf(args.conf)

    if problems:
        print("H88K 网口口径判据：%d 处不合格" % len(problems))
        return 1
    print("H88K 网口口径判据：通过（eth0/eth1=2.5G PCIe，eth2=千兆平台口）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
