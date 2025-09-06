#!/bin/sh
# Hysteria2 一键安装脚本 - Alpine + OpenRC
# 固定端口 45678，自动清理旧进程
# 修改版：只监听 IPv4，只获取 IPv4 地址

# ===== 随机生成端口和密码 =====
[ -z "$HY2_PORT" ] && HY2_PORT=$(shuf -i 20000-65000 -n 1)
[ -z "$PASSWD" ] && PASSWD=$(cat /proc/sys/kernel/random/uuid)

# ===== 检查 root =====
[ "$(id -u)" -ne 0 ] && echo "请在 root 用户下运行" && exit 1

# ===== 安装依赖 =====
apk add --no-cache curl wget tar openssl coreutils net-tools

# ===== 清理旧进程 =====
pkill -9 hysteria 2>/dev/null

# ===== 下载 Hysteria2 二进制 =====
mkdir -p /usr/local/bin
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  HY2_FILE="hysteria-linux-amd64" ;;
  aarch64) HY2_FILE="hysteria-linux-arm64" ;;
  *) echo "暂不支持的架构: $ARCH" && exit 1 ;;
esac

wget -q https://github.com/apernet/hysteria/releases/latest/download/$HY2_FILE -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ===== 配置目录 & 证书 =====
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

# ===== 写配置文件 =====
cat << EOF > /etc/hysteria/config.yaml
listen: 0.0.0.0:$HY2_PORT   # 只监听 IPv4

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$PASSWD"

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

# ===== OpenRC 服务脚本 =====
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

# ===== 获取 IPv4 =====
HOST_IP=$(curl -s ipv4.ip.sb)
[ -z "$HOST_IP" ] && HOST_IP="IPv4获取失败"

# ===== 获取 ISP 信息 =====
ISP=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')

# ===== 输出结果 =====
echo -e "\n\033[1;32mHysteria2 安装成功\033[0m"
echo -e "本机IPv4: $HOST_IP"
echo -e "监听端口: $HY2_PORT"
echo -e "密码: $PASSWD"

echo -e "\nV2rayN / Nekobox:"
echo -e "\033[1;32mhysteria2://$PASSWD@$HOST_IP:$HY2_PORT/?sni=www.bing.com&alpn=h3&insecure=1#$ISP\033[0m"

echo -e "\nClash:"
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
