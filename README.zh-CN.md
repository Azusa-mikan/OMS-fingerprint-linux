# OMS 指纹模块 Linux 一键安装指南（33a7:2388）

> 适用设备：**江西欧迈斯 / 欧菲光指纹模块，USB ID `33a7:2388`**（`ofilm` 系列，
> 常见于机械革命无界 14/15 Pro 等机型）。芯片内匹配（Match-on-Chip），
> 芯片自己存模板、自己比对，主机不需要指纹算法。
>
> 目标：让这颗指纹**用于登录、锁屏解锁和 sudo**。

> ### ⚠️ 测试范围（请务必先读）
>
> **本项目的驱动与应用层，仅在一台机器上实测过：**
>
> | 项目 | 状态 |
> |---|---|
> | 发行版：**Arch Linux** | ✅ 实测 |
> | 桌面/显示管理器：**GNOME 51 + GDM 51** | ✅ 实测 |
> | **sudo 指纹** | ✅ 实测 |
> | 锁屏解锁（GNOME） | ✅ 实测 |
> | fprintd 录入 / 验证 | ✅ 实测 |
> | **GDM ≤ 50** | ❌ **未测试**（按上游行为推断） |
> | **GDM 52+** | ❌ **未测试** |
> | **SDDM / LightDM** | ❌ **未测试**（脚本逻辑经静态验证，但无真机） |
> | **其它发行版**（Debian/Fedora/…） | ❌ **未测试**（脚本面向 Arch/pacman） |
> | **其它桌面**（KDE Plasma 等） | ❌ **未测试** |
> | 其它型号 / 固件版本 | ❌ 未测试（仅 `bcdDevice 0x0200`） |
>
> 未测试项**不代表不能用**，但也**没有保证**。若你在别的环境跑通（或踩坑），
> 欢迎提 issue 反馈，让本指南更完整。

---

## 0. 一眼总览

```
git clone https://github.com/Azusa-mikan/OMS-fingerprint-linux.git
cd oms-fingerprint-linux
sudo ./install.sh          # 一键：装驱动 + fprintd + udev + PAM + 工具
fprintd-enroll             # 录入一根手指（按提示按 6 次）
# 重新登录，即可用指纹
```

出问题怎么办？切到文字终端（`Ctrl+Alt+F3`）用密码登录后：

```
sudo oms-pam-restore       # 恢复 GDM 登录为纯密码（立即生效）
```

---

## 1. 安装前须知

- **发行版**：本指南面向 Arch / Manjaro / EndeavourOS 等使用 `pacman` 的系统。
  其他发行版可参考文末「手动编译」。
- **需要联网**：安装时会下载 libfprint 源码并编译。
- **不要用 root 直接跑**：用普通用户 `sudo ./install.sh`。
  构建那一步（`makepkg`）必须以普通用户身份运行，脚本会自动处理。
- **`/dev/bus/usb` 权限**：脚本装的 udev 规则会放开该设备访问，无需手动 chmod。

---

## 2. 一键安装

```bash
git clone https://github.com/Azusa-mikan/OMS-fingerprint-linux.git
cd oms-fingerprint-linux
sudo ./install.sh
```

脚本会依序完成：

| 步骤 | 内容 |
|---|---|
| 1 | 安装构建依赖（meson / ninja / gobject-introspection / glib2-devel） |
| 2 | 构建并安装 **libfprint-omsmoc**（= libfprint + omsmoc 驱动） |
| 3 | 安装 **fprintd** |
| 4 | 编译并安装辅助工具 `oms-smoke` / `oms-claim` / `oms-ident` |
| 5 | 写 udev 规则（放行访问 + **常供电**，该设备扛不住 autosuspend） |
| 6 | 配 PAM：**登录**（自动识别 GDM/SDDM/LightDM）、**锁屏解锁**、**sudo** |
| 7 | 安装恢复脚本 `oms-pam-restore` |

可选参数：

```bash
sudo ./install.sh --no-pam      # 只装驱动+fprintd，不动 PAM
sudo ./install.sh --no-login    # 跳过显示管理器登录规则（保留 sudo 指纹）
sudo ./install.sh --no-sudo     # 跳过 sudo 指纹
sudo ./install.sh --dm=sddm     # 强制指定显示管理器（gdm|sddm|lightdm|none）
sudo ./install.sh --force-gdm   # 即便 GDM ≤50 也强制加登录覆盖
sudo ./install.sh --build-only  # 只编译出包，不安装
sudo ./install.sh --no-deps     # 假设依赖已就绪
```

脚本可重复运行（幂等）。

### 2.1 显示管理器兼容性（脚本自动处理）

| 显示管理器 | 脚本行为 | 实测 |
|---|---|---|
| **GDM ≥ 51** | 指纹登录被上游移除 → 脚本派生 `/etc/pam.d/gdm-password` 覆盖，登录时可先用指纹 | ✅ 已实测 |
| **GDM ≤ 50** | 指纹登录**原生支持** → 脚本**不动**登录 PAM，保持原样 | ⚠️ 未测试 |
| **SDDM** | 往 `/etc/pam.d/sddm` 插入指纹规则 | ⚠️ 未测试 |
| **LightDM** | 往 `/etc/pam.d/lightdm` 插入指纹规则 | ⚠️ 未测试 |
| **其他/未知** | 给出提示，需手动按其 PAM 服务配置 | — |

