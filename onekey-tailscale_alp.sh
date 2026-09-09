#!/bin/sh
# ============================================================
# onekey-tailscale_alp — Tailscale 一键安装/卸载脚本 (Alpine LXC 直装版)
# 适用环境: Alpine Linux (LXC / 物理机 / VM), OpenRC
# 功能: 安装 tailscale + 开启 IP 转发 + 环境检查
# 与 onekey-tailscale (Debian 直装版) 功能一致, 平台层适配 apk/OpenRC
# 服务名差异: Debian 用 tailscaled, Alpine 包自带 OpenRC 服务名 = tailscale
# ============================================================
set -e

# ---------- 彩色输出 (busybox echo 支持 -e) ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 检测系统版本 ----------
info "检测系统版本..."
. /etc/os-release
[ "$ID" = "alpine" ] || warn "  非 Alpine 系统 (当前: ${NAME}), 脚本按 Alpine/OpenRC 语义运行, 可能不适用"
ALPINE_VERSION=${VERSION_ID:-unknown}
info "  发行版: ${NAME} ${VERSION_ID}"
info "  包管理: apk / 服务管理: OpenRC"

# ---------- 确保 community 仓库已启用 (tailscale 在 community) ----------
ensure_community_repo() {
  REPOS_FILE=/etc/apk/repositories
  # 标准 Alpine: 仓库行形如 https://dl-cdn.alpinelinux.org/alpine/v3.2x/main 与 .../community
  if grep -q '^http.*/community$' "$REPOS_FILE" 2>/dev/null; then
    info "  ✓ community 仓库已启用"
    return 0
  fi
  info "  启用 community 仓库..."
  # 以 main 行推导同版本 community 行 (无 main 行则跳过, 由用户手工处理镜像)
  MAIN_LINE=$(grep -E '^http.*/main$' "$REPOS_FILE" 2>/dev/null | head -1)
  if [ -n "$MAIN_LINE" ]; then
    COMM_LINE=$(echo "$MAIN_LINE" | sed 's#/main$#/community#')
    echo "$COMM_LINE" >> "$REPOS_FILE"
    info "  已添加: $COMM_LINE"
  else
    warn "  未找到 main 仓库行, 请手工确认 /etc/apk/repositories 包含 community"
  fi
  apk update >/dev/null 2>&1 || warn "  apk update 失败, 请检查网络/镜像"
}

# ---------- 版本检测 ----------
get_current_ver() {
  if ! command -v tailscale &>/dev/null; then
    echo ""; return
  fi
  tailscale version 2>/dev/null | head -1 || echo ""
}

# ---------- 卸载函数 ----------
uninstall_tailscale() {
  echo ""
  warn "========== 卸载 Tailscale =========="
  echo ""
  printf "确认卸载 Tailscale？(y/n，默认 y): " >&2
  read CONFIRM </dev/tty
  CONFIRM=${CONFIRM:-y}
  case "$CONFIRM" in
    y|Y) : ;;
    *) info "已取消卸载"; exit 0 ;;
  esac

  # 1. 停止并禁用服务 (Alpine 服务名 = tailscale)
  info "=== 1/5 停止并禁用 tailscale 服务 ==="
  rc-service tailscale stop 2>/dev/null || true
  rc-update del tailscale 2>/dev/null || true

  # 2. 卸载包 (只删 tailscale 本体, 不牵连其它 — Alpine apk 无 autoremove 概念)
  info "=== 2/5 卸载 tailscale 包 ==="
  apk del tailscale tailscale-openrc 2>/dev/null || apk del tailscale || true

  # 3. 删除状态数据
  TS_DATA_DIR="/var/lib/tailscale"
  [ "$TS_DATA_DIR" = "/var/lib/tailscale" ] || err "TS_DATA_DIR 异常"
  info "=== 3/5 删除状态数据 ${TS_DATA_DIR} ==="
  rm -rf "$TS_DATA_DIR"

  # 4. 清理 IP 转发配置 (安装时写入 /etc/sysctl.conf, 卸载时清除并恢复默认值 0)
  info "=== 4/5 清理 IP 转发配置 ==="
  sed -i '/^net\.ipv4\.ip_forward = 1$/d;/^net\.ipv6\.conf\.all\.forwarding = 1$/d' /etc/sysctl.conf 2>/dev/null || true
  sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=0 > /dev/null 2>&1 || true

  # 5. 网络自检 (只读, 不干预)
  info "=== 5/5 网络自检 ==="
  GW=$(ip route | awk '/default/ {print $3; exit}')
  if [ -n "$GW" ] && ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
    info "  ✓ 默认网关 ${GW} 连通正常"
  else
    warn "  ⚠ 默认网关 (${GW:-未知}) ping 不通，网络可能受影响，请检查"
  fi

  echo ""
  info "========== 卸载完成 =========="
  if command -v tailscale >/dev/null 2>&1; then
    warn "  ⚠ tailscale 命令仍然存在，请检查"
  else
    info "  ✓ tailscale 已移除"
  fi
  info "  ✓ IP 转发已恢复 (ip_forward = $(cat /proc/sys/net/ipv4/ip_forward))"
  info "  提示: 如其他服务依赖 IP 转发，请自行重新开启"
  warn "  ⚠ 提示: 若卸载后网络/DNS 异常，可能因 tailscale 曾接管 resolv.conf"
  warn "    (nameserver 100.100.100.100) 未完全还原 (Alpine 用 openresolv 管理)"
  warn "    → 检查 /etc/resolv.conf 或执行: rc-service tailscale stop 后重启网络"
  exit 0
}

