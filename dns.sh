#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NODE_INFO_FILE="$HOME/.xray_nodes_info"

# 如果是-v参数，直接查看节点信息
if [ "$1" = "-v" ]; then
    if [ -f "$NODE_INFO_FILE" ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}           节点信息查看               ${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo
        cat "$NODE_INFO_FILE"
        echo
    else
        echo -e "${RED}未找到节点信息文件${NC}"
        echo -e "${YELLOW}请先运行部署脚本生成节点信息${NC}"
    fi
    exit 0
fi

generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v python3 &> /dev/null; then
        python3 -c "import uuid; print(str(uuid.uuid4()))"
    else
        hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/urandom | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/' | tr '[:upper:]' '[:lower:]'
    fi
}

clear

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Python Xray Argo 一键部署脚本    ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${BLUE}基于项目: ${YELLOW}https://github.com/eooce/python-xray-argo${NC}"
echo -e "${BLUE}脚本仓库: ${YELLOW}https://github.com/byJoey/free-vps-py${NC}"
echo -e "${BLUE}TG交流群: ${YELLOW}https://t.me/+ft-zI76oovgwNmRh${NC}"
echo
echo -e "${GREEN}本脚本基于 eooce 大佬的 Python Xray Argo 项目开发${NC}"
echo -e "${GREEN}提供极速和完整两种配置模式，简化部署流程${NC}"
echo -e "${GREEN}支持自动UUID生成、后台运行、节点信息输出${NC}"
echo

echo -e "${YELLOW}请选择操作:${NC}"
echo -e "${BLUE}1) 极速模式 - 只修改UUID并启动${NC}"
echo -e "${BLUE}2) 完整模式 - 详细配置所有选项${NC}"
echo -e "${BLUE}3) 查看节点信息 - 显示已保存的节点信息${NC}"
echo
read -p "请输入选择 (1/2/3): " MODE_CHOICE

if [ "$MODE_CHOICE" = "3" ]; then
    if [ -f "$NODE_INFO_FILE" ]; then
        echo
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}           节点信息查看               ${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo
        cat "$NODE_INFO_FILE"
        echo
        echo -e "${YELLOW}提示: 如需重新部署，请重新运行脚本选择模式1或2${NC}"
    else
        echo
        echo -e "${RED}未找到节点信息文件${NC}"
        echo -e "${YELLOW}请先运行部署脚本生成节点信息${NC}"
        echo
        echo -e "${BLUE}是否现在开始部署? (y/n)${NC}"
        read -p "> " START_DEPLOY
        if [ "$START_DEPLOY" = "y" ] || [ "$START_DEPLOY" = "Y" ]; then
            echo -e "${YELLOW}请选择部署模式:${NC}"
            echo -e "${BLUE}1) 极速模式${NC}"
            echo -e "${BLUE}2) 完整模式${NC}"
            read -p "请输入选择 (1/2): " MODE_CHOICE
        else
            echo -e "${GREEN}退出脚本${NC}"
            exit 0
        fi
    fi

    if [ "$MODE_CHOICE" != "1" ] && [ "$MODE_CHOICE" != "2" ]; then
        echo -e "${GREEN}退出脚本${NC}"
        exit 0
    fi
fi

echo -e "${BLUE}检查并安装依赖...${NC}"
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}正在安装 Python3...${NC}"
    sudo apt-get update && sudo apt-get install -y python3 python3-pip
fi

if ! python3 -c "import requests" &> /dev/null; then
    echo -e "${YELLOW}正在安装 Python 依赖...${NC}"
    pip3 install requests
fi

PROJECT_DIR="python-xray-argo"
if [ ! -d "$PROJECT_DIR" ]; then
    echo -e "${BLUE}下载完整仓库...${NC}"
    if command -v git &> /dev/null; then
        git clone https://github.com/eooce/python-xray-argo.git
    else
        echo -e "${YELLOW}Git未安装，使用wget下载...${NC}"
        wget -q https://github.com/eooce/python-xray-argo/archive/refs/heads/main.zip -O python-xray-argo.zip
        if command -v unzip &> /dev/null; then
            unzip -q python-xray-argo.zip
            mv python-xray-argo-main python-xray-argo
            rm python-xray-argo.zip
        else
            echo -e "${YELLOW}正在安装 unzip...${NC}"
            sudo apt-get install -y unzip
            unzip -q python-xray-argo.zip
            mv python-xray-argo-main python-xray-argo
            rm python-xray-argo.zip
        fi
    fi

    if [ $? -ne 0 ] || [ ! -d "$PROJECT_DIR" ]; then
        echo -e "${RED}下载失败，请检查网络连接${NC}"
        exit 1
    fi
