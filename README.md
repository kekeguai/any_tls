# AnyTLS Linux 服务端管理脚本

> 在 Linux 服务器上安装和管理 [AnyTLS-Go](https://github.com/anytls/anytls-go) 服务端。适合需要自建 AnyTLS 节点的个人用户；安装后可用交互菜单管理服务、查看连接信息和生成二维码。

## 快速安装

支持 Debian、Ubuntu、CentOS、RHEL、Rocky Linux、AlmaLinux、Fedora、Arch Linux 和 Alpine Linux；需要 `systemd` 或 `OpenRC`、`amd64` 或 `arm64` 架构，并以 root 权限运行。

```bash
curl -fsSL -o anytls_manager.sh https://raw.githubusercontent.com/kekeguai/any_tls/refs/heads/main/anytls_manager.sh
sudo bash anytls_manager.sh install
```

首次安装过程中会依次询问：

1. **监听端口**：默认 `8443`；输入 `1–65535` 的未占用端口。
2. **连接密码**：直接回车会自动生成 UUID 格式密码；手动设置时允许字母、数字和连字符 `-`，长度为 6–64 位。
3. **节点名称**：默认 `AnyTLS`；允许字母、数字、下划线和连字符，长度为 1–32 位。

安装脚本会下载 AnyTLS-Go 发布程序、注册并启动服务，并尝试配置服务器本机防火墙。安装完成后即可运行 `sudo anytls` 打开管理菜单。

## 交互菜单

运行 `sudo anytls` 或 `sudo anytls menu` 打开菜单。菜单复用脚本的管理命令；需要管理员权限的操作会执行相应权限检查。

| 选项 | 操作 |
| --- | --- |
| `1` | 安装 AnyTLS；首次安装时配置端口、密码和节点名称，已安装时更新程序并保留现有配置 |
| `2` | 重启服务 |
| `3` | 启动服务 |
| `4` | 停止服务 |
| `5` | 查看服务状态、版本、端口和节点名称 |
| `6` | 查看最近 200 行日志 |
| `7` | 更新程序并保留现有配置 |
| `8` | 查看连接信息并生成二维码（需要 root 权限） |
| `9` | 重新生成连接密码并重启服务 |
| `10` | 卸载服务、程序和配置（需要确认） |
| `11` | 显示命令帮助 |
| `0` | 退出菜单 |

注意：已安装后选择菜单 `1` 是更新程序，不会重新询问或修改端口。当前没有单独的端口修改菜单项。

## 命令行用法

也可以直接运行子命令，不必进入菜单：

| 命令 | 说明 |
| --- | --- |
| `sudo anytls install` | 首次安装；若已安装则更新程序并保留现有配置 |
| `sudo anytls update` | 更新程序并保留现有配置 |
| `sudo anytls start` | 启动服务 |
| `sudo anytls stop` | 停止服务 |
| `sudo anytls restart` | 重启服务 |
| `anytls status` | 查看服务状态和配置摘要 |
| `sudo anytls log` | 查看日志；可附加 `-n 200` 等参数 |
| `sudo anytls qr` | 直接显示连接链接并生成二维码，不需要再次输入连接密码 |
| `sudo anytls passwd` | 重新生成连接密码并重启服务 |
| `sudo anytls passwd '<新密码>'` | 设置指定连接密码；长度 6–64 位，仅允许字母、数字和 `-` |
| `sudo anytls uninstall` | 确认后卸载 |
| `anytls help` | 查看帮助 |

## 连接信息与二维码

菜单选项 `8` 或执行 `sudo anytls qr` 会显示现有连接链接，并在终端输出二维码；同时尝试将二维码图片保存到：

```text
/etc/anytls/anytls-qr.png
```

二维码和连接链接中都包含客户端连接密码。虽然 `qr` 不再要求输入该密码，但仍要求 root 权限；请勿将终端输出、二维码图片或密码分享给未授权人员。也可以通过 `sudo anytls passwd` 生成新密码，脚本会更新服务配置并重启服务。

服务端使用自签名证书，客户端需开启“允许不安全连接”或“跳过证书验证”。脚本生成的连接 URI 会包含 `insecure=1` 参数。

二维码在服务器本地生成：Alpine 使用 Python 3 标准库内置生成器；其他发行版使用 `qrencode`，缺少时脚本会尝试安装。为获取连接 URI 中的服务器公网 IP，脚本会依次尝试访问 `ifconfig.me` 和 `ip.sb`；二维码内容本身不会上传到二维码生成服务。

## 服务与配置

- 支持 `systemd` 和 `OpenRC`，根据系统环境生成对应服务定义。
- AnyTLS-Go 服务端程序：`/usr/local/bin/anytls-server`
- 管理命令：`/usr/local/bin/anytls` 和 `/usr/local/sbin/anytls`
- 配置文件：`/etc/anytls/config.env`，权限为 `600`；配置目录权限为 `700`。
- systemd 服务文件：`/etc/systemd/system/anytls.service`
- OpenRC 服务脚本：`/etc/init.d/anytls`
- 二维码图片：`/etc/anytls/anytls-qr.png`，生成后权限为 `600`。

## 防火墙与网络

脚本会检测并尝试配置 UFW、firewalld 或 iptables；检测到活动 nftables 时会提示手动处理，不会改写现有 nftables 规则。云厂商安全组不受脚本管理，需要在服务商控制台单独放行所选 **TCP 端口**。

## 常见问题

### 安装后找不到 `anytls` 命令

确认 `/usr/local/bin` 在当前 shell 的 `PATH` 中，或执行 `/usr/local/bin/anytls`。

### 服务启动失败

运行 `sudo anytls log -n 200` 查看日志，并确认监听端口未被占用、云安全组和系统防火墙已放行 TCP 端口。

### 客户端无法连接

检查 `anytls status` 显示服务正在运行，核对服务器地址、端口和连接密码，并确认客户端允许跳过证书验证。

### 修改监听端口

目前没有独立的端口修改命令。修改 `/etc/anytls/config.env` 中的 `PORT` 后，重启服务：

```bash
sudo anytls restart
```

### 卸载

执行 `sudo anytls uninstall`，并在提示时确认。卸载会删除服务定义、管理命令、服务端程序、配置和二维码文件。
