# AnyTLS-Go 一键安装与管理脚本

基于 [anytls/anytls-go](https://github.com/anytls/anytls-go) 的 Linux 服务端一键安装与管理脚本。支持一键安装、更新、启停、查看状态与日志、生成连接二维码和卸载，安装后可直接使用 `anytls` 命令管理。

脚本地址：<https://raw.githubusercontent.com/kekeguai/any_tls/refs/heads/main/anytls_manager.sh>

## 特性

- **一键安装**：自动下载 anytls-go 官方发布的预编译程序，无需编译环境
- **依赖自动处理**：自动安装 `wget`、`unzip`、`curl`、`qrencode` 等工具
- **交互式配置**：安装时输入监听端口和连接密码，密码留空则随机生成
- **服务管理**：自动检测 systemd 或 OpenRC，支持开机自启、异常自动拉起、启动、停止、重启与查看状态
- **日志查看**：systemd 使用 `journalctl`；OpenRC 使用 `/var/log/anytls.log`
- **二维码输出**：生成连接链接并以终端二维码展示，方便移动端导入
- **保留配置更新**：已安装时再次执行 `install` 或 `update` 仅更新程序，保留原端口与密码
- **防火墙联动**：自动检测 UFW、firewalld、iptables 与 nftables 能力，并在无法自动处理时给出提示
- **架构识别**：支持 `amd64` 与 `arm64`

## 系统要求

- Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora / Arch Linux / Alpine Linux
- root 权限（或 sudo）
- systemd 或 OpenRC
- 架构：`x86_64`（amd64）或 `aarch64`（arm64）
- 可访问 GitHub 与 raw.githubusercontent.com

## 安装

### 方式一：一行命令下载并安装（推荐）

```bash
curl -fsSL -o anytls_manager.sh https://raw.githubusercontent.com/kekeguai/any_tls/refs/heads/main/anytls_manager.sh && sudo bash anytls_manager.sh install
```

### 方式二：使用 wget 下载

```bash
wget -O anytls_manager.sh https://raw.githubusercontent.com/kekeguai/any_tls/refs/heads/main/anytls_manager.sh
sudo bash anytls_manager.sh install
```

### 方式三：手动粘贴保存

```bash
nano anytls_manager.sh      # 粘贴脚本内容后 Ctrl+O 保存，Ctrl+X 退出
sudo bash anytls_manager.sh install
```

### 安装过程

1. 识别发行版和包管理器，并安装依赖（wget、unzip、curl、tar、qrencode）
2. 下载 anytls-go 程序并安装到 `/usr/local/bin/anytls-server`
3. 提示输入监听端口（默认 `8443`，需为未被占用的 1–65535 端口）
4. 提示输入连接密码（回车则随机生成，仅限字母和数字，6–64 位）
5. 按当前 init 系统注册 systemd 或 OpenRC 服务并启动，尝试放行防火墙端口
6. 输出服务器信息与连接链接

安装完成后，脚本会被复制到 `/usr/local/sbin/anytls`，之后可直接使用 `anytls` 命令。

## 命令一览

| 命令 | 说明 |
| --- | --- |
| `anytls install` | 安装；若已安装则仅更新程序并保留原配置 |
| `anytls update` | 更新到脚本内指定的版本，保留原配置 |
| `anytls start` | 启动服务 |
| `anytls stop` | 停止服务 |
| `anytls restart` | 重启服务 |
| `anytls status` | 查看服务状态、程序版本与监听端口 |
| `anytls log [参数]` | 查看服务日志，systemd 默认显示最近 100 行，OpenRC 默认跟踪最多 200 行 |
| `anytls qr` | 输入密码确认后，输出连接链接与终端二维码 |
| `anytls uninstall` | 卸载程序、服务与配置（需确认） |
| `anytls help` | 显示帮助信息 |

## 使用示例

```bash
sudo anytls status            # 查看服务状态
sudo anytls restart           # 重启服务
sudo anytls stop              # 停止服务
sudo anytls start             # 启动服务
sudo anytls log               # 查看最近 100 行日志
sudo anytls log -n 200        # 查看最近 200 行日志
sudo anytls qr                # 输出连接链接与二维码
sudo anytls update            # 更新程序版本
sudo anytls uninstall         # 卸载
```

## 连接信息

安装完成或执行 `anytls qr` 后会输出连接信息，格式如下：

```
服务器 IP : 1.2.3.4
端口      : 8443
密码      : Abc12345xyz
连接链接  : anytls://Abc12345xyz@1.2.3.4:8443/?insecure=1
```

**客户端注意**：服务端使用自签名证书，客户端需开启“允许不安全连接”或“跳过证书验证”。

## 支持的客户端

以下客户端已知支持 AnyTLS 协议，可与 anytls-go 服务端配合使用：

- **Shadowrocket**（iOS）：版本 `2.2.65` 及以上，可扫描本脚本生成的二维码
- **NekoBox For Android**（Android）：版本 `1.3.8` 及以上，可扫描本脚本生成的二维码
- **sing-box**（多平台）：基于 sing-box 内核的客户端通常支持 AnyTLS，可手动配置
- **mihomo / Clash Meta**（多平台）：基于 mihomo 内核的客户端通常支持 AnyTLS，可手动配置

## 目录与文件

| 路径 | 说明 |
| --- | --- |
| `/usr/local/sbin/anytls` | 管理脚本本体 |
| `/usr/local/bin/anytls-server` | anytls-go 服务端程序 |
| `/etc/anytls/config.env` | 配置文件（端口、密码、版本），权限 600 |
| `/etc/systemd/system/anytls.service` | systemd 服务文件 |
| `/etc/init.d/anytls` | OpenRC 服务文件（Alpine 等 OpenRC 系统） |
| `/usr/local/libexec/anytls-runner` | OpenRC 启动器，从受限配置文件读取服务参数 |

## 注意事项

1. **云服务器安全组**：阿里云、腾讯云、AWS 等需在控制台安全组中手动放行所选端口（TCP），脚本只能处理系统本机防火墙。
2. **密码安全**：密码保存在 `/etc/anytls/config.env` 中，目录权限为 700、配置文件权限为 600。systemd 通过 `EnvironmentFile` 读取配置，OpenRC 通过受限启动器读取配置，不会把密码写入服务定义文件。
3. **密码限制**：为避免参数解析问题，密码仅允许字母和数字，长度 6–64 位。
4. **版本更新**：`anytls update` 会按脚本内 `VERSION` 变量下载对应版本。如需升级，可修改脚本中的版本号后执行更新，或通过环境变量 `ANYTLS_VERSION` 指定版本。
5. **下载文件名**：脚本按 `anytls_<版本>_linux_<架构>.zip` 的规则下载。若上游发布文件名有变化，需同步修改 `download_server` 函数。
6. **服务参数**：服务端以 `-l 0.0.0.0:<端口> -p <密码>` 方式启动。若上游程序参数有变化，需修改 `write_unit` 函数生成的服务定义或 OpenRC 启动器。
7. **首次使用建议**：请先在测试机上完整执行一次安装，确认服务能正常启动与连接。

## 常见问题

**服务启动失败？**
执行 `sudo anytls log -n 200` 查看日志。常见原因包括端口被占用、程序参数与上游版本不一致、架构不匹配。

**客户端无法连接？**
依次检查：`anytls status` 中服务是否为「运行中」；云安全组是否放行端口（TCP）；系统防火墙（`ufw status`、`firewall-cmd --list-ports` 或 Alpine 的 iptables 规则）是否放行；客户端是否开启了“允许不安全连接”。

**忘记密码？**
执行 `sudo cat /etc/anytls/config.env` 查看当前配置，或执行 `anytls qr` 查看连接信息（需先输入密码）。

**如何修改端口或密码？**
目前脚本未提供单独的端口修改命令。可编辑 `/etc/anytls/config.env` 中的 `PORT` 后，执行 `sudo anytls restart`。

**如何彻底删除？**
执行 `sudo anytls uninstall`，确认后会删除服务、程序、配置及管理脚本本体。

## 免责声明

本项目仅供学习和技术研究使用，请勿用于任何非法用途。使用者应自行承担风险，并遵守所在地区的法律法规。因使用本脚本产生的任何问题或纠纷，脚本作者概不负责。

## 致谢

- [anytls/anytls-go](https://github.com/anytls/anytls-go)：AnyTLS-Go 服务端程序
