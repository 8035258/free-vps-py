#!/bin/bash

# --- 颜色和样式 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 静态变量 ---
NODE_INFO_FILE="$HOME/.xray_vless_node_info"
INSTALL_PATH="/etc/xray"
CONFIG_FILE="${INSTALL_PATH}/config.json"
XRAY_BIN="/usr/local/bin/xray"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
XRAY_URL_BASE="https://github.com/XTLS/Xray-core/releases/latest/download/"
CLOUDFLARED_URL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download/"
# 内部Xray服务监听的端口
XRAY_PORT="8001" 

# --- 全局变量 (由用户输入或默认值填充) ---
UUID=""
NODE_NAME="VLESS-Argo"
CFIP="cloudflare.182682.xyz"
CFPORT="443"
ARGO_DOMAIN=""
ARGO_AUTH=""


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

    # 将 CentOS/Fedora 的 ID 归类到 RHEL 家族，以便在 install_dependencies 中处理
    case "$OS_ID" in
        centos|rhel|fedora)
            OS_ID="rhel"
            log "已将操作系统 ID 归类为: $OS_ID"
            ;;
        debian|ubuntu|alpine)
            # 保持不变
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

# 安装依赖
install_dependencies() {
    log "正在更新软件包列表并安装依赖..."
    case $OS_ID in
        alpine)
            apk update && apk add --no-cache curl wget unzip bash jq
            ;;
        debian | ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update && apt-get install -y curl wget unzip bash jq uuid-runtime
            ;;
        rhel) # 新增的 RHEL/CentOS/Fedora 分支
            # 优先尝试 dnf，如果不存在则使用 yum
            if command -v dnf &> /dev/null; then
                log "使用 dnf 安装依赖..."
                dnf install -y curl wget unzip bash jq uuidgen
            elif command -v yum &> /dev/null; then
                log "使用 yum 安装依赖..."
                yum install -y curl wget unzip bash jq uuidgen
            else
                error "未找到 dnf 或 yum 包管理器。"
            fi
            ;;
        *)
            warn "无法识别的操作系统: $OS_ID, 脚本将继续，但请确保已手动安装 curl, wget, unzip, bash, jq"
            ;;
    esac
    [[ $? -ne 0 ]] && error "依赖安装失败。"
    success "依赖安装完成。"
}

# 停止并禁用旧服务
stop_and_disable_services() {
    log "正在停止并禁用可能存在的旧服务..."
    if command -v systemctl &> /dev/null; then
        systemctl stop xray cloudflared &>/dev/null
        systemctl disable xray cloudflared &>/dev/null
    elif command -v rc-service &> /dev/null; then
        rc-service xray stop &>/dev/null
        rc-service cloudflared stop &>/dev/null
        rc-update del xray default &>/dev/null
        rc-update del cloudflared default &>/dev/null
    fi
}

# 下载并安装二进制文件
download_and_install() {
    local name="$1"
    local bin_path="$2"
    local base_url="$3"
    local file_pattern="$4"

    local download_url="${base_url}${file_pattern}"
    
    log "正在下载 $name..."
    wget -q -O "/tmp/$name.dl" "$download_url"
    [[ $? -ne 0 ]] && error "$name 下载失败。 URL: $download_url"

    if [[ "$file_pattern" == *.zip ]]; then
        log "正在解压并安装 $name..."
        unzip -q -o "/tmp/$name.dl" -d /tmp/install_temp
        # Xray zip 包解压后可能直接是 xray 或 Xray
        if [ -f "/tmp/install_temp/xray" ]; then
            mv "/tmp/install_temp/xray" "$bin_path"
        elif [ -f "/tmp/install_temp/Xray" ]; then
            mv "/tmp/install_temp/Xray" "$bin_path"
        else
            error "在下载的 Xray zip 包中未找到可执行文件。"
        fi
    else
        log "正在安装 $name..."
        mv "/tmp/$name.dl" "$bin_path"
    fi

    chmod +x "$bin_path"
    rm -rf /tmp/install_temp /tmp/$name.dl
    success "$name 安装完成。"
}

# 创建 Xray 配置文件
create_config_file() {
    log "正在创建 Xray 配置文件..."
    mkdir -p "$INSTALL_PATH"
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
    success "配置文件创建完成: $CONFIG_FILE"
}

