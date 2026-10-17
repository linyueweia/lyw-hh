#!/usr/bin/env python3
"""
H88K 网口口径（eth_order）单点判据 —— 构建前查仓库默认值，构建后查镜像内落盘值。

为什么要有这个文件（前车之鉴）：
  lyw-rr 的 run #14 因为 verify-image.sh 里硬编码 `grep 'lan2=eth2'` 与已变更的口径
  打架，4.7GB 镜像全部断言绿、只这一行红，117 分钟白跑。结论：**判据只能有一份**：
  期望口序只从板级 csc 的 `LYW_HH_ETH_ORDER=` 读，本文件里不再写任何板级地址字面量。

口径（用户两次确认，实机 192.168.10.90 验证）：
  eth0 / eth1 = 两个 RTL8125 的 PCIe BDF（dddd:bb:dd.f）
  eth2        = 平台 GMAC 节点（xxxxxxxx.ethernet，RTL8211F 千兆）
  首次开箱 192.168.100.1 落在编号最大的 ethN = eth2 = 千兆口
具体地址只在板级 csc 的 LYW_HH_ETH_ORDER 里写一次（本文件不抄）。

判据写「语义」而不是「某次定案的字符串」：
  · 恰好三个口、互不重复；
  · 前两个是 PCIe 设备（BDF 形式 dddd:bb:dd.f）→ 两个 2.5G；
  · 最后一个是平台节点（xxxxxxxx.ethernet）→ 千兆；
  · 给了 --src 时，镜像内落盘值必须与 csc 声明**逐字相同**（口径单点，不抄第二份）。
"""
import argparse
import os
import re
import sys

problems = []

PCIE_RE = re.compile(r"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$")
PLAT_RE = re.compile(r"^[0-9a-f]{8}\.ethernet$")
ORDER_RE = re.compile(r'^\s*LYW_HH_ETH_ORDER="([^"]+)"\s*$', re.M)


def bad(msg):
    problems.append(msg)
    print("  !! " + msg)


def parse_order(text):
    return [p.strip() for p in text.strip().split(",") if p.strip()]


def check_semantics(got, where):
    """只写性质：两个 PCIe 2.5G 在前、平台千兆在末、三口互不重复。"""
    if len(got) != 3:
        bad("%s: 期望 3 个口，实际 %d 个 (%s)" % (where, len(got), ",".join(got)))
        return
    if len(set(got)) != 3:
        bad("%s: 有重复口 (%s)" % (where, ",".join(got)))
    for i in (0, 1):
        if not PCIE_RE.match(got[i]):
            bad("%s: eth%d 不是 PCIe 设备（RTL8125 应为 dddd:bb:dd.f），实际 %s" % (where, i, got[i]))
    if not PLAT_RE.match(got[2]):
        bad("%s: eth2 不是平台千兆口（应为 xxxxxxxx.ethernet），实际 %s" % (where, got[2]))


def read_src_order(path):
    text = open(path, encoding="utf-8").read()
    m = ORDER_RE.search(text)
    if not m:
        bad("csc: 缺 LYW_HH_ETH_ORDER=\"...\" 声明（口序不会被写进镜像）")
        return None, text
    order = m.group(1)
    # 字面量只准出现一次：第二份期望值正是 lyw-rr #14 白跑的根因
    if text.count(order) != 1:
        bad("csc: 口序字面量出现 %d 次（应恰好 1 次，且只在 LYW_HH_ETH_ORDER 声明处）"
            % text.count(order))
    return order, text


def check_csc(path):
    """构建前：仓库板级配置必须声明同样的口序 + vendor 内核 + h88k dtb + 静态钩子。"""
    order, text = read_src_order(path)
    if order:
        check_semantics(parse_order(order), "csc LYW_HH_ETH_ORDER")

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
    if "eth_order" not in text:
        bad("csc: 没有任何 eth_order 写入动作")


def check_conf(root, expected):
    """构建后：镜像内落盘值。root 可以是挂载点或已解开的 rootfs 目录。"""
    order_path = os.path.join(root, "etc/eth_order")
    if not os.path.exists(order_path):
        bad("镜像内缺 /etc/eth_order（fix-ifaces-name 会按内核名走，口序随机）")
    else:
        got = parse_order(open(order_path, encoding="utf-8").read())
        check_semantics(got, "/etc/eth_order")
        if expected:
            want = parse_order(expected)
            if got != want:
                bad("/etc/eth_order 与 csc 声明不一致：期望 %s，实际 %s"
                    % (",".join(want), ",".join(got)))

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
    ap.add_argument("--src", metavar="CSC", help="仓库板级配置文件（构建前）；同时提供 --conf 的期望值")
    ap.add_argument("--conf", metavar="ROOTFS", help="镜像 rootfs 根目录（构建后）")
    args = ap.parse_args()
    if not args.src and not args.conf:
        ap.error("至少给 --src 或 --conf")

    expected = None
    if args.src:
        print("[src] " + args.src)
        check_csc(args.src)
        m = ORDER_RE.search(open(args.src, encoding="utf-8").read())
        expected = m.group(1) if m else None
    if args.conf:
        print("[conf] " + args.conf)
        check_conf(args.conf, expected)

    if problems:
        print("H88K 网口口径判据：%d 处不合格" % len(problems))
        return 1
    print("H88K 网口口径判据：通过（eth0/eth1=2.5G PCIe，eth2=千兆平台口）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
