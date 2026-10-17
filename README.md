# lyw-hh — Hinlink H88K（RK3588）iNextOS 仓库化构建

从上游框架 [jjm2473/armbian-easepi @ easepi-v26.02](https://github.com/jjm2473/armbian-easepi)
编译 H88K 的 iNextOS 镜像，并把**用户实机 192.168.10.90 上验证过的四处修正**固化成代码。

官方镜像（`iNextOSA_26.2.1_H88K_trixie_vendor_6.1.115.img`）刷上去有四个问题，本仓全部修掉：

| # | 现象 | 根因 | 本仓修法 |
|---|------|------|----------|
| 1 | 网口顺序反了（ETH0↔ETH2） | 厂商 `gen-eth-order.sh` 按「平台口优先 + PCIe 字典序」猜顺序，上游 csc 里没有任何口序代码 | 板级 csc 写死静态 `/etc/eth_order`：`eth0=0004:41(2.5G) eth1=0003:31(2.5G) eth2=fe1b0000(千兆)` |
| 2 | 进后台一下就退出 | `/etc/fake-hwclock.data` 是构建日期（2026-08-26），开机覆盖 RTC → roceos JWT 一签发就过期 | `mask` 掉 `fake-hwclock-load.service`，`.data` 写构建时刻 |
| 3 | 前面板系统灯不亮 | DTS 四个 LED 节点里只有 `work` 带 `linux,default-trigger`，`net/sata/user` 没有默认触发器 | `h88k-admin-ip.service` 守护设置 `blue:net=netdev(br-lan1)`、`green:user=heartbeat`、`amber:sata=disk-activity` |
| 4 | 后台每 5 秒崩一次（`NRestarts=206`） | 26.2.1 载荷里 `server.py` 缺模型时 `sys.exit(1)` + `Restart=on-failure` → 无限重启；官方 **Easepi-r2** 新版改为 `sys.exit(3)` + unit `RestartPreventExitStatus=3` | 用官方那两份文件覆盖载荷（sha256 钉死），与官方行为一致 |

另外保持官方口径：`192.168.100.1` 常驻千兆口（或其桥），`cma=256M`（与官方 Easepi-r2 镜像一致），EEE 不动（官方默认）。

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
  BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  COMPRESS_OUTPUTIMAGE="sha,img,xz" SHARE_LOG=yes EXPERT=yes
```

参考基线：运行系统内核 `6.1.115-vendor-rk35xx`（`R8125=m / STMMAC_ETH=y / DWMAC_ROCKCHIP=y`）——
这些是厂商树默认值，本仓**不改也不断言**。

## 判据（构建前 + 构建后同一份代码）

```bash
# 构建前：仓库默认值
python3 tools/net-pin-check.py --src config/boards/hinlink-h88k.csc
bash tools/tests/net-pin-check-test.sh          # 14 例负例自测

# 构建后：镜像内落盘值
sudo bash tools/verify-image.sh output/images/*.img
```

`verify-image.sh` **只断言本仓改过的地方**：静态口序、时钟、roceos 载荷、roceos-ai 语义、管理地址+LED 守护、命名反断言。官方默认值（DTB/cma/内核符号等）一律不断言。

## 目录

```
config/boards/hinlink-h88k.csc     上游 csc 的加法版（静态口序）
extensions/lyw-hh-net.sh           管理地址守护 + 前面板 LED + cma 官方口径断言
extensions/lyw-hh-clock.sh         mask fake-hwclock-load（JWT 立刻过期的根因）
extensions/lyw-hh-roceos.sh        roceos 载荷注入 + AI 模型门禁
tools/net-pin-check.py             网口口径唯一判据（--src / --conf）
tools/verify-image.sh              镜像自证
docs/H88K-适配工作流与判据.md      全部证据链与实机数据
```
