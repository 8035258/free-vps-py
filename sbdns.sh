#!/bin/bash

# --- 颜色和样式 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 静态变量 (修改为用户可写路径) ---
NODE_INFO_FILE="$HOME/.singbox_vless_node_info"
INSTALL_PATH="$HOME/sing-box-config"
CONFIG_FILE="${INSTALL_PATH}/config.json"
# 二进制文件安装在 HOME 目录
SINGBOX_BIN="$HOME/bin/sing-box"
CLOUDFLARED_BIN="$HOME/bin/cloudflared" 
CLOUDFLARED_URL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download/"
# 内部sing-box服务监听的端口
SINGBOX_PORT="8001"
LOG_FILE="$HOME/run.log" # 新增日志文件

# --- 全局变量 (由用户输入或默认值填充) ---
UUID=""
NODE_NAME="VLESS-Argo-Singbox"
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
        # 在没有 uuidgen 或 python 的情况下，使用 /proc/sys/kernel/random/uuid (通用)
        cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "ffffffff-ffff-ffff-ffff-ffffffffffff"
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

# 移除 check_root 函数，因为不再需要

# 检测操作系统和架构
detect_os_arch() {
    case $(uname -m) in
        x86_64 | amd64) ARCH="amd64" ;;
        aarch64 | arm64) ARCH="arm64" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
    log "检测到系统架构: $ARCH"
}

# 移除 install_dependencies 函数，依赖假设已安装或容器环境自带

# 停止旧进程 (非 root 环境)
stop_old_processes() {
    log "正在尝试停止可能存在的旧 sing-box 和 cloudflared 进程..."
    # 使用 pkill 停止后台进程
    pkill -f "$SINGBOX_BIN" >/dev/null 2>&1 || true
    pkill -f "$CLOUDFLARED_BIN" >/dev/null 2>&1 || true
    success "旧进程清理完成。"
}

# 下载并安装二进制文件 (修改安装路径)
download_and_install() {
    local name="$1"
    local bin_path="$2"
    local download_url="$3"
    local file_type="${4:-bin}"

    mkdir -p "$(dirname "$bin_path")" # 确保 $HOME/bin 存在

    log "正在下载 $name..."
    wget -q -O "/tmp/$name.dl" "$download_url"
    [[ $? -ne 0 ]] && error "$name 下载失败。 URL: $download_url"

    if [[ "$file_type" == "tar.gz" ]]; then
        log "正在解压并安装 $name..."
        mkdir -p /tmp/install_temp
        tar -xzf "/tmp/$name.dl" -C /tmp/install_temp
        local found_bin=$(find /tmp/install_temp -type f -name "$name")
        if [[ -n "$found_bin" ]]; then
            mv "$found_bin" "$bin_path"
        else
            error "在下载的 $name 压缩包中未找到可执行文件。"
        fi
    else
        log "正在安装 $name..."
        mv "/tmp/$name.dl" "$bin_path"
    fi

    chmod +x "$bin_path"
    rm -rf /tmp/install_temp /tmp/$name.dl
    success "$name 安装完成。"
}

# 创建 sing-box 配置文件 (DNS 配置保持不变)
create_config_file() {
    log "正在创建 sing-box 配置文件..."
    mkdir -p "$INSTALL_PATH"
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns_servers",
        "address": "1.1.1.1",
        "detour": "direct"
      },
      {
        "tag": "dns_backup",
        "address": "8.8.8.8",
        "detour": "direct"
      }
    ],
    "final": "dns_servers",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": ${SINGBOX_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "type": "dns",
        "outbound_tag": "dns-out"
      }
    ],
    "final": "direct"
  }
}
EOF
    success "配置文件创建完成: $CONFIG_FILE"
}

# 启动服务 (使用后台命令，无需 root 权限)
start_services_no_root() {
    log "正在启动 sing-box 和 cloudflared 进程..."

    # 1. 启动 sing-box
    nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    SINGBOX_PID=$!
    log "Sing-box 进程 ID: $SINGBOX_PID"

    # 2. 启动 cloudflared
    local CLOUDFLARED_EXEC
    if [[ -n "$ARGO_AUTH" ]]; then
        CLOUDFLARED_EXEC="${CLOUDFLARED_BIN} tunnel --no-autoupdate run --token ${ARGO_AUTH}"
    else
        CLOUDFLARED_EXEC="${CLOUDFLARED_BIN} tunnel --no-autoupdate --url http://127.0.0.1:${SINGBOX_PORT}"
    fi

    nohup $CLOUDFLARED_EXEC >> "$LOG_FILE" 2>&1 &
    CLOUDFLARED_PID=$!
    log "Cloudflared 进程 ID: $CLOUDFLARED_PID"

    success "服务已在后台启动。查看日志：tail -f $LOG_FILE"
    sleep 5 # 等待进程稳定和 cloudflared 建立隧道
}


