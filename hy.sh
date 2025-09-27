#!/bin/bash
# Hysteria2 整合一键安装脚本
# 兼容：Alpine (使用 apk / OpenRC) 和 Debian/Ubuntu (使用 apt / systemd)

# ===== 随机生成端口和密码 =====
[ -z "$HY2_PORT" ] && HY2_PORT=$(shuf -i 20000-65000 -n 1)
[ -z "$PASSWD" ] && PASSWD=$(cat /proc/sys/kernel/random/uuid)

# ===== 检查 root 权限 =====
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请在 root 用户下运行此脚本"
  exit 1
fi

# ===== 识别操作系统类型 =====
if [ -f /etc/alpine-release ]; then
  OS_TYPE="Alpine"
elif [ -f /etc/debian_version ] || grep -q 'Debian\|Ubuntu' /etc/issue; then
  OS_TYPE="Debian"
else
  echo "错误：暂不支持此操作系统类型。目前仅支持 Alpine 和 Debian/Ubuntu。"
  exit 1
fi

echo "---"
echo "检测到操作系统：$OS_TYPE"
echo "---"

# --- 依赖安装函数 ---
install_dependencies() {
  echo "正在安装依赖..."
  if [ "$OS_TYPE" == "Alpine" ]; then
    # Alpine 使用 apk
    apk update -q
    apk add --no-cache curl wget tar openssl coreutils net-tools
  elif [ "$OS_TYPE" == "Debian" ]; then
    # Debian/Ubuntu 使用 apt
    apt update -y -q
    apt install -y curl wget tar openssl coreutils net-tools
  fi
}

# --- 服务清理函数 ---
cleanup_old_service() {
    echo "正在清理旧进程和旧服务配置..."
    pkill -9 hysteria 2>/dev/null
    
    if [ "$OS_TYPE" == "Alpine" ]; then
        # Alpine OpenRC 清理
        if rc-service hysteria status >/dev/null 2>&1; then
            rc-service hysteria stop >/dev/null 2>&1
            rc-update del hysteria >/dev/null 2>&1
        fi
        rm -f /etc/init.d/hysteria
    elif [ "$OS_TYPE" == "Debian" ]; then
        # Debian systemd 清理
        if systemctl is-active --quiet hysteria; then
            systemctl stop hysteria
        fi
        systemctl disable hysteria >/dev/null 2>&1
        rm -f /etc/systemd/system/hysteria.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
}

# ===== 核心安装步骤 =====
install_dependencies
cleanup_old_service

# ===== 下载 Hysteria2 二进制文件 =====
echo "正在下载 Hysteria2 二进制文件..."
mkdir -p /usr/local/bin
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  HY2_FILE="hysteria-linux-amd64" ;;
  aarch64) HY2_FILE="hysteria-linux-arm64" ;;
  *) echo "错误：暂不支持的架构: $ARCH" && exit 1 ;;
esac

wget -q https://github.com/apernet/hysteria/releases/latest/download/$HY2_FILE -O /usr/local/bin/hysteria
if [ $? -ne 0 ]; then
  echo "错误：下载 Hysteria2 失败，请检查网络连接。"
  exit 1
fi
chmod +x /usr/local/bin/hysteria

# ===== 配置目录 & 证书生成 (CN=bing.com) =====
echo "正在生成自签名证书..."
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500 2>/dev/null

# ===== 写入 Hysteria2 配置文件 =====
echo "正在写入配置文件 (端口: $HY2_PORT)..."
cat << EOF > /etc/hysteria/config.yaml
listen: :$HY2_PORT

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
EOF

# --- 配置和启动服务 (根据系统类型选择 OpenRC 或 systemd) ---
echo "正在配置和启动服务 ($OS_TYPE)..."
if [ "$OS_TYPE" == "Alpine" ]; then
  # ===== OpenRC 服务脚本 (Alpine) =====
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
  rc-update add hysteria default 2>/dev/null
  rc-service hysteria restart

elif [ "$OS_TYPE" == "Debian" ]; then
  # ===== systemd 服务脚本 (Debian/Ubuntu) =====
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
  systemctl enable hysteria 2>/dev/null
  systemctl restart hysteria
fi

# ===== 获取 IP 和 ISP 信息 =====
echo "正在获取服务器 IP 和 ISP 信息..."
ipv4=$(curl -s ipv4.ip.sb)
if [ -n "$ipv4" ]; then
    HOST_IP="$ipv4"
else
    ipv6=$(curl -s --max-time 1 ipv6.ip.sb)
    [ -n "$ipv6" ] && HOST_IP="$ipv6" || HOST_IP="服务器IP获取失败"
fi

ISP=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')
ISP=${ISP:-"未知ISP"} # 如果获取失败，设置为“未知ISP”

# ===== 输出结果 =====
echo -e "\n--------------------------------------------------"
echo -e "\033[1;32mHysteria2 安装/配置成功\033[0m"
echo -e "操作系统类型: $OS_TYPE"
echo -e "本机IP: $HOST_IP"
echo -e "监听端口: $HY2_PORT"
echo -e "密码: $PASSWD"
echo -e "--------------------------------------------------"

echo -e "\n\033[1;36m>> 客户端配置信息 (V2rayN / Nekobox)\033[0m"
echo -e "\033[1;32mhysteria2://$PASSWD@$HOST_IP:$HY2_PORT/?sni=www.bing.com&alpn=h3&insecure=1#$ISP\033[0m"

echo -e "\n\033[1;36m>> Clash 配置 (YAML)\033[0m"
cat << EOF
- name: $ISP
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
echo -e "--------------------------------------------------"

# 检查服务状态
if [ "$OS_TYPE" == "Alpine" ]; then
    rc-service hysteria status
elif [ "$OS_TYPE" == "Debian" ]; then
    systemctl status hysteria --no-pager -l | head -n 10
fi