# ---------- 菜单 ----------
echo ""
echo "========================================"
echo "  Tailscale 一键安装/卸载脚本 (Alpine)"
echo "========================================"
echo ""

CURRENT_VER=$(get_current_ver)
if [ -n "$CURRENT_VER" ]; then
  info "检测到 Tailscale ${CURRENT_VER} 已安装"
else
  info "Tailscale 未安装"
fi

echo ""
echo "请选择操作："
echo "  1. 安装 Tailscale"
echo "  2. 卸载 Tailscale"
echo "  0. 退出"
echo ""
printf "请输入选项 (0-2，默认 1): " >&2
read ACTION </dev/tty
ACTION=${ACTION:-1}
echo ""

do_install() {

# =================== 1. 安装 Tailscale ===================
info "=== 1/4 安装 Tailscale ==="

# 确保基础工具 + community 仓库
command -v curl >/dev/null 2>&1 || apk add --no-cache -q curl
[ -f /etc/ssl/certs/ca-certificates.crt ] || apk add --no-cache -q ca-certificates
ensure_community_repo

# Alpine 官方仓库安装 (包自带 tailscale-openrc 服务)
apk add --no-cache -q tailscale

TAILSCALE_VER=$(tailscale version 2>/dev/null | head -1 || echo "unknown")
info "  ✓ Tailscale ${TAILSCALE_VER} 已安装"

# =================== 2. 启用并启动服务 ===================
info "=== 2/4 启用并启动 tailscale 服务 ==="

# Alpine 包 OpenRC 服务名 = tailscale (与 Debian 的 tailscaled 不同)
if [ ! -f /etc/init.d/tailscale ]; then
  err "  /etc/init.d/tailscale 不存在，包安装异常"
fi

rc-update add tailscale default 2>/dev/null || true
if ! rc-service tailscale status >/dev/null 2>&1; then
  rc-service tailscale start || warn "  tailscale 启动失败，请稍后检查日志"
fi
sleep 1
if rc-service tailscale status >/dev/null 2>&1; then
  info "  ✓ tailscale 服务状态: started"
else
  warn "  ⚠ tailscale 服务未运行, 日志: cat /var/log/tailscaled.log"
fi

# =================== 3. 开启 IP 转发 ===================
info "=== 3/4 开启 IP 转发 ==="

# Alpine 启动加载 /etc/sysctl.conf (openrc sysctl 服务), 写入幂等
grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.conf 2>/dev/null \
  || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf

grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.conf 2>/dev/null \
  || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf

# 立即生效
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1

FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$FORWARD" = "1" ]; then
  info "  ✓ IP 转发已开启 (ip_forward = 1)"
else
  warn "  ✗ IP 转发状态异常 (ip_forward = ${FORWARD})"
fi

# =================== 4. 验证 ===================
info "=== 4/4 验证 ==="

# 检查 tailscale 二进制
if command -v tailscale >/dev/null 2>&1; then
  info "  ✓ tailscale 命令可用"
else
  err "  ✗ tailscale 未找到，安装可能失败"
fi

# 检查 TUN 设备 (LXC 常见问题)
info "  检查 TUN 设备..."
if [ -c /dev/net/tun ]; then
  info "  ✓ /dev/net/tun 可用"
else
  warn "  ⚠ /dev/net/tun 不存在！"
  warn "     Tailscale 需要 TUN 设备，请在 PVE 宿主机上执行以下操作："
  warn "     1) 编辑 LXC 配置文件: /etc/pve/lxc/<CT_ID>.conf"
  warn "     2) 添加以下两行："
  warn "       lxc.cgroup2.devices.allow: c 10:200 rwm"
  warn "       lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
  warn "     3) 重启容器后重新运行此脚本"
fi

# =================== 完成 ===================
echo ""
info "========== 安装完成 =========="
info " Tailscale 版本: ${TAILSCALE_VER}"
info " 系统版本:      ${NAME} ${VERSION_ID}"
info " sysctl 配置:   /etc/sysctl.conf (ip_forward 行)"
echo ""
info "=== 下一步：登录并启动 ==="
info "  在需要加入同一网络的每台机器上执行:"
info ""
info "    tailscale up"
info ""
info "  首次运行会打印登录链接，在浏览器打开并授权即可。"
info "  多台机器都加入后，即可通过 Tailscale IP (100.x.x.x) 互通。"
echo ""
info "=== 常用命令 ==="
info "  tailscale status          # 查看网络状态和在线节点"
info "  tailscale ip              # 查看本机 Tailscale IP"
info "  tailscale ping <host>     # 测试到另一节点的连通性"
info "  tailscale down            # 断开 Tailscale 网络"
info "  rc-service tailscale restart  # 重启 tailscale 服务"
}

case "$ACTION" in
  2) uninstall_tailscale ;;
  0) info "已退出"; exit 0 ;;
  1) do_install ;;
  *) err "无效选项: ${ACTION}" ;;
esac
