# onekey-tailscale_alp

一键在 **Alpine Linux LXC** 上安装/卸载 [Tailscale](https://tailscale.com) 并配置 IP 转发，支持 LXC 容器环境。脚本为菜单模式（安装 / 卸载 / 退出）。

> 功能与 [onekey-tailscale](https://github.com/guochan2019/onekey-tailscale)（Debian 直装版）完全一致，平台层适配 **apk + OpenRC**。

---

## 快速开始

> ⚠️ 需要 root 权限。适用 Alpine Linux（OpenRC），包管理 apk。

### 方式一：gh CLI（推荐）

```bash
gh repo clone guochan2019/onekey-tailscale_alp
cd onekey-tailscale_alp
chmod +x onekey-tailscale_alp.sh
./onekey-tailscale_alp.sh
```

### 方式二：wget

```bash
wget -qO- https://raw.githubusercontent.com/guochan2019/onekey-tailscale_alp/main/onekey-tailscale_alp.sh | sh
```

---

## 部署前置（Alpine LXC）

在 PVE 宿主机创建 Alpine LXC（下载 Alpine 模板后创建，3.20+）：

```bash
pveam update
pveam available | grep -i alpine
pct create <CT_ID> local:vztmpl/alpine-3.2x-default_*.tar.zst \
  --hostname <name> --memory 512 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --storage local-lvm --unprivileged 1 --features nesting=1
```

**TUN 设备**（Tailscale 必需）：编辑 `/etc/pve/lxc/<CT_ID>.conf` 添加：

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

添加后重启容器。脚本运行时会自动检查 TUN 设备状态，缺失则打印配置指引。

---

## 使用方式

运行脚本后显示菜单：

```
========================================
  Tailscale 一键安装/卸载脚本 (Alpine)
========================================

[INFO] 检测到 Tailscale 1.x.x 已安装

请选择操作：
  1. 安装 Tailscale
  2. 卸载 Tailscale
  0. 退出
```

## 安装流程

| 步骤 | 说明 |
|------|------|
| 检测 | 确认 root / 发行版为 Alpine |
| 1/4 | 启用 community 仓库（tailscale 所在），`apk add tailscale`（自动带 OpenRC 服务） |
| 2/4 | `rc-update add tailscale default` + 启动服务 |
| 3/4 | 开启 IPv4/IPv6 转发（写入 `/etc/sysctl.conf`，Alpine 启动加载路径） |
| 4/4 | 验证安装 + TUN 设备检查 |

---

## 与 Debian 直装版差异

| 项 | Debian 版 | Alpine 版 |
|----|-----------|-----------|
| 包管理 | APT 源 + `apt purge` | community 仓库 + `apk add/del`（自动启用 community） |
| 服务名 | `tailscaled` | **`tailscale`**（Alpine 包自带 OpenRC 服务名） |
| 服务管理 | `systemctl` | `rc-service` / `rc-update` |
| IP 转发 | `/etc/sysctl.d/99-tailscale.conf` | `/etc/sysctl.conf`（写入幂等） |
| 已知问题修复 | Trixie `/etc/default/tailscaled` 缺失需手动建 | Alpine 包无此问题 |
| resolv.conf 管理 | systemd-resolved | openresolv（apk 自动拉依赖） |

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
| tailscale 服务 | 停止并移出 default 运行级（`rc-service stop` + `rc-update del`） |
| tailscale 包 | `apk del tailscale tailscale-openrc`（不牵连其它包） |
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
rc-service tailscale restart        # 重启 tailscale 服务
tail -f /var/log/tailscaled.log     # 实时日志
```

---

## 下一步：登录

安装完成后，在需要加入同一网络的每台机器上执行：

```bash
tailscale up
```

首次运行会打印登录链接，在浏览器中打开并授权即可。多台机器都加入后，即可通过 Tailscale IP（`100.x.x.x`）互通。

---

## 三件套部署顺序（网络基础设施强绑同一 Alpine LXC）

本脚本与 `onekey-mosdns_alp`、`onekey-frpc_alp` 配套，将三个网络基础服务从 Linux Gate（daed 所在机）分离，避免 daed 故障时连带挂机：

```bash
# 推荐顺序: tailscale → mosdns → frpc (mosdns 远程上游依赖 tailnet 100.x 可达)
./onekey-tailscale_alp.sh    # 先装 tailscale 并 tailscale up 登录
./onekey-mosdns_alp.sh       # 再装 mosdns (remote 上游 = tailnet VPS dnsmasq)
./onekey-frpc_alp.sh         # 最后装 frpc
```

三个服务均以 OpenRC 托管、`supervise-daemon` 崩溃自动拉起；各自独立，卸载互不影响。

---

## 许可证

本项目基于 [GPL-3.0](LICENSE) 协议。
