#!/bin/bash

# =======================================================
# VLESS+WS+TLS 单节点一键安装脚本 (兼容 Debian 11 & Alpine 3.20)
# - 协议：VLESS+WS+TLS，端口：35787
# - 彻底修复 Alpine Linux 兼容性：手动下载 Xray & 配置 OpenRC
# - 使用自签名证书 (客户端需设置跳过证书验证)
# =======================================================

# --- 节点配置 (可自定义) ---
UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=35787
PATH_NAME="/vless"
NODE_NAME="VLESS_WS_TLS_Final"
CRT_FILE="/usr/local/etc/xray/xray.crt"
KEY_FILE="/usr/local/etc/xray/xray.key"
# --- 结束配置 ---

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 确保以 root 身份运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 权限运行此脚本。${NC}"
    exit 1
fi

# =======================================================
# 1. 系统检测与依赖安装
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}1. 系统检测与依赖安装 (curl, wget, socat, openssl, unzip)${NC}"
echo -e "${GREEN}===========================================${NC}"

# 检测操作系统和版本
if grep -qs "Debian GNU/Linux 11" /etc/os-release; then
    OS="Debian_11"
    echo -e "${YELLOW}检测到系统: Debian 11 (Bullseye)${NC}"
    echo -e "${GREEN}安装依赖...${NC}"
    apt update -y
    # Debian 默认 apt install unzip 即可
    apt install -y curl wget socat openssl unzip || { echo -e "${RED}Debian 依赖安装失败。${NC}"; exit 1; }

elif grep -qs "Alpine Linux" /etc/os-release && grep -qs "3\.20" /etc/alpine-release; then
    OS="Alpine_3.20"
    echo -e "${YELLOW}检测到系统: Alpine Linux 3.20${NC}"
    echo -e "${GREEN}安装依赖...${NC}"
    # Alpine 需要 apk add unzip 来解压 Xray 文件
    apk update
    apk add curl wget socat openssl unzip || { echo -e "${RED}Alpine 依赖安装失败。${NC}"; exit 1; }

else
    echo -e "${RED}当前系统版本不支持：本脚本仅支持 Debian-11 和 Alpine-3.20。${NC}"
    exit 1
fi

# =======================================================
# 2. Xray Core 安装 (根据系统选择不同方式)
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}2. Xray Core 安装 (针对性修复)${NC}"
echo -e "${GREEN}===========================================${NC}"

if [ "$OS" == "Debian_11" ]; then
    # Debian (Systemd) - 使用官方脚本
    echo -e "${YELLOW}Debian 使用官方一键安装脚本 (Systemd)...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" || { echo -e "${RED}Xray 官方脚本安装失败。${NC}"; exit 1; }

elif [ "$OS" == "Alpine_3.20" ]; then
    # Alpine (OpenRC) - 彻底手动安装 Xray Core
    echo -e "${YELLOW}Alpine 系统不兼容官方脚本，进行手动下载与 OpenRC 配置...${NC}"

    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        echo -e "${RED}错误: 检测到架构为 ${ARCH}。本脚本 Alpine 部分目前仅支持 x86_64 架构。${NC}"
        exit 1
    fi

    # 自动获取最新版本号
    XRAY_VERSION=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$XRAY_VERSION" ]; then
        echo -e "${YELLOW}警告: 获取 Xray 最新版本号失败。使用备用版本 v1.8.6${NC}"
        XRAY_VERSION="v1.8.6" 
    fi

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
    TEMP_DIR=$(mktemp -d)

    echo -e "${GREEN}下载 Xray ${XRAY_VERSION} (${DOWNLOAD_URL})...${NC}"
    # 使用 -L 遵循重定向，使用 -s 静默模式，只显示进度
    wget -q --show-progress -O "${TEMP_DIR}/xray.zip" "$DOWNLOAD_URL" || { echo -e "${RED}Xray 下载失败。请检查网络或 URL。${NC}"; rm -rf "${TEMP_DIR}"; exit 1; }

    unzip -q "${TEMP_DIR}/xray.zip" -d "${TEMP_DIR}"
    install -m 755 "${TEMP_DIR}/xray" /usr/local/bin/xray
    mkdir -p /usr/local/etc/xray

    # 创建 OpenRC 服务文件
    XRAY_RC_SERVICE=$(cat <<EOF
#!/sbin/openrc-run
name="Xray Service"
command="/usr/local/bin/xray"
command_args="-config /usr/local/etc/xray/config.json"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
start_stop_daemon_args="-p \${pidfile} --exec \${command} -- \${command_args}"

depend() {
    need net
    use logger
}
EOF
)
    echo "$XRAY_RC_SERVICE" > /etc/init.d/xray
    chmod +x /etc/init.d/xray
    
    # 清理
    rm -rf "${TEMP_DIR}"
    echo -e "${GREEN}Xray Core 及 OpenRC 服务文件安装成功。${NC}"
