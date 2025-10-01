#!/bin/bash

# --- 颜色和样式 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 静态变量 ---
NODE_INFO_FILE="$HOME/.singbox_reality_argo_node_info"
INSTALL_PATH="/etc/sing-box"
CONFIG_FILE="${INSTALL_PATH}/config.json"
SINGBOX_BIN="/usr/local/bin/sing-box"
# CLOUDFLARED_BIN 不再需要
# SINGBOX_PORT 不再需要，直接监听 443
SINGBOX_PORT="443"

# --- 全局变量 (由用户输入或默认值填充) ---
UUID=""
PRIVATE_KEY="" # Reality 私钥
SHORT_ID=""    # Reality Short ID
ARGO_AUTH=""   # Cloudflare Tunnel Token
ARGO_DOMAIN="" # Cloudflare Tunnel 域名
NODE_NAME="VLESS-Reality-Argo"
CFIP="cloudflare.182682.xyz"
CFPORT="443"


# =================================================================
# --- 核心功能函数 ---
# =================================================================

# 打印日志
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
# 打印成功信息
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
# 打印警告信息
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
# 打印错误信息并退出
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v python3 &> /dev/null; then
        python3 -c "import uuid; print(str(uuid.uuid4()))"
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 生成 Reality 参数
generate_reality_params() {
    log "正在生成 VLESS Reality 参数..."
    local output
    # 使用 sing-box 命令直接生成私钥和 Short ID
    output=$("$SINGBOX_BIN" generate reality)
    
    PRIVATE_KEY=$(echo "$output" | grep 'private key' | awk '{print $NF}')
    SHORT_ID=$(echo "$output" | grep 'short id' | awk '{print $NF}')
    
    if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ]; then
        error "无法生成 Reality 参数。请确保 sing-box 已正确安装和运行。"
    fi
    
    success "Reality Private Key: $PRIVATE_KEY"
    success "Reality Short ID: $SHORT_ID"
}

# 查看已保存的节点信息
view_node_info() {
    if [ -f "$NODE_INFO_FILE" ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}           节点信息查看               ${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo
        cat "$NODE_INFO_FILE"
        echo
    else
        error "未找到节点信息文件 ($NODE_INFO_FILE)"
        warn "请先运行部署脚本生成节点信息"
    fi
}

# 检查 root 权限
check_root() {
    [[ $EUID -ne 0 ]] && error "此脚本需要以 root 权限运行。"
}

# 检测操作系统和架构
detect_os_arch() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
    else
        error "无法检测到操作系统。"
    fi
    log "检测到原始操作系统 ID: $OS_ID"

    case "$OS_ID" in
        centos|rhel|fedora)
            OS_ID="rhel"
            log "已将操作系统 ID 归类为: $OS_ID"
            ;;
        debian|ubuntu|alpine)
            ;;
        *)
            warn "检测到未知操作系统 ID: $OS_ID，脚本将尝试继续。"
            ;;
    esac

    case $(uname -m) in
        x86_64 | amd64) ARCH="amd64" ;;
        aarch64 | arm64) ARCH="arm64" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
    log "检测到系统架构: $ARCH"
}

# 安装依赖 (移除 uuid-runtime, 新增必要的依赖)
install_dependencies() {
    log "正在更新软件包列表并安装依赖..."
    case $OS_ID in
        alpine)
            apk update && apk add --no-cache curl wget tar unzip bash jq
            ;;
        debian | ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update && apt-get install -y curl wget tar unzip bash jq
            ;;
        rhel)
            if command -v dnf &> /dev/null; then
                dnf install -y curl wget tar unzip bash jq
            elif command -v yum &> /dev/null; then
                yum install -y curl wget tar unzip bash jq
            else
                error "未找到 dnf 或 yum 包管理器。"
            fi
            ;;
        *)
            warn "无法识别的操作系统: $OS_ID, 脚本将继续，但请确保已手动安装 curl, wget, tar, unzip, bash, jq"
            ;;
    esac
    [[ $? -ne 0 ]] && error "依赖安装失败。"
    success "依赖安装完成。"
}

