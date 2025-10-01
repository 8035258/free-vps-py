#!/bin/bash

# --- 颜色和样式 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 静态变量 ---
NODE_INFO_FILE="$HOME/.singbox_vless_node_info"
INSTALL_PATH="/etc/sing-box"
CONFIG_FILE="${INSTALL_PATH}/config.json"
SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_URL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download/"
# 内部sing-box服务监听的端口
SINGBOX_PORT="8001" 

# --- 全局变量 (由用户输入或默认值填充) ---
UUID=""
NODE_NAME="VLESS-Argo-Singbox"
CFIP="cloudflare.182682.xyz"
CFPORT="443"
ARGO_DOMAIN=""
ARGO_AUTH=""
INIT_SYSTEM="" # 用于记录系统初始化系统 (systemd/openrc)


# =================================================================
# --- 核心功能函数 ---
# =================================================================

# 打印日志
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
# 打印成功信息
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
# 打印警告信息
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
# 打印错误信息
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查Linux发行版、包管理器和初始化系统
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
            PKG_MANAGER="apt"
        elif [ "$OS" == "centos" ] || [ "$OS" == "fedora" ] || [ "$OS" == "rhel" ]; then
            PKG_MANAGER="yum"
        elif [ "$OS" == "alpine" ]; then
            PKG_MANAGER="apk"
        else
            error "不支持的操作系统：$OS"
        fi
    else
        error "无法确定操作系统类型"
    fi
    
    # 检查初始化系统
    if command -v systemctl &> /dev/null; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &> /dev/null; then
        INIT_SYSTEM="openrc"
    else
        warn "未检测到 systemd 或 openrc，服务将无法自动管理。请手动配置。"
    fi
}

# 安装依赖
install_dependencies() {
    log "正在安装依赖：curl, tar, unzip, $INIT_SYSTEM 相关工具..."
    
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt update >/dev/null 2>&1
        apt -y install curl tar gzip unzip systemd >/dev/null 2>&1
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum -y install curl tar gzip unzip systemd >/dev/null 2>&1
    elif [ "$PKG_MANAGER" == "apk" ]; then
        apk update >/dev/null 2>&1
        apk add curl tar gzip unzip openrc >/dev/null 2>&1
    fi
    
    # 再次确认关键工具
    if ! command -v curl &> /dev/null || ! command -v tar &> /dev/null || ! command -v unzip &> /dev/null; then
        error "无法安装必要的依赖 (curl, tar, unzip)，请手动安装后重试。"
    fi
    
    success "依赖安装完成。"
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

# 下载 Sing-box (最终修复下载逻辑)
download_singbox() {
    log "正在下载 Sing-box 二进制文件..."
    local version_tag=$(get_latest_version "SagerNet/sing-box") # 例如 v1.12.8
    local version_num=$(echo "$version_tag" | sed 's/^v//') # 移除 v 前缀，例如 1.12.8

    local arch=$(uname -m)
    local arch_pattern=""
    case $arch in
        x86_64) arch_pattern="linux-amd64" ;;
        aarch64) arch_pattern="linux-arm64" ;;
        armv7l) arch_pattern="linux-armv7" ;;
        i686) arch_pattern="linux-386" ;;
        *) error "不支持的架构：$arch" ;;
    esac

    # 核心修复：文件名通常不带 v
    local file_name="sing-box-${version_num}-${arch_pattern}.tar.gz" 
    
    # 路径使用完整的 version_tag (带 v)
    local url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/${file_name}"
    
    log "尝试下载链接 (不带v的文件名): $url"
    
    # 使用 -f 确保失败时 curl 返回非 0 状态
    if ! curl -fL "$url" -o sing-box.tar.gz; then
        # 再次尝试一种备用命名 (文件名也带 v)
        file_name="sing-box-${version_tag}-${arch_pattern}.tar.gz"
        url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/${file_name}"
        log "尝试备用链接 (带v的文件名): $url"
        
        if ! curl -fL "$url" -o sing-box.tar.gz; then
            rm -f sing-box.tar.gz
            error "下载 Sing-box 失败，请检查网络或 URL。"
        fi
    fi

    # 尝试解压
    if ! tar -xzf sing-box.tar.gz; then
        rm -f sing-box.tar.gz
        error "解压 Sing-box 文件失败。下载的文件可能已损坏。"
    fi
    
    # 查找并移动 sing-box 可执行文件
    local success_move=false
    # 确保文件夹名是干净的
    local extracted_dir=$(tar -tf sing-box.tar.gz | head -n 1 | awk -F/ '{print $1}')
    
    if [ -f "${extracted_dir}/sing-box" ]; then
        mv "${extracted_dir}/sing-box" "$SINGBOX_BIN"
        success_move=true
    fi

    if ! $success_move; then
        rm -rf sing-box.tar.gz "${extracted_dir}"
        error "在压缩包中找不到 sing-box 可执行文件。"
    fi

    chmod +x "$SINGBOX_BIN"
    rm -rf sing-box.tar.gz "${extracted_dir}"
    success "Sing-box ${version_tag} 安装完成。"
}

