#!/bin/sh
# ============================================================
# onekey-tailscale_alp — Tailscale 一键安装/升级/卸载脚本 (Alpine 直装版, 官方二进制)
# 适用环境: Alpine Linux (LXC / 物理机 / VM), OpenRC
# 与 onekey-tailscale (Debian 直装版) 功能一致
# 安装方式: 官方静态二进制 (pkgs.tailscale.com) + 自管 OpenRC 服务 tailscaled
#   —— 不走 Alpine community 包 (版本滞后约 4 个小版, 2026-09 决策改 B 方案)
# 服务自愈: supervise-daemon 崩溃自动拉起
# ============================================================
set -e

trap 'echo -e "\033[0;31m[ERROR] 脚本执行失败，请检查:\033[0m
  - 网络连接（能否访问 pkgs.tailscale.com / api.github.com）
  - 是否以 root 运行
  - 系统架构是否支持" >&2' ERR

# ---------- 配置 ----------
INSTALL_DIR="/usr/local/bin"
BIN_TS="/usr/local/bin/tailscale"
BIN_TSD="/usr/local/bin/tailscaled"
DATA_DIR="/var/lib/tailscale"
FALLBACK_VER="1.102.3"

# ---------- 彩色输出 ----------
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

# ---------- 检测系统 ----------
info "检测系统版本..."
. /etc/os-release 2>/dev/null || true
info "  发行版: ${NAME:-unknown} ${VERSION_ID:-}"
[ "$ID" = "alpine" ] || warn "  非 Alpine 系统, 脚本按 apk/OpenRC 语义运行, 可能不适用"

# ---------- 检测架构 ----------
detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       echo ""       ;;
  esac
}

# ---------- 获取最新版本 ----------
fetch_latest_ver() {
  # 官方 GitHub release tag: v1.x.y → 去 v
  curl -s --connect-timeout 5 \
    https://api.github.com/repos/tailscale/tailscale/releases/latest \
    | grep -o '"tag_name": *"[^"]*"' | grep -o 'v[0-9.]*' 2>/dev/null | tr -d 'v' || echo ""
}

# ---------- 获取当前版本 ----------
get_current_ver() {
  if [ ! -x "$BIN_TS" ]; then
    echo ""; return
  fi
  "$BIN_TS" version 2>/dev/null | head -1 || echo ""
}

# ---------- 基础依赖 ----------
ensure_deps() {
  NEED=""
  command -v curl >/dev/null 2>&1 || NEED="$NEED curl"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || NEED="$NEED ca-certificates"
  [ -z "$NEED" ] || apk add --no-cache -q $NEED
}

# ---------- 下载安装核心 (安装/升级共用) ----------
install_binaries() {
  VER="$1"
  ARCH="$2"
  info "  下载 Tailscale ${VER} (${ARCH}, 官方静态二进制)..."
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"
  wget -q "https://pkgs.tailscale.com/stable/tailscale_${VER}_${ARCH}.tgz" -O ts.tgz \
    || err "下载失败: https://pkgs.tailscale.com/stable/tailscale_${VER}_${ARCH}.tgz"
  tar xzf ts.tgz
  EXTRACT_DIR=$(find . -maxdepth 1 -type d -name "tailscale_*" | head -1)
  [ -z "$EXTRACT_DIR" ] && err "解压后找不到 tailscale 目录"
  # 官方 tgz 内含 tailscale + tailscaled 两个二进制
  [ -f "${EXTRACT_DIR}/tailscale" ] && [ -f "${EXTRACT_DIR}/tailscaled" ] \
    || err "tgz 内容不完整 (缺 tailscale/tailscaled)"
  install -m 755 "${EXTRACT_DIR}/tailscale" "$BIN_TS"
  install -m 755 "${EXTRACT_DIR}/tailscaled" "$BIN_TSD"
  rm -rf "$TMPDIR"
}

# ---------- 卸载 ----------
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

  # 1. 停止并禁用服务
  info "=== 1/5 停止并禁用 tailscaled 服务 ==="
  rc-service tailscaled stop 2>/dev/null || true
  rc-update del tailscaled 2>/dev/null || true

  # 2. 删除服务脚本与二进制
  info "=== 2/5 删除服务脚本与二进制 ==="
  rm -f /etc/init.d/tailscaled
  rm -f "$BIN_TS" "$BIN_TSD"

  # 3. 删除状态数据
  info "=== 3/5 删除状态数据 ${DATA_DIR} ==="
  rm -rf "$DATA_DIR"

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
  if [ -x "$BIN_TS" ]; then
    warn "  ⚠ tailscale 命令仍然存在，请检查"
  else
    info "  ✓ tailscale 已移除"
  fi
  info "  ✓ IP 转发已恢复 (ip_forward = $(cat /proc/sys/net/ipv4/ip_forward))"
  info "  提示: 如其他服务依赖 IP 转发，请自行重新开启"
  warn "  ⚠ 提示: 若卸载后网络/DNS 异常，可能因 tailscale 曾接管 resolv.conf"
  warn "    (nameserver 100.100.100.100) 未完全还原 (Alpine 用 openresolv 管理)"
  warn "    → 检查 /etc/resolv.conf 或重启容器恢复"
  exit 0
}

