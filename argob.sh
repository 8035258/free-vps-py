#!/bin/bash

# =====================================================
# Sing-box + Cloudflared 单进程模式安装脚本 (Alpine 3.20)
# Cloudflared 隧道端口固定 8001
# =====================================================

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 路径 ---
INSTALL_PATH="/etc/sing-box"
CONFIG_FILE="${INSTALL_PATH}/config.json"
SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
NODE_INFO_FILE="$HOME/.singbox_vless_node_info"
SINGBOX_PORT=8001

# --- 默认值 ---
NODE_NAME="VLESS-Argo-Singbox"
CFIP="cloudflare.182682.xyz"
CFPORT="443"

# =====================================================
# --- 日志函数 ---
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =====================================================
# 检查系统与初始化系统
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        case "$OS" in
            alpine) PKG_MANAGER="apk" ;;
            debian|ubuntu) PKG_MANAGER="apt" ;;
            centos|fedora|rhel) PKG_MANAGER="yum" ;;
            *) error "不支持的系统: $OS" ;;
        esac
    else
        error "无法检测操作系统"
    fi

    if command -v systemctl &>/dev/null; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        warn "未检测到 systemd 或 openrc"
    fi
}

# 安装依赖
install_deps() {
    log "安装依赖..."
    case "$PKG_MANAGER" in
        apk) apk update && apk add curl tar gzip unzip openrc >/dev/null ;;
        apt) apt update >/dev/null && apt install -y curl tar gzip unzip systemd >/dev/null ;;
        yum) yum install -y curl tar gzip unzip systemd >/dev/null ;;
    esac
    success "依赖安装完成"
}

# 自动获取最新版本号
get_latest_version() {
    local repo="$1"
    # 获取完整的 tag，例如 v1.12.8
    local version=$(curl -sL "https://api.github.com/repos/${repo}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$version" ]; then
        error "无法从 GitHub 获取 ${repo} 的最新版本，请检查网络连接。"
    fi
    echo "$version"
}

# 下载 Sing-box
download_singbox() {
    log "正在下载 Sing-box 二进制文件..."
    local version_tag=$(get_latest_version "SagerNet/sing-box")
    local version_num=$(echo "$version_tag" | sed 's/^v//')

    local arch=$(uname -m)
    local arch_pattern=""
    case $arch in
        x86_64) arch_pattern="linux-amd64" ;;
        aarch64) arch_pattern="linux-arm64" ;;
        armv7l) arch_pattern="linux-armv7" ;;
        i686) arch_pattern="linux-386" ;;
        *) error "不支持的架构：$arch" ;;
    esac

    local file_name="sing-box-${version_num}-${arch_pattern}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/${file_name}"

    log "尝试下载链接: $url"

    if ! curl -fL "$url" -o sing-box.tar.gz; then
        rm -f sing-box.tar.gz
        error "下载 Sing-box 失败，请检查网络或 URL。"
    fi

    if ! tar -xzf sing-box.tar.gz; then
        rm -f sing-box.tar.gz
        error "解压 Sing-box 文件失败。下载的文件可能已损坏。"
    fi

    local extracted_dir=$(tar -tf sing-box.tar.gz | head -n 1 | awk -F/ '{print $1}')

    if [ -f "${extracted_dir}/sing-box" ]; then
        mv "${extracted_dir}/sing-box" "$SINGBOX_BIN"
    else
        rm -rf sing-box.tar.gz "${extracted_dir}"
        error "在压缩包中找不到 sing-box 可执行文件。"
    fi

    chmod +x "$SINGBOX_BIN"
    rm -rf sing-box.tar.gz "${extracted_dir}"
    success "Sing-box ${version_tag} 安装完成。"
}


# 下载 cloudflared
download_cloudflared() {
    log "下载 cloudflared..."
    local arch=$(uname -m)
    local file=""
    case $arch in
        x86_64) file="cloudflared-linux-amd64" ;;
        aarch64) file="cloudflared-linux-arm64" ;;
        armv7l) file="cloudflared-linux-arm" ;;
        i686) file="cloudflared-linux-386" ;;
        *) error "不支持架构 $arch" ;;
    esac

    curl -fL "https://github.com/cloudflare/cloudflared/releases/latest/download/$file" -o "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"
    success "Cloudflared 安装完成"
}

# 生成 UUID
generate_uuid() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "${YELLOW}生成 UUID: ${GREEN}$UUID${NC}"
    read -p "是否使用此 UUID? (默认 y): " choice
    [[ "$choice" =~ ^[Nn]$ ]] && read -p "请输入 UUID: " UUID
    [ -z "$UUID" ] && error "UUID 不能为空"
}

# 收集用户输入
collect_input() {
    generate_uuid
    read -p "请输入 Argo 域名 (例如 vless.example.com): " ARGO_DOMAIN
    [ -z "$ARGO_DOMAIN" ] && error "域名不能为空"
    read -p "请输入 Argo Token: " ARGO_AUTH
    [ -z "$ARGO_AUTH" ] && error "Token 不能为空"
    read -p "节点名称 (默认 $NODE_NAME): " input_name
    [ -n "$input_name" ] && NODE_NAME="$input_name"
    read -p "Cloudflare 优选 IP (默认 $CFIP): " input_cfip
    [ -n "$input_cfip" ] && CFIP="$input_cfip"
}

# 生成配置文件 (单进程模式)
generate_config() {
    log "生成 Sing-box 配置文件..."
    mkdir -p "$INSTALL_PATH"
    local WS_PATH="/${UUID}-path"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $SINGBOX_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": {
          "Host": "$ARGO_DOMAIN"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "argo",
      "tag": "cloudflared",
      "tunnel": {
        "token": "$ARGO_AUTH",
        "url": "http://127.0.0.1:$SINGBOX_PORT"
      }
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "vless-in",
        "outbound": "cloudflared"
      }
    ]
  }
}
EOF
    success "配置文件生成完成，监听端口 $SINGBOX_PORT"
}

# 启动 sing-box 单进程模式
start_singbox() {
    log "启动 Sing-box 单进程模式..."
    "$SINGBOX_BIN" run -C "$INSTALL_PATH"
}

# =====================================================
# 主函数
install_node() {
    check_os
    install_deps
    collect_input
    download_singbox
    download_cloudflared
    generate_config
    start_singbox
}

# =====================================================
# root 检查
[ "$(id -u)" -ne 0 ] && error "请使用 root 运行"

install_node