# 显示并保存结果
show_and_save_result() {
    local final_domain="$ARGO_DOMAIN"
    
    if [[ -z "$final_domain" ]]; then
        log "使用临时隧道，正在获取隧道域名..."
        sleep 10 

        # 从日志文件中获取域名 (最可靠的方式)
        TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" | tail -n 1)
        
        retries=0
        while [ -z "$TUNNEL_URL" ] && [ $retries -lt 5 ]; do
            warn "未能获取到域名，5秒后重试... (尝试次数: $((retries+1)))"
            sleep 5
            TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" | tail -n 1)
            ((retries++))
        done
        
        [[ -z "$TUNNEL_URL" ]] && error "无法获取 Cloudflare Tunnel 域名，请检查 $LOG_FILE 日志文件。"
        final_domain=$(echo "$TUNNEL_URL" | sed 's|https://||')
    fi
    
    success "获取到的域名: $final_domain"

    VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${final_domain}&fp=chrome&type=ws&host=${final_domain}&path=/#${NODE_NAME}" 
    
    SAVE_INFO="========================================
           节点信息 (VLESS + Sing-box)
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
管理命令 (非ROOT环境):
停止服务: pkill -f sing-box && pkill -f cloudflared
查看节点: bash $0 -v
查看日志: tail -f $LOG_FILE
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

# 极速模式
quick_mode() {
    clear
    echo -e "${BLUE}=== 极速模式 ===${NC}"
    read -p "请输入您的 UUID (留空将自动生成): " UUID_INPUT
    UUID=${UUID_INPUT:-$(generate_uuid)}
    success "UUID 已设置为: $UUID"
    
    NODE_NAME="VLESS-Argo-Singbox-Quick"
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

    read -p "请输入节点名称 [默认: VLESS-Argo-Singbox]: " NODE_NAME_INPUT
    NODE_NAME=${NODE_NAME_INPUT:-"VLESS-Argo-Singbox"}

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
    echo -e "${GREEN}=== 开始部署 (内核: sing-box) ===${NC}"
    # check_root 已移除
    detect_os_arch
    # install_dependencies 已移除

    stop_old_processes # 清理旧进程

    # --- 动态获取 sing-box 下载链接 (修改后：不使用 jq) ---
    log "正在获取 sing-box 最新版本下载链接 (尝试使用 grep/sed)..."
    local SINGBOX_DOWNLOAD_URL
    local TARGET_ARCH_PATTERN="linux-${ARCH}\.tar\.gz"

    # 使用 curl 获取 JSON，然后用 grep 和 sed 提取匹配架构的链接
    SINGBOX_DOWNLOAD_URL=$(
        curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | \
        grep -o '"browser_download_url": "[^"]*'"${TARGET_ARCH_PATTERN}"'"' | \
        head -n 1 | \
        sed -E 's/.*"browser_download_url": "(.*)".*/\1/'
    )

    if [ -z "$SINGBOX_DOWNLOAD_URL" ]; then
        error "无法自动获取 sing-box 最新下载链接。请检查网络或确认目标文件 ${TARGET_ARCH_PATTERN} 是否存在。"
    fi
    log "已获取最新链接: $SINGBOX_DOWNLOAD_URL"
    # --- 修改结束 ---
    
    download_and_install "sing-box" "$SINGBOX_BIN" "$SINGBOX_DOWNLOAD_URL" "tar.gz"
    download_and_install "cloudflared" "$CLOUDFLARED_BIN" "${CLOUDFLARED_URL_BASE}cloudflared-linux-${ARCH}" "bin"
    
    create_config_file
    start_services_no_root # 启动服务
    show_and_save_result
}

# 卸载脚本
uninstall_service() {
    clear
    echo -e "${RED}=== 卸载脚本 ===${NC}"
    warn "这将移除 sing-box, Cloudflared 以及所有相关配置文件。"
    read -p "您确定要继续吗? (y/N): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}卸载已取消。${NC}"
        exit 0
    fi

    # 停止进程
    log "正在停止 sing-box 和 cloudflared 进程..."
    pkill -f "$SINGBOX_BIN" >/dev/null 2>&1 || true
    pkill -f "$CLOUDFLARED_BIN" >/dev/null 2>&1 || true
    
    log "正在移除二进制文件..."
    rm -f "$SINGBOX_BIN" "$CLOUDFLARED_BIN"
    rmdir --ignore-fail-on-non-empty "$HOME/bin" 2>/dev/null || true # 尝试移除空目录

    log "正在移除配置文件目录..."
    rm -rf "$INSTALL_PATH"
    
    log "正在移除节点信息和日志文件..."
    rm -f "$NODE_INFO_FILE" "$LOG_FILE"
    
    success "卸载完成！"
}


# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    Sing-box + Argo VLESS 部署脚本 (无ROOT) ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    适用于 Hugging Face Spaces 等受限环境  ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}请选择操作:${NC}"
    echo -e "${BLUE}1) 极速模式 - 自动配置，快速部署 (临时域名)${NC}"
    echo -e "${BLUE}2) 完整模式 - 自定义配置项 (推荐 Argo Token)${NC}"
    echo -e "${BLUE}3) 查看节点信息 - 显示已保存的节点${NC}"
    echo -e "${RED}4) 卸载脚本 - 移除所有相关文件和进程${NC}"
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
if [ "$1" = "-v" ]; then
    view_node_info
    exit 0
fi

main_menu