# ---------- 安装 ----------
do_install() {
  TS_VER="$1"
  TS_ARCH="$2"

  ensure_deps
  info "=== 1/4 下载并安装 Tailscale ${TS_VER} ==="
  install_binaries "$TS_VER" "$TS_ARCH"
  info "  ✓ tailscale/tailscaled 已安装到 /usr/local/bin"

  info "=== 2/4 创建并启动 tailscaled 服务 ==="
  cat > /etc/init.d/tailscaled << 'SERVICEEOF'
#!/sbin/openrc-run
# tailscaled OpenRC 服务 (官方静态二进制 + supervise-daemon 自愈)
name="tailscaled"
description="Tailscale daemon"
supervisor="supervise-daemon"
command="/usr/local/bin/tailscaled"
pidfile="/run/tailscaled.pid"
respawn_delay=5
supervise_daemon_args="--stdout /var/log/tailscaled.log --stderr /var/log/tailscaled.log"

depend() {
    need net
}
SERVICEEOF
  chmod +x /etc/init.d/tailscaled
  mkdir -p /var/log
  rc-update add tailscaled default 2>/dev/null || true
  rc-service tailscaled start || warn "  tailscaled 启动失败，请查看 /var/log/tailscaled.log"
  sleep 1
  if rc-service tailscaled status >/dev/null 2>&1; then
    info "  ✓ tailscaled 服务状态: started"
  else
    warn "  ⚠ tailscaled 服务未运行, 日志: cat /var/log/tailscaled.log"
  fi

  info "=== 3/4 开启 IP 转发 ==="
  grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.conf 2>/dev/null \
    || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.conf 2>/dev/null \
    || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
  # 确保 Alpine 开机自动应用 /etc/sysctl.conf (容器模板默认未启用 sysctl 服务,
  #   否则容器重启后 ip_forward 回 0, subnet router 转发失效 —— 2026-09-09 实机踩坑)
  if ! rc-update show 2>/dev/null | grep -q '^ *sysctl '; then
    rc-update add sysctl boot >/dev/null 2>&1 || warn "  ⚠ rc-update add sysctl boot 失败"
  fi
  sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
  sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
  FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
  if [ "$FORWARD" = "1" ]; then
    info "  ✓ IP 转发已开启 (ip_forward = 1)"
  else
    warn "  ✗ IP 转发状态异常 (ip_forward = ${FORWARD})"
  fi

  info "=== 4/4 验证 ==="
  if [ -x "$BIN_TS" ]; then
    info "  ✓ tailscale 命令可用"
  else
    err "  ✗ tailscale 未找到，安装可能失败"
  fi
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

  echo ""
  info "========== 安装完成 =========="
  info " Tailscale 版本: ${TS_VER}"
  info " 二进制:         ${BIN_TS} + ${BIN_TSD} (官方静态)"
  info " 状态目录:       ${DATA_DIR}"
  info " sysctl 配置:    /etc/sysctl.conf (ip_forward 行)"
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
  info "  rc-service tailscaled restart  # 重启 tailscale 服务"
  info "  tail -f /var/log/tailscaled.log # 实时日志"
}

# ---------- 升级 ----------
do_upgrade() {
  TS_VER="$1"
  TS_ARCH="$2"
  CURRENT_VER="$3"

  ensure_deps
  info "=== 升级 Tailscale: ${CURRENT_VER} → ${TS_VER} ==="
  # 备份旧二进制
  cat "$BIN_TS" > "${BIN_TS}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  cat "$BIN_TSD" > "${BIN_TSD}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  install_binaries "$TS_VER" "$TS_ARCH"
  if rc-service tailscaled status >/dev/null 2>&1; then
    rc-service tailscaled restart
    info "  ✓ tailscaled 服务已重启"
  fi
  info "  ✓ 已升级到 ${TS_VER} (备份: /usr/local/bin/tailscale*.bak.*)"
}

# ---------- 菜单 ----------
echo ""
echo "========================================"
echo "  Tailscale 一键安装/升级/卸载脚本 (Alpine)"
echo "========================================"
echo ""

TS_ARCH=$(detect_arch)
[ -z "$TS_ARCH" ] && err "不支持的架构: $(uname -m) (仅支持 amd64 / arm64)"

INSTALLED=false
CURRENT_VER=$(get_current_ver)
if [ -n "$CURRENT_VER" ]; then
  INSTALLED=true
  info "检测到 Tailscale ${CURRENT_VER} 已安装"
else
  info "Tailscale 未安装"
fi

echo ""
echo "请选择操作："
echo "  1. 安装 / 升级 Tailscale"
echo "  2. 卸载 Tailscale"
echo "  0. 退出"
echo ""
printf "请输入选项 (0-2，默认 1): " >&2
read ACTION </dev/tty
ACTION=${ACTION:-1}
echo ""

case "$ACTION" in
  2) uninstall_tailscale ;;
  0) info "已退出"; exit 0 ;;
  1)
    LATEST_VER=$(fetch_latest_ver)
    if [ -z "$LATEST_VER" ]; then
      LATEST_VER="$FALLBACK_VER"
      warn "GitHub API 不可用，使用后备版本 ${FALLBACK_VER}"
    fi
    if [ "$INSTALLED" = true ]; then
      if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$LATEST_VER" ]; then
        info "当前版本: ${CURRENT_VER}"
        info "✓ 已是最新版本，无需更新"
        exit 0
      fi
      do_upgrade "$LATEST_VER" "$TS_ARCH" "$CURRENT_VER"
    else
      do_install "$LATEST_VER" "$TS_ARCH"
    fi
    ;;
  *) err "无效选项: ${ACTION}" ;;
esac
