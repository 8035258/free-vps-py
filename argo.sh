#!/bin/bash
# 一键安装 Xray + Argo (VLESS 节点)
# 支持 Debian/Ubuntu 和 Alpine

set -e

# ========== 基础颜色 ==========
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ========== 检测系统 ==========
detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unsupported"
    fi
}

PM=$(detect_pm)
if [ "$PM" = "unsupported" ]; then
    echo -e "${RED}未检测到受支持的包管理器 (apt 或 apk)${NC}"
    exit 1
fi

echo -e "${GREEN}检测到系统使用: $PM${NC}"

# ========== 安装依赖 ==========
if [ "$PM" = "apt" ]; then
    apt-get update -y
    apt-get install -y wget unzip curl uuid-runtime
elif [ "$PM" = "apk" ]; then
    apk update
    apk add --no-cache wget unzip curl bash
fi

# ========== 生成 UUID ==========
if command -v uuidgen >/dev/null 2>&1; then
    UUID=$(uuidgen)
else
    UUID=$(cat /proc/sys/kernel/random/uuid)
fi

echo -e "${GREEN}已生成 UUID: $UUID${NC}"

# ========== 安装 Xray ==========
mkdir -p /usr/local/xray
cd /usr/local/xray

XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '\"' -f4)
wget -q https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip
unzip -qo Xray-linux-64.zip
chmod +x xray

# 写配置文件 (监听本地 8001)
cat > config.json <<EOF
{
  "inbounds": [{
    "port": 8001,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID" }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "/" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

echo -e "${GREEN}Xray 配置已写入 /usr/local/xray/config.json${NC}"

# ========== 安装 cloudflared ==========
cd /usr/local/bin
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
chmod +x cloudflared

# ========== 选择隧道模式 ==========
echo -e "${YELLOW}请选择隧道模式:${NC}"
echo "1) 临时隧道 (Cloudflare 自动分配临时域名)"
echo "2) 固定隧道 (需要提供 Argo Token 和域名)"
read -p "请输入选择 (1/2): " MODE

cd /usr/local/xray
./xray run -c config.json > xray.log 2>&1 &
sleep 2

if [ "$MODE" = "1" ]; then
    # 临时隧道
    /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8001 > argo.log 2>&1 &
    sleep 5
    ARGO_DOMAIN=$(grep -oE "https://[a-zA-Z0-9.-]+trycloudflare.com" argo.log | head -n1 | sed 's#https://##')
elif [ "$MODE" = "2" ]; then
    read -p "请输入 Argo 域名 (例如 myargo.example.com): " ARGO_DOMAIN
    read -p "请输入 Argo Token: " ARGO_AUTH
    echo "$ARGO_AUTH" > /root/argo_token.txt
    /usr/local/bin/cloudflared tunnel --no-autoupdate run --token $ARGO_AUTH > argo.log 2>&1 &
else
    echo -e "${RED}无效输入，退出${NC}"
    exit 1
fi

sleep 5

# ========== 输出 VLESS 节点 ==========
if [ -n "$ARGO_DOMAIN" ]; then
    VLESS_LINK="vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=/#xray-argo"
    echo -e \"${GREEN}VLESS 节点信息:${NC}\"
    echo \"$VLESS_LINK\"
else
    echo -e \"${RED}未能获取 Argo 域名，请检查日志 /usr/local/xray/argo.log${NC}\"
fi