fi

cd "$PROJECT_DIR"

echo -e "${GREEN}依赖安装完成！${NC}"
echo

if [ ! -f "app.py" ]; then
    echo -e "${RED}未找到app.py文件！${NC}"
    exit 1
fi

cp app.py app.py.backup
echo -e "${YELLOW}已备份原始文件为 app.py.backup${NC}"

if [ "$MODE_CHOICE" = "1" ]; then
    echo -e "${BLUE}=== 极速模式 ===${NC}"
    echo

    echo -e "${YELLOW}当前UUID: $(grep "UUID = " app.py | head -1 | cut -d"'" -f2)${NC}"
    read -p "请输入新的 UUID (留空自动生成): " UUID_INPUT
    if [ -z "$UUID_INPUT" ]; then
        UUID_INPUT=$(generate_uuid)
        echo -e "${GREEN}自动生成UUID: $UUID_INPUT${NC}"
    fi

    sed -i "s/UUID = os.environ.get('UUID', '[^']*')/UUID = os.environ.get('UUID', '$UUID_INPUT')/" app.py
    echo -e "${GREEN}UUID 已设置为: $UUID_INPUT${NC}"

    sed -i "s/CFIP = os.environ.get('CFIP', '[^']*')/CFIP = os.environ.get('CFIP', 'joeyblog.net')/" app.py
    echo -e "${GREEN}优选IP已自动设置为: joeyblog.net${NC}"

    echo
    echo -e "${GREEN}极速配置完成！正在启动服务...${NC}"
    echo

else
    echo -e "${BLUE}=== 完整配置模式 ===${NC}"
    echo
    # 保持和原始逻辑一致（UUID / 端口 / CFIP / CFPORT 等配置），省略重复代码
    # ...
    echo -e "${GREEN}完整配置完成！${NC}"
fi

echo -e "${YELLOW}=== 当前配置摘要 ===${NC}"
echo -e "UUID: $(grep "UUID = " app.py | head -1 | cut -d"'" -f2)"
echo -e "节点名称: $(grep "NAME = " app.py | head -1 | cut -d"'" -f4)"
echo -e "服务端口: $(grep "PORT = int" app.py | grep -o "or [0-9]*" | cut -d" " -f2)"
echo -e "优选IP: $(grep "CFIP = " app.py | cut -d"'" -f4)"
echo -e "优选端口: $(grep "CFPORT = " app.py | cut -d"'" -f4)"
echo -e "订阅路径: $(grep "SUB_PATH = " app.py | cut -d"'" -f4)"
echo -e "${YELLOW}========================${NC}"
echo

echo -e "${BLUE}正在启动服务...${NC}"
echo -e "${YELLOW}当前工作目录：$(pwd)${NC}"
echo

# 🔹 删除 YouTube 分流补丁，改为 DNS 配置补丁
echo -e "${BLUE}正在修改配置，添加 DNS: 1.1.1.1...${NC}"
cat > dns_patch.py << 'EOF'
with open('app.py', 'r', encoding='utf-8') as f:
    content = f.read()

# 在 config = { 里面增加 dns 配置
if '"dns"' not in content:
    content = content.replace('"loglevel":"none"}', '"loglevel":"none"}, "dns": {"servers": ["1.1.1.1"]}')

with open('app.py', 'w', encoding='utf-8') as f:
    f.write(content)

print("DNS 配置已添加")
EOF

python3 dns_patch.py
rm dns_patch.py

# 先清理可能存在的进程
pkill -f "python3 app.py" > /dev/null 2>&1
sleep 2

# 启动服务并获取PID
python3 app.py > app.log 2>&1 &
APP_PID=$!

# 验证 PID 获取成功
if [ -z "$APP_PID" ] || [ "$APP_PID" -eq 0 ]; then
    echo -e "${RED}获取进程PID失败，尝试直接启动${NC}"
    nohup python3 app.py > app.log 2>&1 &
    sleep 2
    APP_PID=$(pgrep -f "python3 app.py" | head -1)
    if [ -z "$APP_PID" ]; then
        echo -e "${RED}服务启动失败，请检查Python环境${NC}"
        echo -e "${YELLOW}查看日志: tail -f app.log${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}服务已在后台启动，PID: $APP_PID${NC}"
echo -e "${YELLOW}日志文件: $(pwd)/app.log${NC}"

# ...（后面节点等待/保存逻辑保持不变，但去掉 YouTube 分流相关说明）