# 停止并禁用旧服务 (移除 cloudflared)
stop_and_disable_services() {
    log "正在停止并禁用可能存在的旧服务..."
    if command -v systemctl &> /dev/null; then
        # 仅停止 sing-box 和可能存在的旧 cloudflared
        systemctl stop sing-box cloudflared &>/dev/null
        systemctl disable sing-box cloudflared &>/dev/null
        # 移除 cloudflared service 文件
        rm -f /etc/systemd/system/cloudflared.service
    elif command -v rc-service &> /dev/null; then
        rc-service sing-box stop &>/dev/null
        rc-service cloudflared stop &>/dev/null
        rc-update del sing-box default &>/dev/null
        rc-update del cloudflared default &>/dev/null
        # 移除 cloudflared service 文件
        rm -f /etc/init.d/cloudflared
    fi
}

# 下载并安装 sing-box (移除 cloudflared)
download_and_install_singbox() {
    local name="sing-box"
    local bin_path="$SINGBOX_BIN"

    log "正在获取 sing-box 最新版本下载链接..."
    local SINGBOX_DOWNLOAD_URL
    SINGBOX_DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r --arg ARCH "$ARCH" '.assets[] | select(.name | endswith("linux-\($ARCH).tar.gz")) | .browser_download_url')

    if [ -z "$SINGBOX_DOWNLOAD_URL" ]; then
        error "无法自动获取 sing-box 最新下载链接。"
    fi
    log "已获取最新链接: $SINGBOX_DOWNLOAD_URL"
    
    log "正在下载 $name..."
    wget -q -O "/tmp/$name.dl" "$SINGBOX_DOWNLOAD_URL"
    [[ $? -ne 0 ]] && error "$name 下载失败。 URL: $SINGBOX_DOWNLOAD_URL"

    log "正在解压并安装 $name..."
    mkdir -p /tmp/install_temp
    # 解压到临时目录
    tar -xzf "/tmp/$name.dl" -C /tmp/install_temp
    
    # 在解压文件中找到 sing-box 二进制文件并移动
    local found_bin=$(find /tmp/install_temp -type f -name "$name")
    if [[ -n "$found_bin" ]]; then
        mv "$found_bin" "$bin_path"
    else
        error "在下载的 $name 压缩包中未找到可执行文件。"
    fi

    chmod +x "$bin_path"
    rm -rf /tmp/install_temp /tmp/$name.dl
    success "$name 安装完成。"
}

# 创建 sing-box 配置文件 (核心修改)
create_config_file() {
    log "正在创建 sing-box 配置文件 (VLESS+Reality+Argo)..."
    mkdir -p "$INSTALL_PATH"
    
    # Reality 伪装域名，使用默认值
    local REALITY_SERVER_NAME="www.youtube.com" 
    
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${SINGBOX_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "transport": {
        "type": "tcp"
      },
      "tls": {
        "enabled": true,
        "server_name": "${ARGO_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
             "server": "${REALITY_SERVER_NAME}"
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "cloudflare-tunnel",
      "tag": "cloudflare-tunnel-out",
      "domain": "${ARGO_DOMAIN}",
      "token": "${ARGO_AUTH}"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "vless-in",
        "outbound": "cloudflare-tunnel-out"
      }
    ]
  }
}
EOF
    success "配置文件创建完成: $CONFIG_FILE"
}

# 创建并启用服务 (仅 sing-box)
create_and_enable_service() {
    log "正在创建并启用 sing-box 服务..."
    
    if [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "rhel" ]; then
        # systemd
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service (VLESS+Reality+Argo)
After=network.target
[Service]
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
        # 确保移除 cloudflared.service 
        rm -f /etc/systemd/system/cloudflared.service
        
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
    elif [ "$OS_ID" = "alpine" ]; then
        # OpenRC
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
pidfile="/run/\${RC_SVCNAME}.pid"
name="sing-box"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        
        # 确保移除 cloudflared init.d 文件
        rm -f /etc/init.d/cloudflared

        rc-update add sing-box default
        rc-service sing-box restart
    fi
    success "sing-box 服务启动成功。"
}