fi

# 获取服务器公网 IP
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://icanhazip.com)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
    echo -e "${YELLOW}警告：无法自动获取公网 IP。${NC}"
else
    echo -e "${GREEN}服务器公网 IP: $SERVER_IP${NC}"
fi

# =======================================================
# 3. 生成自签名证书和 Xray 配置
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}3. 生成自签名证书和 Xray 配置${NC}"
echo -e "${GREEN}===========================================${NC}"

# 生成自签名证书，CN (Common Name) 使用服务器 IP
mkdir -p /usr/local/etc/xray/
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -keyout "$KEY_FILE" \
    -out "$CRT_FILE" \
    -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Global/OU=IT/CN=${SERVER_IP}" || { echo -e "${RED}证书生成失败。${NC}"; exit 1; }

echo -e "${YELLOW}自签名证书已生成: ${CRT_FILE} 和 ${KEY_FILE}${NC}"

# Xray 配置文件内容 (VLESS+WS+TLS)
XRAY_CONFIG_JSON=$(cat <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "none"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "$CRT_FILE",
                            "keyFile": "$KEY_FILE"
                        }
                    ],
                    "alpn": ["http/1.1"],
                    "minVersion": "1.2"
                },
                "wsSettings": {
                    "path": "$PATH_NAME"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF
)

# 写入配置文件
echo "$XRAY_CONFIG_JSON" > /usr/local/etc/xray/config.json || { echo -e "${RED}写入 Xray 配置文件失败。${NC}"; exit 1; }
echo -e "${YELLOW}Xray 配置已保存到 /usr/local/etc/xray/config.json${NC}"

# =======================================================
# 4. 启动 Xray 服务
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}4. 启动 Xray 服务${NC}"
echo -e "${GREEN}===========================================${NC}"

if [ "$OS" == "Debian_11" ]; then
    # Debian 11 使用 systemctl
    systemctl daemon-reload
    systemctl enable xray --now
    systemctl status xray | grep -q "active (running)"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Xray 服务已成功通过 systemctl 启动并运行!${NC}"
    else
        echo -e "${RED}Xray 服务启动失败，请检查日志！${NC}"
        exit 1
    fi
    
elif [ "$OS" == "Alpine_3.20" ]; then
    # Alpine 3.20 使用 OpenRC
    rc-update add xray default 2>/dev/null
    rc-service xray start
    ps | grep -v grep | grep -q "/usr/local/bin/xray"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Xray 服务已成功通过 OpenRC 启动并运行!${NC}"
    else
        echo -e "${RED}Xray 服务启动失败，请检查日志！${NC}"
        exit 1
    fi
fi

# =======================================================
# 5. 生成 VLESS 连接
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}5. 生成 VLESS 连接${NC}"
echo -e "${GREEN}===========================================${NC}"

# URL 编码 Path: /vless -> %2Fvless
ENCODED_PATH=$(echo "$PATH_NAME" | sed 's/\//%2F/g')

# VLESS URI 格式: vless://<uuid>@<address>:<port>?security=tls&type=ws&path=<path>&sni=<sni>&allowInsecure=true#<name>
VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?security=tls&type=ws&path=${ENCODED_PATH}&sni=${SERVER_IP}&allowInsecure=true#${NODE_NAME}"

echo -e "\n🎉 **${GREEN}VLESS+WS+TLS 单节点安装成功!${NC}**"
echo "------------------------------------------------------------"
echo -e "${RED}⚠️ 重要警告: 正在使用自签名证书，客户端连接时【务必】启用【允许不安全连接/跳过证书验证】选项。${NC}"
echo "------------------------------------------------------------"
echo -e "${GREEN}配置信息:${NC}"
echo -e "UUID:         ${YELLOW}${UUID}${NC}"
echo -e "地址/IP:      ${YELLOW}${SERVER_IP}${NC}"
echo -e "端口:         ${YELLOW}${PORT}${NC}"
echo -e "传输协议:     ${YELLOW}ws (WebSocket)${NC}"
echo -e "加密方式:     ${YELLOW}tls (自签名)${NC}"
echo -e "路径:         ${YELLOW}${PATH_NAME}${NC}"
echo -e "SNI:          ${YELLOW}${SERVER_IP}${NC}"
echo "------------------------------------------------------------"
echo -e "${GREEN}🔗 VLESS 一键连接 (复制到客户端):${NC}"
echo -e "${YELLOW}${VLESS_URI}${NC}"
echo "------------------------------------------------------------"
