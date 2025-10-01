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
    log "正在安装依赖：curl, tar, gzip, unzip, $INIT_SYSTEM 相关工具..."

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


# 生成 Sing-box 配置
generate_singbox_config() {
    log "正在生成 Sing-box 配置文件..."
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

# 安装和启用服务
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
ExecStart=${exec_command} ${openrc_args}
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
        cat > "/etc/init.d/${service_name}" <<EOF
#!/sbin/openrc-run

name="${service_name} Service"
command="$exec_command"
command_args="$openrc_args"
pidfile="/var/run/${service_name}.pid"

depend() {
    need net
    use dns
    after net dns
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
    log "正在启动 Sing-box 和 cloudflared 服务..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl restart sing-box.service
        systemctl restart cloudflared.service
        sleep 3
        if systemctl is-active --quiet sing-box.service && systemctl is-active --quiet cloudflared.service; then
            success "Sing-box 和 cloudflared 服务已成功启动！"
        else
            error "服务启动失败，请检查日志 (journalctl -u sing-box.service / journalctl -u cloudflared.service)"
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service sing-box stop >/dev/null 2>&1
        rc-service cloudflared stop >/dev/null 2>&1

        log "正在启动 sing-box..."
        rc-service sing-box start
        sleep 2
        if ! rc-service sing-box status | grep -q "status: started"; then
             error "Sing-box 服务启动失败。请手动运行命令检查: ${SINGBOX_BIN} run -C ${INSTALL_PATH}"
        fi
        success "Sing-box 服务已启动。"

        log "正在启动 cloudflared..."
        rc-service cloudflared start
        sleep 2
        if ! rc-service cloudflared status | grep -q "status: started"; then
            error "Cloudflared 服务启动失败。请手动运行命令检查: ${CLOUDFLARED_BIN} tunnel --no-autoupdate --token ${ARGO_AUTH:0:10}... --url http://127.0.0.1:${SINGBOX_PORT}"
        fi
        success "Cloudflared 服务已启动。"

        success "所有服务已成功启动！"
    else
        warn "请手动运行服务: ${SINGBOX_BIN} run -C ${INSTALL_PATH} 和 ${CLOUDFLARED_BIN} tunnel --no-autoupdate --token ${ARGO_AUTH} --url http://127.0.0.1:${SINGBOX_PORT}"#!/bin/bash

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
    log "正在安装依赖：curl, tar, gzip, unzip, $INIT_SYSTEM 相关工具..."

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


# 生成 Sing-box 配置
generate_singbox_config() {
    log "正在生成 Sing-box 配置文件..."
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

# 安装和启用服务
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
ExecStart=${exec_command} ${openrc_args}
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
        cat > "/etc/init.d/${service_name}" <<EOF
#!/sbin/openrc-run

name="${service_name} Service"
command="$exec_command"
command_args="$openrc_args"
pidfile="/var/run/${service_name}.pid"

depend() {
    need net
    use dns
    after net dns
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
    log "正在启动 Sing-box 和 cloudflared 服务..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl restart sing-box.service
        systemctl restart cloudflared.service
        sleep 3
        if systemctl is-active --quiet sing-box.service && systemctl is-active --quiet cloudflared.service; then
            success "Sing-box 和 cloudflared 服务已成功启动！"
        else
            error "服务启动失败，请检查日志 (journalctl -u sing-box.service / journalctl -u cloudflared.service)"
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service sing-box stop >/dev/null 2>&1
        rc-service cloudflared stop >/dev/null 2>&1

        log "正在启动 sing-box..."
        rc-service sing-box start
        sleep 2
        if ! rc-service sing-box status | grep -q "status: started"; then
             error "Sing-box 服务启动失败。请手动运行命令检查: ${SINGBOX_BIN} run -C ${INSTALL_PATH}"
        fi
        success "Sing-box 服务已启动。"

        log "正在启动 cloudflared..."
        rc-service cloudflared start
        sleep 2
        if ! rc-service cloudflared status | grep -q "status: started"; then
            error "Cloudflared 服务启动失败。请手动运行命令检查: ${CLOUDFLARED_BIN} tunnel --no-autoupdate --token ${ARGO_AUTH:0:10}... --url http://127.0.0.1:${SINGBOX_PORT}"
        fi
        success "Cloudflared 服务已启动。"

        success "所有服务已成功启动！"
    else
        warn "请手动运行服务: ${SINGBOX_BIN} run -C ${INSTALL_PATH} 和 ${CLOUDFLARED_BIN} tunnel --no-autoupdate --token ${ARGO_AUTH} --url http://127.0.0.1:${SINGBOX_PORT}"