# 显示并保存结果
show_and_save_result() {
    local final_domain="${ARGO_DOMAIN}"
    local REALITY_SERVER_NAME="www.youtube.com" 

    # VLESS 链接使用 Reality 参数
    # 注意：此链接使用 Reality 的 'dest' 参数模拟 Cloudflare 优选IP和端口
    VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?security=reality&sni=${ARGO_DOMAIN}&fp=chrome&pbk=${SHORT_ID}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&dest=${REALITY_SERVER_NAME}:${CFPORT}#${NODE_NAME}" 
    
    SAVE_INFO="========================================
           节点信息 (VLESS + Reality + Argo)
========================================
部署时间: $(date)
节点名称: ${NODE_NAME}
UUID: ${UUID}
优选IP: ${CFIP}
优选端口: ${CFPORT}
隧道域名: ${ARGO_DOMAIN}
Reality 私钥 (Private Key): ${PRIVATE_KEY}
Reality 短 ID (Short ID): ${SHORT_ID}
----------------------------------------
VLESS Reality 链接:
${VLESS_LINK}
----------------------------------------
管理命令:
查看节点: bash $0 -v
重启服务 (systemd/OpenRC): systemctl restart sing-box 或 rc-service sing-box restart
查看日志 (systemd): journalctl -u sing-box -f
查看日志 (OpenRC): tail -f /var/log/messages
========================================"

    echo "$SAVE_INFO" > "$NODE_INFO_FILE"

    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}           部署完成！                   ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}节点信息已保存到: ${NC}${BLUE}$NODE_INFO_FILE${NC}"
    echo
    cat "$NODE_INFO_FILE"
    echo
    success "感谢使用！"
}


# =================================================================
# --- 交互式菜单和安装流程 ---
# =================================================================

# 极速模式 (已移除，因为此架构强制要求 ARGO_AUTH 和 ARGO_DOMAIN)
# 修改为简化安装，仍要求输入 Token 和 Domain
simplified_mode() {
    clear
    echo -e "${BLUE}=== VLESS+Reality+Argo 简化模式 ===${NC}"
    warn "注意: 此架构强制要求使用 Cloudflare Argo Token 和绑定域名。"
    
    # 1. UUID
    read -p "请输入您的 UUID (留空将自动生成): " UUID_INPUT
    UUID=${UUID_INPUT:-$(generate_uuid)}
    success "UUID 已设置为: $UUID"

    # 2. Token
    read -p "请输入 Cloudflare Argo Tunnel Token (必须填写): " ARGO_AUTH_INPUT
    [[ -z "$ARGO_AUTH_INPUT" ]] && error "必须提供 Argo Tunnel Token。"
    ARGO_AUTH=${ARGO_AUTH_INPUT}

    # 3. Domain
    read -p "请输入与该Token关联的域名 (必须填写): " ARGO_DOMAIN_INPUT
    [[ -z "$ARGO_DOMAIN_INPUT" ]] && error "必须提供固定域名。"
    ARGO_DOMAIN=${ARGO_DOMAIN_INPUT}
    
    # 4. 默认值
    NODE_NAME="VLESS-Reality-Argo-Simp"
    CFIP="cloudflare.182682.xyz"
    CFPORT="443"

    run_installation
}

