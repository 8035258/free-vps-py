#!/bin/bash

# --- 颜色配置 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 变量 ---
INSTALL_PATH="/etc/sing-box"
CONFIG_FILE="${INSTALL_PATH}/config.json"
CERT_DIR="${INSTALL_PATH}/cert"
SINGBOX_BIN="/usr/local/bin/sing-box"
NODE_INFO_FILE="$HOME/.singbox_vless_info"

# --- 核心功能 ---

# 1. 检查 Root
check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请以 root 权限运行!${NC}"; exit 1; }
}

# 2. 基础依赖安装
install_deps() {
    echo -e "${BLUE}正在安装必要依赖 (curl, openssl, tar)...${NC}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            centos|rhel|fedora) 
                yum install -y curl wget tar openssl jq ;;
            debian|ubuntu) 
                apt-get update && apt-get install -y curl wget tar openssl jq ;;
            alpine) 
                apk add curl wget tar openssl jq ;;
        esac
    fi
}

# 3. 获取公网IP
get_public_ip() {
    PUBLIC_IP=$(curl -s https://api.ipify.org)
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(curl -s http://ipv4.icanhazip.com)
    fi
    echo -e "${GREEN}检测到公网 IP: ${PUBLIC_IP}${NC}"
}

# 4. 生成自签名证书 (无需域名)
generate_cert() {
    echo -e "${BLUE}正在生成自签名证书...${NC}"
    mkdir -p "$CERT_DIR"
    
    # 生成有效期 10 年的自签名证书，CN=公网IP
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
        -keyout "$CERT_DIR/private.key" \
        -out "$CERT_DIR/cert.crt" \
        -days 3650 \
        -subj "/CN=${PUBLIC_IP}" &>/dev/null
        
    chmod 644 "$CERT_DIR/cert.crt"
    chmod 644 "$CERT_DIR/private.key"
    echo -e "${GREEN}证书生成完成。${NC}"
}

# 5. 安装 Sing-box
install_singbox() {
    echo -e "${BLUE}正在安装 Sing-box...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
    esac
    
    DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r --arg ARCH "$ARCH" '.assets[] | select(.name | endswith("linux-\($ARCH).tar.gz")) | .browser_download_url')
    
    wget -q -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL"
    mkdir -p /tmp/sing-box-install
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/sing-box-install
    mv $(find /tmp/sing-box-install -name "sing-box" -type f) "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-install
}

# 6. 写入配置
write_config() {
    mkdir -p "$INSTALL_PATH"
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "error", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{ "uuid": "${UUID}", "flow": "" }],
      "tls": {
        "enabled": true,
        "server_name": "${PUBLIC_IP}",
        "certificate_path": "${CERT_DIR}/cert.crt",
        "key_path": "${CERT_DIR}/private.key"
      },
      "transport": { "type": "ws", "path": "/" }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
}

# 7. 启动服务
start_service() {
    # 简单的服务管理逻辑
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box
After=network.target
[Service]
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
    elif command -v rc-service &>/dev/null; then
        # Alpine OpenRC
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
supervisor=supervise-daemon
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
pidfile="/run/sing-box.pid"
name="sing-box"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart
    fi
}

# 8. 显示结果
show_info() {
    # 链接中添加 &allowInsecure=1 用于部分客户端自动跳过验证
    LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=tls&sni=${PUBLIC_IP}&type=ws&host=${PUBLIC_IP}&path=/&fp=chrome&allowInsecure=1#Singbox-IP-Direct"
    
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}       部署成功 (VLESS+WS+TLS)        ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "IP地址: ${PUBLIC_IP}"
    echo -e "端口:   ${PORT}"
    echo -e "UUID:   ${UUID}"
    echo -e "--------------------------------------"
    echo -e "${YELLOW}重要提示: 因使用自签名证书，客户端必须开启 [跳过证书验证] 或 [Allow Insecure]${NC}"
    echo -e "--------------------------------------"
    echo -e "${BLUE}VLESS 链接:${NC}"
    echo -e "${LINK}"
    echo -e "--------------------------------------"
    
    # 保存到文件
    echo "$LINK" > "$NODE_INFO_FILE"
}

# --- 主程序 ---
clear
echo -e "${BLUE}=== Sing-box 极简直连脚本 (VLESS+WS+TLS+自签名) ===${NC}"

check_root

# 交互输入
read -p "请输入端口 [回车默认 443]: " INPUT_PORT
PORT=${INPUT_PORT:-443}

read -p "请输入UUID [回车自动生成]: " INPUT_UUID
if [[ -z "$INPUT_UUID" ]]; then
    if command -v uuidgen &>/dev/null; then
        UUID=$(uuidgen)
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
else
    UUID=$INPUT_UUID
fi

echo -e "${YELLOW}配置: 端口 [$PORT], UUID [$UUID]${NC}"

install_deps
get_public_ip
generate_cert
install_singbox
write_config
start_service
show_info