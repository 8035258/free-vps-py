#!/bin/sh

# 随机生成端口和密码
[ -z "$HY2_PORT" ] && HY2_PORT=$(shuf -i 2000-65000 -n 1)
[ -z "$PASSWD" ] && PASSWD=$(cat /proc/sys/kernel/random/uuid)

# 检查 root
[ "$(id -u)" -ne 0 ] && echo "请在 root 用户下运行" && exit 1

# 安装依赖
apk add --no-cache curl wget unzip openssl

# 安装 Hysteria2（官方脚本）
bash <(curl -fsSL https://get.hy2.sh/)

# 生成证书目录
mkdir -p /etc/hysteria

# 生成自签证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

# 修改属主（Alpine 下 hysteria 用户可能没有创建，先判断）
id hysteria >/dev/null 2>&1 || adduser -D -s /sbin/nologin hysteria
chown hysteria /etc/hysteria/server.key /etc/hysteria/server.crt

# 写入配置
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

transport:
  udp:
    hopInterval: 30s
EOF

# OpenRC 服务文件
cat << 'EOF' > /etc/init.d/hysteria
#!/sbin/openrc-run

command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"
description="Hysteria2 Server"
EOF

chmod +x /etc/init.d/hysteria

# 加入开机启动 & 启动
rc-update add hysteria default
rc-service hysteria restart

# 获取 IP
ipv4=$(curl -s ipv4.ip.sb)
if [ -n "$ipv4" ]; then
    HOST_IP="$ipv4"
else
    ipv6=$(curl -s --max-time 1 ipv6.ip.sb)
    if [ -n "$ipv6" ]; then
        HOST_IP="$ipv6"
    else
        echo "无法获取公网 IP"
        exit 1
    fi
fi
echo -e "\e[1;32m本机IP: $HOST_IP\033[0m"

# 获取 ISP 信息
ISP=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')

# 输出连接信息
echo -e "\n\e[1;32mHysteria2 安装成功\033[0m"
echo -e "\nV2rayN / Nekobox:"
echo -e "\e[1;32mhysteria2://$PASSWD@$HOST_IP:$HY2_PORT/?sni=www.bing.com&alpn=h3&insecure=1#$ISP\033[0m"
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
