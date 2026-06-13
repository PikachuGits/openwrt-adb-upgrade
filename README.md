# OpenWrt ADB Upgrade Tool

将 OpenWrt 上的 ADB 从旧版本 (1.0.32) 升级到最新版 (35.0.1)，解决手机 USB 重连反复要求授权的问题。

## 问题描述

OpenWrt 官方仓库中的 ADB 版本为 1.0.32（基于 Android 5.0.2），版本过旧导致：

- 手机 USB 断开重连后反复要求重新授权
- 即使勾选"记住此计算机"也不生效
- 与其他电脑连接正常，仅 OpenWrt 出现此问题

## 环境要求

| 项目 | 要求 |
|------|------|
| OpenWrt 版本 | 24.10+ (musl libc) |
| 架构 | x86_64 |
| SSH | 需要 root SSH 访问路由器 |
| Docker | 仅在 `--rebuild` 时需要（可选） |

## 快速安装（推荐）

无需 Docker，直接使用预编译包：

```bash
# 1. 下载项目
git clone https://github.com/your-username/openwrt-adb-upgrade.git
cd openwrt-adb-upgrade

# 2. 一键安装
./install.sh --host 192.168.6.1 --user root
```

## 预编译包说明

项目中包含预编译的 ADB 包，无需 Docker 或编译环境：

```
prebuilt/
├── bin/
│   ├── adb           # ADB 35.0.1 二进制 (2.2MB)
│   └── fastboot      # Fastboot 二进制 (1.4MB)
└── lib/              # 55 个 musl 共享库
    ├── libprotobuf.so.24
    ├── libstdc++.so.6
    ├── libusb-1.0.so.0
    ├── libzstd.so.1
    └── ... (共 55 个库文件)
```

**预编译包来源**: Alpine Linux 3.20 community 仓库 (android-tools 35.0.1-r3)

**兼容性**: Alpine 和 OpenWrt 均使用 musl libc，二进制完全兼容。

## 安装参数

```bash
./install.sh [OPTIONS]

Options:
  --host HOST       OpenWrt 路由器 IP (默认: 192.168.6.1)
  --user USER       SSH 用户名 (默认: root)
  --port PORT       SSH 端口 (默认: 22)
  --rebuild         强制使用 Docker 重新构建（忽略预编译文件）
  --dry-run         仅显示操作，不实际执行
  -h, --help        显示帮助
```

### 使用示例

```bash
# 使用默认配置安装
./install.sh

# 指定路由器 IP
./install.sh --host 192.168.1.1

# 指定 SSH 端口
./install.sh --host 10.0.0.1 --port 2222

# 预览操作（不实际执行）
./install.sh --dry-run

# 强制从 Docker 重新构建
./install.sh --rebuild
```

## 安装后操作

1. **手机端**:
   - 设置 → 开发者选项 → 撤销 USB 调试授权
   - 重新 USB 连接
   - 点击"允许" + 勾选"始终允许此计算机"

2. **验证**:
   ```bash
   ssh root@192.168.6.1 "adb version"
   # 应显示: Android Debug Bridge version 1.0.41
   #         Version 35.0.1-android-tools
   ```

## 卸载/回滚

```bash
# 交互式卸载
./uninstall.sh 192.168.6.1 root 22

# 或手动回滚
ssh root@192.168.6.1 "
  cp /usr/bin/adb.old /usr/bin/adb
  rm -rf /usr/local/lib/adb-bin
  killall adb && adb start-server
"
```

## 文件说明

```
openwrt-adb-upgrade/
├── README.md              # 本文档
├── install.sh             # 一键安装脚本
├── uninstall.sh           # 卸载/回滚脚本
├── adb-bundle.tar.gz      # 打包的 ADB 文件 (5.3MB)
├── prebuilt/              # 预编译文件（可直接使用）
│   ├── bin/
│   │   ├── adb
│   │   └── fastboot
│   └── lib/
│       └── ... (55 个 .so 文件)
└── .gitignore
```

## 从源码构建

如需自行构建最新版本：

```bash
# 需要 Docker
./install.sh --rebuild

# 构建产物保存在:
#   output/           # 解压后的文件
#   adb-bundle.tar.gz # 打包文件
```

## 技术细节

### 为什么不用 Google 官方 platform-tools？

Google 官方 platform-tools 中的 adb 是 **glibc** 链接的，而 OpenWrt 使用 **musl libc**，两者二进制不兼容。

### 为什么选择 Alpine 预编译包？

Alpine Linux 和 OpenWrt 均使用 musl libc，且 Alpine 仓库提供了预编译的 android-tools 包，包含所有依赖库，无需编译。

### Wrapper 脚本原理

安装后 `/usr/bin/adb` 是一个 wrapper 脚本，它：
1. 设置 `LD_LIBRARY_PATH` 指向自定义库目录
2. 执行实际的 adb 二进制

这样 adb 可以找到所有依赖库，而不影响系统其他程序。

## License

MIT