> 若脚本识别不到你的显示管理器（少见），可用 `--dm=gdm|sddm|lightdm` 手动指定。

**锁屏解锁**：GNOME 走同一服务的重新认证（脚本已覆盖）；KDE Plasma 6 的
`kscreenlocker` 自带 `/etc/pam.d/kde-fingerprint`，开箱即用。

---

## 3. 录入指纹

```bash
fprintd-enroll                        # 默认右手食指；按提示「按下→抬起」共 6 次
fprintd-enroll -f right-index-finger  # 指定手指（食指）
fprintd-list                          # 查看已录入
fprintd-verify                        # 验证（按一次已录入的手指）
fprintd-delete                        # 删除
```

手指名可用：`right/left-{thumb,index,middle,ring,little}-finger`。

> **重要**：芯片会拒绝重复录入（报 `enroll-duplicate`）。若某根手指在 Windows
> 下已经录过，芯片里已有它的模板，就不能再录一遍——请用第 4 节「复用旧模板」。

---

## 4. 复用芯片里已有的模板（Windows 遗留）

芯片里存着 Windows 时期录的模板，但 **fprintd 不认领**它们（fprintd 的用户↔指纹
映射存在它自己的数据库里，不在芯片里）。芯片又拒绝重复录入，所以要用工具把这些
**已有模板**登记给 fprintd：

```bash
oms-smoke list                       # 1. 看看芯片里有哪些槽位（Slot 0/1/2 ...）
sudo oms-claim <用户名> 0:right-index-finger 2:right-middle-finger
                                     # 2. 把槽位登记成你要的手指标签
fprintd-list                         # 3. 确认 fprintd 已认领
```

> 槽位号与手指的对应关系，可以用全库识别来实测：
> ```bash
> sudo systemctl stop fprintd          # 释放设备（libfprint 独占）
> oms-ident 25                         # 按一次手指，直接报命中的 Slot
> ```
> **注意**：标签（哪根手指）只影响显示，不影响使用——登录/解锁/sudo 用的是
> 「任意已注册手指」模式，会遍历全部指纹。

---

## 5. 各场景怎么用

| 场景 | 操作 |
|---|---|
| **GDM 登录** | 选账号后，直接按手指；或照常输密码 |
| **锁屏解锁** | 按手指；或输密码 |
| **sudo** | 终端里 `sudo <命令>`，会先提示按手指；不按则回落到密码 |
| **polkit 提权弹窗** | GNOME 环境下同样走 fprintd（部分应用需额外配置） |

---

## 6. 关于登录界面（各显示管理器）

| 显示管理器 | 指纹登录 | 实测 | 说明 |
|---|---|---|---|
| **GDM ≥ 51** | 需本项目的 PAM 覆盖 | ✅ 已实测 | GDM 51.0 起指纹只用于「重新认证」（解锁等），不能再单独登录 |
| **GDM ≤ 50** | **原生支持** | ⚠️ 未测试 | 登录界面自带「指纹」选项，无需任何改动 |
| **SDDM** | 本项目插入 `/etc/pam.d/sddm` | ⚠️ 未测试 | KDE 常用；注意 KWallet 仍需密码解锁 |
| **LightDM** | 本项目插入 `/etc/pam.d/lightdm` | ⚠️ 未测试 | — |

`install.sh` 会**自动识别**你的显示管理器并做对应处理；GDM ≤50 时**不做任何覆盖**。

### GDM 51 的覆盖是怎么做的

在 `/etc/pam.d/gdm-password` 顶部放 `auth sufficient pam_fprintd.so`，于是 GDM 走密码
流程时会**先让你按指纹**，按了就走，没按就回落到密码。

代价（GDM 官方砍它的原因）：**用指纹登录时 gnome-keyring 拿不到密码**，
之后可能弹窗要你输一次钥匙串密码。在意的话安装时加 `--no-login`，
只用锁屏/sudo 的指纹。

### GNOME 51 上游原文（供参考）

> in GNOME 51, we've changed the behavior of the fingerprint sensor to only
> function during re-authentication. The user can no longer log into their
> system with a fingerprint sensor alone.

---

## 7. 排错

### 7.1 登录界面卡住 / 指纹不管用

切到文字终端（**`Ctrl+Alt+F3`**），用**密码**登录，然后：

```bash
sudo oms-pam-restore        # 移除 GDM 指纹覆盖，登录立即恢复纯密码
```

（等价于 `sudo rm /etc/pam.d/gdm-password`。）想连 sudo 也还原：
`sudo oms-pam-restore --all`。

### 7.2 设备卡死（bulk 传输超时，但 lsusb 还在）

这个设备**绝不能收到不完整的 USBC 序列**（比如只发头、或裸发 EF01 帧），
否则固件会卡住。此外它也**扛不住内核 autosuspend**（脚本已用 udev 规则常供电）。

卡住后，复位 USB 端口即可：

