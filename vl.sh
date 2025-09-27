#!/bin/bash

# =======================================================
# VLESS+WS+TLS 单节点一键安装脚本
# - 支持 Debian 11 和 Alpine 3.20
# - 协议：VLESS+WS+TLS
# - 端口：35787
# - 使用自签名证书，客户端会有证书警告
# =======================================================

# --- 节点配置 (可自定义) ---
# VLESS 的唯一标识符 (UUID)
UUID=$(cat /proc/sys/kernel/random/uuid)
# VLESS 监听端口 (默认 35787)
PORT=35787
# WebSocket 路径
PATH_NAME="/vless"
# 节点名称 (URI 尾部)
NODE_NAME="VLESS_WS_TLS_Direct"
# Xray 证书和密钥路径
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
echo -e "${GREEN}1. 系统检测与依赖安装 (Xray Core, curl, wget, socat, openssl)${NC}"
echo -e "${GREEN}===========================================${NC}"

# 检测操作系统和版本
if grep -qs "Debian GNU/Linux 11" /etc/os-release; then
    OS="Debian_11"
    echo -e "${YELLOW}检测到系统: Debian 11 (Bullseye)${NC}"
    echo -e "${GREEN}安装依赖...${NC}"
    apt update -y
    apt install -y curl wget socat openssl || { echo -e "${RED}Debian 依赖安装失败。${NC}"; exit 1; }

elif grep -qs "Alpine Linux" /etc/os-release && grep -qs "3\.20" /etc/alpine-release; then
    OS="Alpine_3.20"
    echo -e "${YELLOW}检测到系统: Alpine Linux 3.20${NC}"
    echo -e "${GREEN}安装依赖...${NC}"
    apk update
    apk add curl wget socat openssl || { echo -e "${RED}Alpine 依赖安装失败。${NC}"; exit 1; }

else
    echo -e "${RED}当前系统版本不支持：${NC}"
    cat /etc/os-release 2>/dev/null || cat /etc/alpine-release 2>/dev/null
    echo -e "${RED}本脚本仅支持 Debian-11 和 Alpine-3.20。${NC}"
    exit 1
fi

# 安装 Xray Core
echo -e "\n${GREEN}安装 Xray Core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" || { echo -e "${RED}Xray 安装失败。${NC}"; exit 1; }

# 获取服务器公网 IP，用于证书的 CN 字段和 VLESS 链接
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://icanhazip.com)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
    echo -e "${YELLOW}警告：无法自动获取公网 IP。${NC}"
else
    echo -e "${GREEN}服务器公网 IP: $SERVER_IP${NC}"
fi

# =======================================================
# 2. 生成自签名证书
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}2. 生成自签名证书 (${SERVER_IP})${NC}"
echo -e "${GREEN}===========================================${NC}"

mkdir -p /usr/local/etc/xray/
# 生成自签名证书，CN (Common Name) 使用服务器 IP
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -keyout "$KEY_FILE" \
    -out "$CRT_FILE" \
    -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Global/OU=IT/CN=${SERVER_IP}" || { echo -e "${RED}证书生成失败。${NC}"; exit 1; }

echo -e "${YELLOW}自签名证书已生成: ${CRT_FILE} 和 ${KEY_FILE}${NC}"

# =======================================================
# 3. 生成 Xray 配置文件 (VLESS+WS+TLS)
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}3. 生成 Xray 配置文件${NC}"
echo -e "${GREEN}===========================================${NC}"

# Xray 配置文件内容
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

# 启动服务
systemctl daemon-reload 2>/dev/null
systemctl enable xray --now 2>/dev/null

# 尝试检查 systemctl 状态 (Debian)
if command -v systemctl &> /dev/null && systemctl status xray | grep -q "active (running)"; then
    echo -e "${GREEN}Xray 服务已成功通过 systemctl 启动并运行!${NC}"
elif [ "$OS" == "Alpine_3.20" ] && command -v rc-service &> /dev/null; then
    # 尝试 OpenRC (Alpine)
    rc-update add xray default 2>/dev/null
    rc-service xray start
    ps | grep -v grep | grep -q "/usr/local/bin/xray"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Xray 服务已成功通过 OpenRC 启动并运行!${NC}"
    else
        echo -e "${RED}Xray 服务启动失败，请检查日志！${NC}"
        exit 1
    fi
else
    echo -e "${RED}Xray 服务启动失败或状态检测失败，请手动检查: systemctl status xray 或 rc-service xray status${NC}"
    exit 1
fi

# =======================================================
# 5. 生成 VLESS 连接
# =======================================================

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}5. 生成 VLESS 连接${NC}"
echo -e "${GREEN}===========================================${NC}"

# URL 编码 Path: /vless -> %2Fvless
ENCODED_PATH=$(echo "$PATH_NAME" | sed 's/\//%2F/g')

# VLESS URI 格式: vless://<uuid>@<address>:<port>?security=tls&type=ws&path=<path>&sni=<sni>#<name>
# SNI 设置为 IP 地址 (匹配自签名证书 CN)
VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?security=tls&type=ws&path=${ENCODED_PATH}&sni=${SERVER_IP}&allowInsecure=true#${NODE_NAME}"

echo -e "\n🎉 **${GREEN}VLESS+WS+TLS 单节点安装成功!${NC}**"
echo "------------------------------------------------------------"
echo -e "${RED}⚠️ 重要警告: 正在使用自签名证书，客户端连接时可能会看到【不安全/不受信任】警告。${NC}"
echo -e "${YELLOW}如果客户端支持，您可能需要手动启用【允许不安全连接】或【跳过证书验证】选项。${NC}"
echo "------------------------------------------------------------"
echo -e "${GREEN}配置信息:${NC}"
echo -e "UUID:         ${YELLOW}${UUID}${NC}"
echo -e "地址/IP:      ${YELLOW}${SERVER_IP}${NC}"
echo -e "端口:         ${YELLOW}${PORT}${NC}"
echo -e "传输协议:     ${YELLOW}ws (WebSocket)${NC}"
echo -e "加密方式:     ${YELLOW}tls (自签名)${NC}"
echo -e "路径:         ${YELLOW}${PATH_NAME}${NC}"
echo "------------------------------------------------------------"
echo -e "${GREEN}🔗 VLESS 一键连接 (复制到客户端):${NC}"
echo -e "${YELLOW}${VLESS_URI}${NC}"
echo "------------------------------------------------------------"