# 创建并启用服务
create_and_enable_service() {
    log "正在创建并启用服务..."
    
    # 根据是否提供了Argo Token决定cloudflared的启动命令
    if [[ -n "$ARGO_AUTH" ]]; then
        # 使用永久隧道Token
        CLOUDFLARED_EXEC="${CLOUDFLARED_BIN} tunnel --no-autoupdate run --token ${ARGO_AUTH}"
    else
        # 使用临时隧道
        CLOUDFLARED_EXEC="${CLOUDFLARED_BIN} tunnel --no-autoupdate --url http://127.0.0.1:${XRAY_PORT}"
    fi

    # 整合 Debian, Ubuntu, CentOS, Fedora (RHEL) 的 systemd 支持
    if [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "rhel" ]; then
        # --- 创建 systemd 服务 (适用于 Debian/Ubuntu/CentOS/Fedora) ---
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=${CLOUDFLARED_EXEC}
Restart=on-failure
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray cloudflared
        systemctl restart xray cloudflared
    elif [ "$OS_ID" = "alpine" ]; then
        # --- 创建 Alpine (OpenRC) 服务 ---
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
supervisor=supervise-daemon
command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
pidfile="/run/\${RC_SVCNAME}.pid"
name="xray"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray
        cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
supervisor=supervise-daemon
command="${CLOUDFLARED_BIN}"
command_args="tunnel --no-autoupdate run --token ${ARGO_AUTH}"
pidfile="/run/\${RC_SVCNAME}.pid"
name="cloudflared"
depend() { need net; }
EOF
        chmod +x /etc/init.d/cloudflared
        rc-update add xray default
        rc-update add cloudflared default
        rc-service xray restart >/dev/null 2>&1 &
        rc-service cloudflared restart >/dev/null 2>&1 &
    fi
    success "服务创建并启动成功。"
}

# 显示并保存结果
show_and_save_result() {
    local final_domain="$ARGO_DOMAIN"
    local systemd_system=false

    if [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "rhel" ]; then
        systemd_system=true
    fi

    if [[ -z "$final_domain" ]]; then
        log "使用临时隧道，正在获取隧道域名..."
        sleep 10 # 等待cloudflared启动并生成日志

        if $systemd_system; then
            TUNNEL_URL=$(journalctl -u cloudflared -n 20 --no-pager | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -n 1)
        elif [ "$OS_ID" = "alpine" ]; then
             TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/messages /var/log/cloudflared.log 2>/dev/null | tail -n 1)
        fi
        
        # 重试机制
        retries=0
        while [ -z "$TUNNEL_URL" ] && [ $retries -lt 5 ]; do
            warn "未能获取到域名，5秒后重试... (尝试次数: $((retries+1)))"
            sleep 5
            if $systemd_system; then
                TUNNEL_URL=$(journalctl -u cloudflared -n 20 --no-pager | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -n 1)
            else
                TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/messages /var/log/cloudflared.log 2>/dev/null | tail -n 1)
            fi
            ((retries++))
        done
        
        [[ -z "$TUNNEL_URL" ]] && error "无法获取 Cloudflare Tunnel 域名，请检查 cloudflared 服务状态和日志。"
        final_domain=$(echo "$TUNNEL_URL" | sed 's|https://||')
    fi
    
    success "获取到的域名: $final_domain"

    # 生成 VLESS 链接
    VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${final_domain}&fp=chrome&type=ws&host=${final_domain}&path=/#${NODE_NAME}" 
    
    # 准备保存到文件的信息
    SAVE_INFO="========================================
           节点信息 (VLESS)
========================================
部署时间: $(date)
节点名称: ${NODE_NAME}
UUID: ${UUID}
优选IP: ${CFIP}
优选端口: ${CFPORT}
隧道域名: ${final_domain}
----------------------------------------
VLESS 链接:
${VLESS_LINK}
----------------------------------------
管理命令:
查看节点: bash $0 -v
重启服务 (systemd): systemctl restart xray cloudflared
重启服务 (OpenRC): rc-service xray restart && rc-service cloudflared restart
查看日志 (systemd): journalctl -u xray -f & journalctl -u cloudflared -f
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
    # 从文件中打印信息，确保一致性
    cat "$NODE_INFO_FILE"
    echo
    success "感谢使用！"
}


# =================================================================
# --- 交互式菜单和安装流程 ---
# =================================================================

# 极速模式
quick_mode() {
    clear
    echo -e "${BLUE}=== 极速模式 ===${NC}"
    read -p "请输入您的 UUID (留空将自动生成): " UUID_INPUT
    UUID=${UUID_INPUT:-$(generate_uuid)}
    success "UUID 已设置为: $UUID"
    
    # 使用默认值
    NODE_NAME="VLESS-Argo-Quick"
    CFIP="cloudflare.182682.xyz"
    CFPORT="443"
    ARGO_DOMAIN=""
    ARGO_AUTH=""
    
    run_installation
}