# 下载 cloudflared
download_cloudflared() {
    log "正在下载 cloudflared 二进制文件..."
    local arch=$(uname -m)
    local file_name=""
    case $arch in
        x86_64) file_name="cloudflared-linux-amd64" ;;
        aarch64) file_name="cloudflared-linux-arm64" ;;
        armv7l) file_name="cloudflared-linux-arm" ;;
        i686) file_name="cloudflared-linux-386" ;;
        *) error "不支持的架构：$arch" ;;
    esac

    local url="${CLOUDFLARED_URL_BASE}${file_name}"
    
    if ! curl -fL "$url" -o "$CLOUDFLARED_BIN"; then
        error "下载 cloudflared 失败，请检查网络或 URL。"
    fi

    chmod +x "$CLOUDFLARED_BIN"
    success "cloudflared 安装完成。"
}


# 生成 Sing-box 配置 (VLESS + WS 监听本地端口)
generate_singbox_config() {
    log "正在生成 Sing-box 配置文件..."
    
    # 确保路径中 / 是被转义的
    local WS_PATH="/${UUID}-path"
    
    # VLESS + WS 监听本地环回地址和端口
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
      "stream_options": {
        "network": "ws",
        "security": "none",
        "ws_options": {
          "path": "$WS_PATH",
          "headers": {
            "Host": "$ARGO_DOMAIN"
          }
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
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "vless-in",
        "outbound": "direct"
      }
    ]
  }
}
EOF
    success "Sing-box 配置生成完成，监听端口: $SINGBOX_PORT"
}

# 安装和启用服务 (兼容 Systemd 和 OpenRC)
install_and_enable_service() {
    local service_name="$1"
    local exec_command="$2"
    local after_target="$3" # Systemd only
    local openrc_args="$4" # OpenRC only

    if [ "$INIT_SYSTEM" == "systemd" ]; then
        log "正在创建和安装 ${service_name}.service (Systemd)..."
        cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=${service_name} Service
After=network.target ${after_target}

[Service]
Type=simple
ExecStart=${exec_command}
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${service_name}.service" >/dev/null 2>&1
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        log "正在创建和安装 ${service_name} (OpenRC)..."
        # 针对 OpenRC 系统的服务脚本
        cat > "/etc/init.d/${service_name}" <<EOF
#!/sbin/openrc-run

name="${service_name} Service"
# 修复：直接将完整的命令包含在 command 变量中，避免 start-stop-daemon 将参数视为自己的选项
command="${exec_command} ${openrc_args}"
command_args=""
pidfile="/var/run/${service_name}.pid"
depend() {
    need localmount net
    # OpenRC 依赖设置
    if [ "$service_name" == "cloudflared" ]; then
        use sing-box
    fi
}
EOF
        chmod +x "/etc/init.d/${service_name}"
        rc-update add "${service_name}" default >/dev/null 2>&1
    else
        warn "未找到初始化系统，跳过服务安装。"
        return 1
    fi
    success "${service_name} 服务安装完成。"
}


