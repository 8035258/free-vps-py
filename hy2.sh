#!/bin/bash

# ===== 随机生成端口和密码 =====
[ -z "$HY2_PORT" ] && HY2_PORT=$(shuf -i 20000-65000 -n 1)
[ -z "$PASSWD" ] && PASSWD=$(cat /proc/sys/kernel/random/uuid)

# ===== 检查 root =====
[ "$(id -u)" -ne 0 ] && echo "错误：请在 root 用户下运行此脚本。" && exit 1

# ===== 系统检测和依赖安装 =====
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
else
    echo "无法检测到操作系统。"
    exit 1
fi

case "$OS_ID" in
  debian)
    echo "检测到 Debian 系统，正在安装依赖..."
    apt update -y
    apt install -y curl wget tar openssl coreutils net-tools
    ;;
  alpine)
    echo "检测到 Alpine 系统，正在安装依赖..."
    apk add --no-cache curl wget tar openssl coreutils net-tools
    ;;
  *)
    echo "暂不支持的操作系统: $OS_ID"
    exit 1
    ;;
esac

# ===== 清理旧进程 =====
pkill -9 hysteria 2>/dev/null

# ===== 下载 Hysteria2 二进制文件 =====
echo "正在下载 Hysteria2..."
mkdir -p /usr/local/bin
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  HY2_FILE="hysteria-linux-amd64" ;;
  aarch64) HY2_FILE="hysteria-linux-arm64" ;;
  *) echo "暂不支持的架构: $ARCH" && exit 1 ;;
esac

# 停止可能正在运行的服务，以防万一
if command -v systemctl &> /dev/null; then
    systemctl stop hysteria 2>/dev/null
elif command -v rc-service &> /dev/null; then
    rc-service hysteria stop 2>/dev/null
fi

wget -q "https://github.com/apernet/hysteria/releases/latest/download/$HY2_FILE" -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ===== 配置目录 & 生成自签名证书 =====
echo "正在生成证书和配置文件..."
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

# ===== 写入 Hysteria2 配置文件 =====
cat << EOF > /etc/hysteria/config.yaml
listen: 0.0.0.0:$HY2_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$PASSWD"

fastOpen: true

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

outboundBind: 0.0.0.0
EOF

# ===== 根据系统配置服务 =====
case "$OS_ID" in
  debian)
    echo "正在配置 systemd 服务..."
    cat << EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria
    systemctl restart hysteria
    ;;
  alpine)
    echo "正在配置 OpenRC 服务..."
    cat << 'EOF' > /etc/init.d/hysteria
#!/sbin/openrc-run

name="hysteria"
description="Hysteria2 Server"

command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
EOF
    chmod +x /etc/init.d/hysteria
    rc-update add hysteria default
    rc-service hysteria restart
    ;;
esac

# ===== 获取公网 IP 和 ISP 信息 (仅IPv4) =====
echo "正在获取服务器 IPv4 地址..."
ipv4=$(curl -s ipv4.ip.sb)
if [ -z "$ipv4" ]; then
    echo -e "\n\033[1;31m错误：无法获取服务器的 IPv4 地址，脚本已中止。\033[0m"
    echo "请检查您的网络连接或确保服务器拥有一个公网 IPv4 地址。"
    exit 1
else
    HOST_IP="$ipv4"
fi

ISP=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')
[ -z "$ISP" ] && ISP="Hysteria2"

# ===== 输出配置信息 =====
echo -e "\n\033[1;32mHysteria2 安装成功！\033[0m"
echo "----------------------------------------"
echo -e "服务器IP (Your IP): \033[1;33m$HOST_IP\033[0m"
echo -e "监听端口 (Port): \033[1;33m$HY2_PORT\033[0m"
echo -e "密码 (Password): \033[1;33m$PASSWD\033[0m"
echo "----------------------------------------"

echo -e "\n\033[1;34mV2rayN / Nekobox 客户端链接:\033[0m"
echo -e "\033[1;32mhysteria2://$PASSWD@$HOST_IP:$HY2_PORT/?sni=www.bing.com&alpn=h3&insecure=1#${ISP}\033[0m"

echo -e "\n\033[1;34mClash (Meta Core) 客户端配置:\033[0m"
cat << EOF
- name: ${ISP}
  type: hysteria2
  server: $HOST_IP
  port: $HY2_PORT
  password: $PASSWD
  alpn:
    - h3
  sni: www.bing.com
  skip-cert-verify: true
  fast-open: true
EOF