```bash
# 方式一：pyusb
python3 -c "import usb.core; usb.core.find(idVendor=0x33a7,idProduct=0x2388).reset()"
# 方式二：授权位脉冲（需 root，把 1-4 换成你的设备路径）
echo 0 | sudo tee /sys/bus/usb/devices/1-4/authorized
sleep 2
echo 1 | sudo tee /sys/bus/usb/devices/1-4/authorized
```

> 若 `lsusb` 里设备变成了 `1234:abce`（引导模式），说明进了 BootROM，
> 需要用厂商烧录工具恢复固件（会 ChipErase，**芯片内模板全丢**）。

### 7.3 fprintd 显示 inactive

正常现象。fprintd 是 D-Bus 按需激活的服务，闲置 30 秒会自动退出，下次调用再拉起。

### 7.4 升级系统后指纹失效

系统的 `libfprint` 一升级就会和 `libfprint-omsmoc` 冲突。重装本包即可：

```bash
cd ~/Projects/oms-fingerprint-linux/aur/libfprint-omsmoc
makepkg -fC --noconfirm
yes | sudo pacman -U libfprint-omsmoc-*.pkg.tar.zst
```

或在 `/etc/pacman.conf` 里用 `IgnorePkg` 钉住 `libfprint`，避免被动升级。

---

## 8. 卸载

```bash
sudo ./uninstall.sh            # 还原 PAM/udev/工具，并移除驱动包
sudo ./uninstall.sh --purge    # 同时删除 fprintd 的指纹记录
sudo pacman -S libfprint       # 还原发行版 libfprint
```

---

## 9. 手动安装（AUR 包路线）

不用一键脚本时，也可手动构建 AUR 包：

```bash
cd aur/libfprint-omsmoc
makepkg -fC                    # 再次构建必须加 -C，否则 prepare() 因补丁已应用而失败
yes | sudo pacman -U libfprint-omsmoc-*.pkg.tar.zst
sudo pacman -S fprintd
sudo systemctl restart fprintd # 或等 D-Bus 激活
```

包装细节（踩过的坑）：

- `provides` 必须含 soname `libfprint-2.so=2-64`，否则 fprintd 依赖不满足。
- `conflicts=('libfprint>=1.90')` 只与 2.x 冲突，保留遗留 `libfprint-1`（`fingerprint-gui` 依赖它）。

---

## 10. 手动编译驱动（其他发行版 / 开发）

```bash
cd driver
./setup.sh              # 下载 libfprint 1.94.100 + 打补丁 + 构建
./setup.sh --test       # 构建后跑 umockdev 回放测试（无需硬件）

B=build/libfprint-build
LD_LIBRARY_PATH=$B/libfprint $B/examples/oms-smoke info
LD_LIBRARY_PATH=$B/libfprint $B/examples/oms-smoke list
LD_LIBRARY_PATH=$B/libfprint $B/examples/oms-smoke verify 30 --slot 0
```

依赖（Arch 名）：`base-devel meson ninja glib2 glib2-devel gusb libusb cairo
pixman nss gobject-introspection umockdev`。

> 提示：缺 `g-ir-scanner` 时（未装 `gobject-introspection`），libfprint 的
> `tests/meson.build` 在缺 introspection 的分支里有个单变量 `foreach` 会报错，
> 装上 `gobject-introspection` 或把那一行改成 `foreach x, _: ...` 即可。

---

## 11. 协议速查（逆向结论）

给想深入的人：

```
传输层：  8 字节 USBC 请求头 + 4 字节 USBS 应答
  写 64:  55 53 42 43 00 40 00 00   +  64 字节数据
  读 64:  55 53 42 43 80 40 00 00   （先发命令，再发这个读请求）
  轮询:   55 53 42 43 80 20 00 00
  应答:   55 53 42 53
帧层：    64 字节 EF01 帧
  EF 01 FF FF FF FF <dir> 00 <len> <payload...> <chk>
  dir: 0x01=主机→设备, 0x07=设备→主机
  校验和 = dir + len + Σpayload（低 8 位）
常用命令：0x34 芯片SN · 0x1d 模板数 · 0x1f 索引位图 · 0x32 识别/录入 ·
          0x31 生成模板 · 0x0c 删除/清空 · 0x30 取消
0x32 应答：00 05 00 SS 03 e8 = 匹配成功（SS=命中槽位）· 09 05 ... = 未匹配
```

全明文，无握手、无密钥、无加密。

---

## 12. 许可与合规

- 本仓库代码：**LGPL-2.1-or-later**（与 libfprint 一致，便于上游合并）。
- 这是对**自己拥有的硬件**做的互操作性逆向；仓库**不含**厂商二进制 / 固件 / 原始抓包。
- 测试回放数据里的芯片序列号、USB 序列号等已脱敏。
- 芯片内的模板是**不可再生状态**：删除 / 清空前请确认目标槽位。

---

## 13. 参考

- 驱动本体：`driver/omsmoc.c`（文件头有协议与实现说明）
- 构建与测试：`driver/README.md`
- AUR 打包：`aur/README.md`
- 上游 MR 材料：`driver/upstream/`
- 英文说明：`README.md`