# 启动服务
start_services() {
    log "正在启动 Sing-box 服务..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl start sing-box.service
        systemctl start cloudflared.service
        sleep 3 # 等待服务启动
        if systemctl is-active --quiet sing-box.service && systemctl is-active --quiet cloudflared.service; then
            success "Sing-box 和 cloudflared 服务已成功启动！"
        else
            error "服务启动失败，请检查日志 (journalctl -u sing-box.service / cloudflared.service)"
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service sing-box start
        rc-service cloudflared start
        sleep 3
        # OpenRC 状态检查
        if rc-service sing-box status | grep -q "status: started" && rc-service cloudflared status | grep -q "status: started"; then
            success "Sing-box 和 cloudflared 服务已成功启动！"
        else
            error "服务启动失败，请检查日志 (/var/log/messages 或 /var/log/syslog)。如果日志不清楚，请尝试手动运行命令：$SINGBOX_BIN run -C $INSTALL_PATH 和 $CLOUDFLARED_BIN tunnel --no-autoupdate --token $ARGO_AUTH --url http://127.0.0.1:$SINGBOX_PORT"
        fi
    else
        warn "请手动运行服务: $SINGBOX_BIN run -C $INSTALL_PATH 和 $CLOUDFLARED_BIN tunnel --no-autoupdate --token $ARGO_AUTH --url http://127.0.0.1:$SINGBOX_PORT"
    fi
}

# 生成 VLESS 配置链接
generate_vless_link() {
    local url_path="/$UUID-path"
    local vless_link_tls="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&type=ws&host=${ARGO_DOMAIN}&path=${url_path}#${NODE_NAME}_TLS"
    local vless_link_non_tls="vless://${UUID}@${CFIP}:80?encryption=none&security=none&type=ws&host=${ARGO_DOMAIN}&path=${url_path}#${NODE_NAME}_Non_TLS"

    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      VLESS + Argo 节点信息 (Token 模式)    ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${YELLOW}节点名称:${NC} $NODE_NAME"
    echo -e "${YELLOW}目标域名 (Host):${NC} $ARGO_DOMAIN"
    echo -e "${YELLOW}Path:${NC} $url_path"
    echo -e "${YELLOW}UUID:${NC} $UUID"
    echo

    echo -e "${BLUE}--- 1. 推荐链接 (TLS / 端口 443) ---${NC}"
    echo -e "$vless_link_tls"
    echo -e "\n${BLUE}--- 2. 非加密链接 (Non-TLS / 端口 80) ---${NC}"
    echo -e "注意: 客户端需关闭TLS，Cloudflare SSL/TLS 边缘证书 '始终使用HTTPS' 需关闭。"
    echo -e "$vless_link_non_tls"
    echo
    echo -e "信息已保存到 ${NODE_INFO_FILE}"
    
    # 保存节点信息
    cat > "$NODE_INFO_FILE" <<EOF
节点名称: $NODE_NAME
Argo 域名: $ARGO_DOMAIN
Argo Token: $ARGO_AUTH
UUID: $UUID
本地监听端口: $SINGBOX_PORT

VLESS 链接 (TLS):
$vless_link_tls

VLESS 链接 (Non-TLS):
$vless_link_non_tls
EOF
}

# 收集用户输入
collect_user_input() {
    # 1. UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "${YELLOW}生成的 UUID: ${GREEN}$UUID${NC}"
    read -p "是否使用此 UUID？(y/n，默认 y): " use_default_uuid
    if [[ "$use_default_uuid" == [nN] ]]; then
        read -p "请输入自定义 UUID: " UUID
    fi
    [ -z "$UUID" ] && error "UUID 不能为空！"

    # 2. Argo 域名
    echo
    echo -e "${YELLOW}接下来需要输入您的 Cloudflare 域名配置。${NC}"
    echo -e "您必须预先在 Cloudflare 创建 Tunnel 并将其 CNAME 记录指向您的域名。"
    read -p "请输入您的自定义 Argo 域名 (例如: vless.example.com): " ARGO_DOMAIN
    [ -z "$ARGO_DOMAIN" ] && error "Argo 域名不能为空！"

    # 3. Argo Token
    echo -e "Argo Token 可以在 Cloudflare Tunnel 管理界面找到。"
    read -p "请输入您的 Argo Tunnel Token: " ARGO_AUTH
    [ -z "$ARGO_AUTH" ] && error "Argo Token 不能为空！"
    
    # 4. 节点名称
    echo
    read -p "请输入节点名称 (默认: $NODE_NAME): " input_name
    [ -n "$input_name" ] && NODE_NAME="$input_name"
    
    # 5. CF 优选 IP
    echo
    read -p "请输入 VLESS 客户端使用的 Cloudflare 优选 IP (默认: $CFIP): " input_cfip
    [ -n "$input_cfip" ] && CFIP="$input_cfip"
}

