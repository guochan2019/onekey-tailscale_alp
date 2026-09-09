# onekey-tailscale_alp

一键在 **Alpine Linux LXC** 上安装/升级/卸载 [Tailscale](https://tailscale.com) 并配置 IP 转发，支持 LXC 容器环境。脚本为菜单模式（安装 / 升级 / 卸载）。

> 功能与 [onekey-tailscale](https://github.com/guochan2019/onekey-tailscale)（Debian 直装版）完全一致。安装方式为 **官方静态二进制**（不走 Alpine community 包——发行版仓库版本滞后约 4 个小版，如 3.24 stable = 1.98.5 vs 官方 1.102.x）。

---

## 快速开始

> ⚠️ 需要 root 权限。适用 Alpine Linux（OpenRC）。官方静态二进制无需任何运行时依赖。

```bash
# 方式一：一键直达（推荐）
sh <(wget -qO- https://raw.githubusercontent.com/guochan2019/onekey-tailscale_alp/main/onekey-tailscale_alp.sh)

# 方式二：GitHub 镜像加速（网关 50.1 等直连受限环境）
sh <(wget -qO- https://gh-proxy.com/https://raw.githubusercontent.com/guochan2019/onekey-tailscale_alp/main/onekey-tailscale_alp.sh)

# 方式三：gh CLI
gh repo clone guochan2019/onekey-tailscale_alp && cd onekey-tailscale_alp
chmod +x onekey-tailscale_alp.sh && ./onekey-tailscale_alp.sh
```

---

## 部署前置（Alpine LXC）

在 PVE 宿主机创建 Alpine LXC（3.20+）。**TUN 设备**（Tailscale 必需）：编辑 `/etc/pve/lxc/<CT_ID>.conf` 添加：

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

添加后重启容器。脚本运行时会自动检查 TUN 设备状态，缺失则打印配置指引。

> ⚠️ **Alpine 容器重启后转发失效（2026-09-09 实机坑）**：容器模板默认**未启用 sysctl 服务**（`/etc/init.d/sysctl` 不在运行级），`/etc/sysctl.conf` 开机不自动应用 → 重启后 ip_forward 回 0，subnet router 转发断（tailscaled 自身仍正常）。本脚本 3/4 已自动 `rc-update add sysctl boot` 修复；老部署手动补：`rc-update add sysctl boot && sysctl -w net.ipv4.ip_forward=1 && sysctl -w net.ipv6.conf.all.forwarding=1`

---

## 使用方式

运行脚本后显示菜单：

```
========================================
  Tailscale 一键安装/升级/卸载脚本 (Alpine)
========================================

[INFO] 检测到 Tailscale 1.102.3 已安装

请选择操作：
  1. 安装 / 升级 Tailscale
  2. 卸载 Tailscale
  0. 退出
```

| 选项 | 功能 |
|------|------|
| **1** | 未安装 → 4 步完整安装；已安装 → 自动检测官方最新版并升级 |
| **2** | 卸载：停止服务、删除二进制/状态/转发配置 |
| **0** | 退出 |

## 安装流程

| 步骤 | 说明 |
|------|------|
| 检测 | 确认 root / 发行版 / 架构（amd64 / arm64） |
| 1/4 | 获取官方最新版本（GitHub API）→ 下载静态二进制 tgz（pkgs.tailscale.com）→ 安装到 `/usr/local/bin` |
| 2/4 | 创建 OpenRC 服务 `tailscaled`（supervise-daemon 自愈）+ 启动 |
| 3/4 | 开启 IPv4/IPv6 转发（写入 `/etc/sysctl.conf` + 即时生效） |
| 4/4 | 验证安装 + TUN 设备检查 |

---

## 安装方式说明（为什么不用 apk 包）

| 方案 | 版本 | 说明 |
|------|------|------|
| ❌ Alpine community 包 | 滞后（3.24 = 1.98.5） | Tailscale 官方在 Alpine **无独立仓库**，官方 install.sh 也是 apk；版本随 Alpine release 快照，滞后约 4 个小版 |
| ✅ **官方静态二进制**（本脚本） | 最新（1.102.x） | `pkgs.tailscale.com` tgz，纯静态零依赖，与 daed/frpc 同为二进制管理模式 |

---

## 目录结构

```
/usr/local/bin/tailscale     # CLI
/usr/local/bin/tailscaled    # 守护进程 (官方静态)
/var/lib/tailscale/          # 状态目录 (tailnet 身份, 含登录密钥)
/etc/init.d/tailscaled       # OpenRC 服务脚本
/var/log/tailscaled.log      # 运行日志 (supervise-daemon 重定向)
```

---

## 卸载

运行脚本后选择 `2`，按提示确认（默认 `y`）即可卸载：

```bash
./onekey-tailscale_alp.sh
# 选择 2. 卸载 Tailscale
```

卸载清理内容：

| 清理项 | 说明 |
|--------|------|
| tailscaled 服务 | 停止并移出 default 运行级 + 删除 `/etc/init.d/tailscaled` |
| 二进制 | 删除 `/usr/local/bin/tailscale` + `tailscaled` |
| 状态数据 | 删除 `/var/lib/tailscale`（含登录密钥） |
| IP 转发 | 从 `/etc/sysctl.conf` 删除转发行并恢复 `ip_forward=0`（IPv4/IPv6） |

> ⚠️ 卸载会删除 `/var/lib/tailscale`（tailnet 身份），重装后需重新 `tailscale up` 登录。

> ⚠️ 若卸载后网络/DNS 异常：tailscale 开启 MagicDNS 时曾接管 `/etc/resolv.conf`（`nameserver 100.100.100.100`），卸载后可能未完全还原（Alpine 用 openresolv 管理）——检查 `/etc/resolv.conf` 或重启容器即可恢复。

---

## 服务管理

```bash
tailscale status                    # 查看网络状态和在线节点
tailscale ip                        # 查看本机 Tailscale IP
tailscale ping <host>               # 测试到另一节点的连通性
tailscale down                      # 断开 Tailscale 网络
rc-service tailscaled restart       # 重启 tailscale 服务
tail -f /var/log/tailscaled.log     # 实时日志
```

> 服务由 `supervise-daemon` 托管：进程异常退出自动拉起。与 Debian 版服务名一致（`tailscaled`）。

---

## 下一步：登录

安装完成后，在需要加入同一网络的每台机器上执行：

```bash
tailscale up
```

首次运行会打印登录链接，在浏览器中打开并授权即可。多台机器都加入后，即可通过 Tailscale IP（`100.x.x.x`）互通。

---

## 四件套部署顺序（网络基础设施强绑同一 Alpine LXC）

本脚本与 `onekey-init_alp`、`onekey-mosdns_alp`、`onekey-frpc_alp` 配套，将网络基础服务从 Linux Gate（daed 所在机）分离：

```bash
./onekey-init_alp.sh            # ① 系统初始化（换源/工具/时区）
./onekey-tailscale_alp.sh       # ② tailscale + tailscale up 登录
./onekey-mosdns_alp.sh          # ③ mosdns (remote 上游 = tailnet VPS dnsmasq)
./onekey-frpc_alp.sh            # ④ frpc
```

三个服务均以 OpenRC 托管、`supervise-daemon` 崩溃自动拉起；各自独立，卸载互不影响。

---

## 许可证

本项目基于 [GPL-3.0](LICENSE) 协议。