# 完整模式 (与简化模式合并，因为参数是必需的)
full_mode() {
    clear
    echo -e "${BLUE}=== VLESS+Reality+Argo 完整配置模式 ===${NC}"
    warn "注意: 此架构强制要求使用 Cloudflare Argo Token 和绑定域名。"
    
    # 1. UUID
    read -p "请输入您的 UUID (留空将自动生成): " UUID_INPUT
    UUID=${UUID_INPUT:-$(generate_uuid)}
    success "UUID 已设置为: $UUID"

    # 2. 节点名称
    read -p "请输入节点名称 [默认: VLESS-Reality-Argo]: " NODE_NAME_INPUT
    NODE_NAME=${NODE_NAME_INPUT:-"VLESS-Reality-Argo"}
    
    # 3. 优选IP和端口
    read -p "请输入优选IP/域名 [默认: cloudflare.182682.xyz]: " CFIP_INPUT
    CFIP=${CFIP_INPUT:-"cloudflare.182682.xyz"}

    read -p "请输入优选端口 [默认: 443]: " CFPORT_INPUT
    CFPORT=${CFPORT_INPUT:-"443"}

    # 4. Token
    read -p "请输入 Cloudflare Argo Tunnel Token (必须填写): " ARGO_AUTH_INPUT
    [[ -z "$ARGO_AUTH_INPUT" ]] && error "必须提供 Argo Tunnel Token。"
    ARGO_AUTH=${ARGO_AUTH_INPUT}

    # 5. Domain
    read -p "请输入与该Token关联的域名 (必须填写): " ARGO_DOMAIN_INPUT
    [[ -z "$ARGO_DOMAIN_INPUT" ]] && error "必须提供固定域名。"
    ARGO_DOMAIN=${ARGO_DOMAIN_INPUT}
    
    run_installation
}

# 运行实际安装流程
run_installation() {
    echo -e "${GREEN}=== 开始部署 (内核: sing-box + 内置 Argo + Reality) ===${NC}"
    check_root
    detect_os_arch
    install_dependencies
    stop_and_disable_services
    
    download_and_install_singbox # 仅安装 sing-box
    
    generate_reality_params # 生成 Reality 参数

    create_config_file
    create_and_enable_service # 仅启用 sing-box 服务
    show_and_save_result
}

# 卸载脚本 (移除 cloudflared 相关的卸载)
uninstall_service() {
    clear
    echo -e "${RED}=== 卸载脚本 ===${NC}"
    warn "这将从系统中移除 sing-box 以及所有相关配置文件和服务。"
    read -p "您确定要继续吗? (y/N): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}卸载已取消。${NC}"
        exit 0
    fi

    check_root
    detect_os_arch
    
    log "正在停止并禁用服务..."
    if command -v systemctl &> /dev/null && ([ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "rhel" ]); then
        systemctl stop sing-box &>/dev/null
        systemctl disable sing-box &>/dev/null
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service # 确保移除 cloudflared
        systemctl daemon-reload
    elif command -v rc-service &> /dev/null; then
        rc-service sing-box stop &>/dev/null
        rc-service cloudflared stop &>/dev/null # 尝试停止 cloudflared 以防万一
        rc-update del sing-box default &>/dev/null
        rc-update del cloudflared default &>/dev/null
        rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
    fi
    
    log "正在移除二进制文件..."
    rm -f "$SINGBOX_BIN"
    
    log "正在移除配置文件目录..."
    rm -rf "$INSTALL_PATH"
    
    log "正在移除节点信息文件..."
    rm -f "$NODE_INFO_FILE"
    
    success "卸载完成！"
}


# 主菜单 (修改极速模式为简化模式)
main_menu() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Sing-box VLESS + Reality + 内置 Argo    ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}     特点: 更低内存，更高效率 (需要 Argo Token)  ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}请选择操作:${NC}"
    echo -e "${BLUE}1) 简化模式 - 快速配置，必填 Argo Token/域名${NC}"
    echo -e "${BLUE}2) 完整模式 - 自定义配置项，必填 Argo Token/域名${NC}"
    echo -e "${BLUE}3) 查看节点信息 - 显示已保存的节点${NC}"
    echo -e "${RED}4) 卸载脚本 - 移除所有相关文件和服务${NC}"
    echo
    read -p "请输入选择 (1/2/3/4): " MODE_CHOICE

    case $MODE_CHOICE in
        1) simplified_mode ;;
        2) full_mode ;;
        3) view_node_info; exit 0 ;;
        4) uninstall_service; exit 0 ;;
        *) error "无效输入，请输入 1-4 之间的数字。" ;;
    esac
}

# --- 脚本入口 ---
if [ "$1" = "-v" ]; then
    view_node_info
    exit 0
fi

main_menu