# 完整模式
full_mode() {
    clear
    echo -e "${BLUE}=== 完整配置模式 ===${NC}"
    read -p "请输入您的 UUID (留空将自动生成): " UUID_INPUT
    UUID=${UUID_INPUT:-$(generate_uuid)}
    success "UUID 已设置为: $UUID"

    read -p "请输入节点名称 [默认: VLESS-Argo]: " NODE_NAME_INPUT
    NODE_NAME=${NODE_NAME_INPUT:-"VLESS-Argo"}

    read -p "请输入优选IP/域名 [默认: cloudflare.182682.xyz]: " CFIP_INPUT
    CFIP=${CFIP_INPUT:-"cloudflare.182682.xyz"}

    read -p "请输入优选端口 [默认: 443]: " CFPORT_INPUT
    CFPORT=${CFPORT_INPUT:-"443"}

    echo
    warn "如果您有 Cloudflare Argo 隧道的固定 Token，请输入它。"
    warn "这将创建一个永久隧道，无需每次启动都生成新域名。"
    warn "留空则使用临时的 trycloudflare.com 域名。"
    read -p "请输入 Argo Tunnel Token (留空使用临时隧道): " ARGO_AUTH_INPUT
    ARGO_AUTH=${ARGO_AUTH_INPUT}
    
    if [[ -n "$ARGO_AUTH" ]]; then
        warn "由于您使用了 Argo Token，您需要提供一个已在Cloudflare上配置好的域名。"
        read -p "请输入与该Token关联的域名 (必须填写): " ARGO_DOMAIN_INPUT
        [[ -z "$ARGO_DOMAIN_INPUT" ]] && error "使用Argo Token时必须提供固定域名。"
        ARGO_DOMAIN=${ARGO_DOMAIN_INPUT}
    fi
    
    run_installation
}

# 运行实际安装流程
run_installation() {
    echo -e "${GREEN}=== 开始部署 ===${NC}"
    check_root
    detect_os_arch
    install_dependencies
    stop_and_disable_services
    download_and_install "xray" "$XRAY_BIN" "$XRAY_URL_BASE" "Xray-linux-64.zip"
    download_and_install "cloudflared" "$CLOUDFLARED_BIN" "$CLOUDFLARED_URL_BASE" "cloudflared-linux-${ARCH}"
    create_config_file
    create_and_enable_service
    show_and_save_result
}

# 卸载脚本
uninstall_service() {
    clear
    echo -e "${RED}=== 卸载脚本 ===${NC}"
    warn "这将从系统中移除 Xray, Cloudflared 以及所有相关配置文件和服务。"
    read -p "您确定要继续吗? (y/N): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}卸载已取消。${NC}"
        exit 0
    fi

    check_root
    detect_os_arch
    
    log "正在停止并禁用服务..."
    # 整合 systemd 服务的停止和移除 (Debian/Ubuntu/CentOS/Fedora)
    if command -v systemctl &> /dev/null && ([ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "rhel" ]); then
        systemctl stop xray cloudflared &>/dev/null
        systemctl disable xray cloudflared &>/dev/null
        log "正在移除 systemd 服务文件..."
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
        log "正在重新加载 systemd..."
        systemctl daemon-reload
    elif command -v rc-service &> /dev/null; then
        rc-service xray stop &>/dev/null
        rc-service cloudflared stop &>/dev/null
        rc-update del xray default &>/dev/null
        rc-update del cloudflared default &>/dev/null
        log "正在移除 OpenRC 服务文件..."
        rm -f /etc/init.d/xray /etc/init.d/cloudflared
    fi
    
    log "正在移除二进制文件..."
    rm -f "$XRAY_BIN" "$CLOUDFLARED_BIN"
    
    log "正在移除配置文件目录..."
    rm -rf "$INSTALL_PATH"
    
    log "正在移除节点信息文件..."
    rm -f "$NODE_INFO_FILE"
    
    success "卸载完成！"
    warn "请注意，脚本依赖 (如 curl, wget, jq) 未被卸载，因为它们可能被其他程序使用。"
}


# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      Xray + Argo VLESS 一键部署脚本     ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    支持系统: Debian/Ubuntu/CentOS/Fedora/Alpine  ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}请选择操作:${NC}"
    echo -e "${BLUE}1) 极速模式 - 自动配置，快速部署 (临时域名)${NC}"
    echo -e "${BLUE}2) 完整模式 - 自定义配置项 (推荐 Argo Token)${NC}"
    echo -e "${BLUE}3) 查看节点信息 - 显示已保存的节点${NC}"
    echo -e "${RED}4) 卸载脚本 - 移除所有相关文件和服务${NC}"
    echo
    read -p "请输入选择 (1/2/3/4): " MODE_CHOICE

    case $MODE_CHOICE in
        1) quick_mode ;;
        2) full_mode ;;
        3) view_node_info; exit 0 ;;
        4) uninstall_service; exit 0 ;;
        *) error "无效输入，请输入 1-4 之间的数字。" ;;
    esac
}

# --- 脚本入口 ---
# 如果提供了 -v 参数，直接查看节点信息
if [ "$1" = "-v" ]; then
    view_node_info
    exit 0
fi

main_menu