# 安装主函数
install_node() {
    # 0. 检查系统并安装依赖
    check_os
    install_dependencies
    
    # 1. 收集用户输入
    collect_user_input

    # 2. 下载二进制文件 
    download_singbox
    download_cloudflared

    # 3. 创建配置目录
    mkdir -p "$INSTALL_PATH"

    # 4. 生成配置
    generate_singbox_config
    
    # 5. 安装服务 (已兼容 OpenRC 和 Systemd)
    # OpenRC Sing-box 参数修复：必须明确指定 -C 配置目录
    install_and_enable_service "sing-box" "$SINGBOX_BIN" "network.target" "run -C $INSTALL_PATH"
    
    # OpenRC Cloudflared 参数修复：将完整的启动命令合并到 command 变量中
    local cloudflared_command="$CLOUDFLARED_BIN tunnel --no-autoupdate --token $ARGO_AUTH --url http://127.0.0.1:$SINGBOX_PORT"
    install_and_enable_service "cloudflared" "$CLOUDFLARED_BIN" "sing-box.service" "tunnel --no-autoupdate --token $ARGO_AUTH --url http://127.0.0.1:$SINGBOX_PORT"
    
    # 6. 启动服务
    start_services

    # 7. 显示 VLESS 链接
    generate_vless_link
}


# 卸载服务
uninstall_node() {
    check_os
    log "正在停止并禁用服务..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl stop sing-box.service cloudflared.service &>/dev/null
        systemctl disable sing-box.service cloudflared.service &>/dev/null
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service sing-box stop &>/dev/null
        rc-service cloudflared stop &>/dev/null
        rc-update del sing-box default &>/dev/null
        rc-update del cloudflared default &>/dev/null
        rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
    fi
    
    log "正在移除二进制文件..."
    rm -f "$SINGBOX_BIN" "$CLOUDFLARED_BIN"
    
    log "正在移除配置文件目录..."
    rm -rf "$INSTALL_PATH"
    
    log "正在移除节点信息文件..."
    rm -f "$NODE_INFO_FILE"
    
    success "卸载完成！"
    warn "注意: Argo Tunnel Token 和配置信息（如 ~/.cloudflared/ 目录）可能仍存在，请手动清理。"
}

# =================================================================
# --- 主菜单 ---
# =================================================================
main_menu() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Sing-box + Argo VLESS (Token 模式) 部署  ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}请选择操作:${NC}"
    echo -e "${BLUE}1) 安装 / 重新安装 VLESS + Argo (Token 模式)${NC}"
    echo -e "${BLUE}2) 卸载服务${NC}"
    echo -e "${BLUE}3) 查看节点信息${NC}"
    echo -e "${BLUE}4) 退出${NC}"
    echo
    read -p "请输入选项 (默认 1): " choice
    [ -z "$choice" ] && choice=1

    case $choice in
        1) 
            # 兼容性处理：如果文件已存在，先卸载以避免服务冲突
            if [ -f "/etc/init.d/sing-box" ] || [ -f "/etc/systemd/system/sing-box.service" ]; then
                warn "检测到旧服务文件，正在进行卸载..."
                check_os
                uninstall_node
            fi
            install_node 
            ;;
        2) 
            check_os
            uninstall_node 
            ;;
        3) 
            if [ -f "$NODE_INFO_FILE" ]; then
                clear
                cat "$NODE_INFO_FILE"
            else
                warn "节点信息文件不存在，请先安装服务。"
            fi
            ;;
        4) success "退出脚本。"; exit 0 ;;
        *) error "无效的选项。" ;;
    esac
}

main_menu
