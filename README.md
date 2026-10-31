# lyw-hh — Hinlink H88K（RK3588）iNextOS 仓库化构建

从上游框架 [jjm2473/armbian-easepi @ easepi-v26.02](https://github.com/jjm2473/armbian-easepi)
编译 H88K 的 iNextOS 镜像，并把**用户实机 192.168.10.90 上验证过的修正**固化成代码。

官方镜像（`iNextOSA_26.2.1_H88K_trixie_vendor_6.1.115.img`）刷上去有下列问题，本仓全部修掉：

| # | 现象 | 根因 | 本仓修法 |
|---|------|------|----------|
| 1 | 网口顺序反了（ETH0↔ETH2） | 厂商 `gen-eth-order.sh` 按「平台口优先 + PCIe 字典序」猜顺序，上游 csc 里没有任何口序代码 | 板级 csc 写死静态 `/etc/eth_order`：`eth0=0004:41(2.5G) eth1=0003:31(2.5G) eth2=fe1b0000(千兆)` |
| 2 | 进后台一下就退出 | `/etc/fake-hwclock.data` 是构建日期（2026-08-26），开机覆盖 RTC → roceos JWT 一签发就过期 | `mask` 掉 `fake-hwclock-load.service`，`.data` 写构建时刻 |
| 3 | 前面板系统灯不亮 | DTS 本身没问题（GPIO/标注都对），只是 `net/sata/user` 没写 `linux,default-trigger`，开机无人驱动 | `h88k-admin-ip.service` 守护设置 `blue:net=netdev(br-lan1)`、`green:user=heartbeat`、`amber:sata=disk-activity` |
| 4 | 后台每 5 秒崩一次（`NRestarts=206`） | 26.2.1 载荷里 `server.py` 缺模型时 `sys.exit(1)` + `Restart=on-failure` → 无限重启；官方 **Easepi-r2** 新版改为 `sys.exit(3)` + unit `RestartPreventExitStatus=3` | 用官方那两份文件覆盖载荷（sha256 钉死），与官方行为一致 |
| 5 | 千兆口（`fe1b0000`，RTL8211F）偶发「灯亮、协商 1000M、但整口收不到包 → 下级设备 30s 后自分配 169.254，拔插网线即恢复」 | 1000T EEE 的唤醒竞争：vendor 6.1 的 `stmmac_main.c` 以 `rx_clk_runs_in_lpi=0` 调 `phy_init_eee()` → PHY 在 LPI 期间停 xMII RX 时钟，唤醒失败就丢帧；`carrier` 仍在、错误计数不涨，所以从接口上看不出来（iNextOS 线 K1/T68M 已定案同一机制） | 板级 DTS（`patch/kernel/rk35xx-vendor-6.1/dt/rk3588-hinlink-h88k.dts`）在 `&mdio0` 的 `rgmii_phy`（`phy@1`）节点写 `eee-broken-1000t`：只关 1G 的 EEE、100M 不动，不需要任何用户态脚本。两个 2.5G（RTL8125）是 PCIe 网卡、不走 phylib，DT 属性对它们无效 |

另外保持官方口径：`192.168.100.1` 常驻千兆口（或其桥），`cma=256M`（与官方 Easepi-r2 镜像一致）。

## 关机后风扇仍转、网口灯常亮 —— 官方原样，本仓不修

现象：`poweroff` 之后 CPU 停了、SSH 断了，但风扇还在转、网口灯还亮，像没断电。

根因（代码级，vendor 6.1 树）：

- 关机断电只有一条链 `pm_power_off`。兜底是 `drivers/firmware/psci/psci.c:618` 的
  `pm_power_off = psci_sys_poweroff`（PSCI SYSTEM_OFF → ATF）。
- RK809/RK817 板还有第二条：`drivers/mfd/rk808.c:1533` **仅当** DTS 写
  `rockchip,system-power-controller` 才注册 `rk808_pm_power_off`（写 SLPPIN_DN_FUN +
  `pinctrl_select_state("pmic-power-off")`）→ 这才是真正把 PMIC 主输出关掉。
- **RK806 板（本板 / Easepi R2）没有第二条**：`drivers/mfd/rk806-core.c:630` 只
  `pinctrl_lookup_state("pmic-power-off")`、**全文件从不 select**；`rk806-spi.c` 也没有
  `.shutdown`；整棵树找不到任何 rk806 的 `pm_power_off` 注册 ⇒ 加
  `rockchip,system-power-controller` 也无效，只能走 PSCI/ATF。

官方怎么配的：`rk3588-easepi-r2.dts` 只 include `rk3588-rk806-single.dtsi`，**没有**
system-power-controller（R1 的 `rk3568-easepi-r1.dts` / `rk3568-roc-k40pro.dtsi` 同样 0 处）
⇒ **官方 R2 关机也不断主电源**，风扇/网口灯同样亮。

判据（在出问题的机器上跑一次即可定性）：

```bash
journalctl -b -1 --no-pager | tail -5     # reboot: Power down = 走了 poweroff；System halted = 只 halt
ls /sys/bus/spi/devices/                  # RK806 在 SPI 上；RK809 在 I2C 上
```

**本仓决定：不修**（2026-10-31 定案，与官方对齐优先）。要真断电只能给 vendor 内核打
rk806 的 poweroff 补丁（照 `rk808.c` 写法注册 SYS_OFF + select 那个已经备好但没人用的
`pmic-power-off` pinctrl state），那属于**有意偏离官方**的内核改动，未做。

## AI 服务：官方镜像里同样没有模型（实测）

对比 `iNextOSA_26.2.1_Easepi-r2_..._minimal.img`（官方，能"跑 AI"）与 H88K 那份：

| | Easepi-r2（官方） | H88K 26.2.1 |
|---|---|---|
| `/opt/roceos-ai` 内容 | `librkllmrt.so` + `server.py`，**没有 model.conf / .rkllm** | 同 |
| 无模型时 | `sys.exit(3)` | `sys.exit(1)` |
| unit | `RestartPreventExitStatus=3`（不重启）+ 无 `Wants=roceos.service` | 无该行 + `Wants=roceos.service` |
| 结果 | 服务干净退出，模型下载后由后端拉起 | 每 5 秒崩溃重启（实机 `NRestarts=206`） |

所以"官方能跑 AI"不是因为它带了模型，而是因为它**不会崩**、且等模型经后台下载后再启动。
本仓直接采用官方那两份文件（`files/roceos-ai/`，sha256 钉死），H88K 也就有了同样的行为。
要真正启用推理：把模型（`.rkllm`）放进设备，写 `/opt/roceos-ai/model.conf`（一行＝模型绝对路径），
再 `systemctl start roceos-ai`。

## 网口灯规律（实测定案，别再当故障）

| 口 | 芯片 | 100M | 1G | 2.5G |
|----|------|------|----|------|
| eth0/eth1 | RTL8125（2.5G） | 灭 | 亮 | 亮 |
| eth2 | RTL8211F（千兆） | 亮 | 亮 | — |

RJ45 灯由 PHY 自己驱动，DTS 里没有网口 LED 节点，`r8125` 也没有 LED 参数 —— 软件改不了，
亮/灭只反映链路速率。想看"任意速率都有链路指示"用前面板 `blue:net`（已绑 LAN 桥，谁有流量都闪）。

## 构建

GitHub Actions，两种档位（`workflow_dispatch`）：

- `adapted`（默认）：本仓适配层，产物＝和实机同行为的镜像
- `official`：纯上游 + istorenext，一行不改，用来做对照（口序反/后台退/灯灭都是它的原状）

```bash
./compile.sh build BOARD=hinlink-h88k BRANCH=vendor RELEASE=trixie \
  ENABLE_EXTENSIONS="istorenext,lyw-hh-roceos,lyw-hh-net,lyw-hh-clock" \
  BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  COMPRESS_OUTPUTIMAGE="sha,img,xz" SHARE_LOG=yes EXPERT=yes
```

**`BUILD_MINIMAL=yes` 是官方口径，不是性能选项**：官方 `iNextOSA_26.2.1_Easepi-r2_…_minimal.img`
文件名就带 `_minimal`（框架只在 yes 时加这个后缀）、实测 718 包。传 `no` 会装整份
`config/cli/<rel>/main/packages.additional`（实测 958 包），其中 `avahi-autoipd` 在 DHCP 失败时
往网卡塞 169.254 地址、`unattended-upgrades` 后台升级并重启 dnsmasq/网络服务 —— 两者都会表现成
「网口灯亮、下级设备拿不到 IP / 用几小时就掉」，官方 minimal 完全没有。CI 与 `verify-image.sh`
各有硬断言（镜像名必须含 `_minimal` + 上述包不得出现在 dpkg 状态里）。

参考基线：运行系统内核 `6.1.115-vendor-rk35xx`（`R8125=m / STMMAC_ETH=y / DWMAC_ROCKCHIP=y`）——
这些是厂商树默认值，本仓**不改也不断言**。

## 包集合口径（与官方 minimal 逐包对齐，2026-10-31 定案）

**结论**：本仓镜像的 dpkg 包集合 = 框架官方 minimal 口径；本仓的扩展**不额外加任何包**。

判据单点：`tools/packages-parity-check.py`（`--selftest` 跑 3 正例 + 6 负例 + 1 聚合口径自测）。

- 旧判据把 `packages.additional` 整份当黑名单，只要成员出现在镜像里就判红 →
  **`BUILD_MINIMAL=yes` 明明生效，仍然打出 15 条红**（lyw-rr run #39 / lyw-hh run #26），
  整轮 2 小时白跑。错的不是包，是判据。
- `packages.additional` 的成员有四个「官方 minimal 镜像里同样存在」的合法来源：
  1. 框架自己的 rootfs 清单（**三层聚合**：`config/cli/<rel>/main/packages` +
     `config/optional/_any_board/_config/…` + `config/optional/architectures/<arch>/_config/…`）
     —— `sudo` `wget` `bash-completion` `htop` `wireless-regdb`，**以及只写在
     arm64 optional 层的 `gpiod`**（只看 `config/cli/…` 会把它误判成「多出来的包」）；
  2. `extensions/istorenext.sh` 的 `add_packages_to_image` —— `git` `unzip` `ntfs-3g`
     `nfs-common` `smartmontools`；
  3. 上面两者的 Depends/Recommends 传递依赖 —— `keyboard-configuration ← console-setup`、
     `libpam-systemd ← systemd-sysv ← init`、`iptables ← wireguard-tools`、
     `apt-utils ← debconf ← iproute2`；
  4. apt 的 `Auto-Installed` 记录（镜像里 `/var/lib/apt/extended_states` 在时）。
- 现判据 = **来源减法**：只有「出现 ∩ 不属于以上四类」的成员才判红 ——
  `BUILD_MINIMAL=no`（整份 additional 进镜像）或有人手工装 additional 包时立刻红。
  实测：用真实镜像同口径数据跑，上述 15 项全部有来源、判据绿；再造「整份装进来」负例，判据红。
- Flask 栈**保留**构建期 `apt-get install python3-flask …`（≈ 与官方同口径）：
  2026-10-31 取官方 **A2 2.9.1** 镜像（sha256 `a8cdf1d2…`，716 包）实测，
  官方里面确实装着 `python3-flask/-werkzeug/-jinja2/-itsdangerous/-markupsafe/-blinker`
  这 6 个包 ⇒ 我们原先的写法是对的，不要为了"少几个包"去删它；
  载荷里的 `dist-packages` 只作 apt 无 DNS 时的兜底。
- **roceos 版本口径（2026-10-31）**：镜像内置 roceos = 官方在线通道的最新版 **3.0.2**
  （`channel=stable_arm`、`arch=arm64`，取自官方更新服务器 `update.roceos.com:14380` +
  在役实机 OTA 后的 `/opt/roceos`）。版本记录在 `official-roceos.txt`；
  `.github/workflows/check-roceos.yml` 每天比对一次，官方发了新版就红（= 该重建载荷）。
  取件与打包步骤见 `docs/` 的「roceos 载荷怎么跟官方版本」。

- 与官方 csc 的对齐（2026-10-31）：`FULL_DESKTOP`/`BOOT_LOGO` 恢复官方同值
  （前者是框架废弃变量，`lib/` 全仓无读取者；后者只在 `BUILD_DESKTOP=yes` 时生效，
  见 `distro-agnostic.sh:591`），桌面仍由 CI 的 `BUILD_DESKTOP=no` 关掉 —— 产物不变，
  csc 不再自造差异。

## 判据（构建前 + 构建后同一份代码）

```bash
# 构建前：仓库默认值（期望口序只从 csc 的 LYW_HH_ETH_ORDER 读，判据里不抄第二份）
python3 tools/net-pin-check.py --src config/boards/hinlink-h88k.csc
bash tools/tests/net-pin-check-test.sh          # 16 例负例自测
bash tools/tests/admin-ip-iface-test.sh         # 管理地址守护选口逻辑（无桥→eth2 / 有桥→br-lan1）

# 构建前：镜像布局探测自测（微型镜像：单分区 / 双分区 / 不像 rootfs / 随机字节）
sudo bash tools/tests/layout-probe-test.sh

# 构建后：镜像内落盘值
sudo bash tools/verify-image.sh output/images/*.img      # 完整自证
sudo bash tools/verify-image.sh --probe output/images/*.img   # 只探测布局
```

`verify-image.sh` **只断言本仓改过的地方**：静态口序、时钟、roceos 载荷、roceos-ai 语义、管理地址+LED 守护、命名反断言，
外加三类官方发布件口径（2026-10-30 对齐）：镜像名必须含 `_minimal`、
`packages.additional` 逐包核对（判据单点 `tools/packages-parity-check.py`，见上面「包集合口径」一节）、
`smartmontools` 包在但不启用、`serial-getty@ttyFIQ0` 必须已 mask（vendor 分支串口走 fiq-debugger）。
官方默认值（DTB/cma/内核符号等）一律不断言。

**布局**：本板 csc 没声明 `BOOTFS_TYPE`，构建产物是**单分区**（p1 = rootfs ext4，引导文件在 rootfs 的 `/boot`），与官方 H88K 镜像同构；只有声明了 `BOOTFS_TYPE` 的板才是 `bootfs + rootfs` 双分区。自证脚本**枚举分区 + blkid 判定**，两种布局都支持；挂上的分区不像 rootfs（缺 `/etc` `/usr`）就立刻判红并打印分区表。

> 历史：run #6 就是因为自证写死「p1=bootfs / p2=rootfs」，在单分区镜像上第一行就 `exit 1`（镜像其实已编好并上传，但一条断言都没跑）。

## 目录

```
config/boards/hinlink-h88k.csc     上游 csc 的加法版（静态口序）
extensions/lyw-hh-net.sh           管理地址守护 + 前面板 LED
extensions/lyw-hh-clock.sh         mask fake-hwclock-load（JWT 立刻过期的根因）
extensions/lyw-hh-roceos.sh        roceos 载荷注入 + AI 无模型语义
patch/kernel/rk35xx-vendor-6.1/dt/rk3588-hinlink-h88k.dts
                                   板级 DTS fork（唯一改动 = 千兆 PHY 节点 eee-broken-1000t）
tools/dts-lint.py                  板级 DTS 语法门（构建前秒级；CPP 移位运算符/prop-order 全覆盖）
tools/net-pin-check.py             网口口径唯一判据（--src / --conf，期望值只来自 csc）
tools/verify-image.sh              镜像自证（分区布局自适应，支持 --probe）
tools/tests/                       负例自测：网口口径 16 例 + 布局探测 4 例
docs/H88K-适配工作流与判据.md      全部证据链与实机数据
```
