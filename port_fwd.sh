#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以root身份运行!${RESET}" 1>&2
        exit 1
    fi
}

update_system() {
    echo -e "${GREEN}正在更新系统和安装依赖...${RESET}"
    if [ -f "/usr/bin/apt-get" ]; then
        apt-get update -y && apt-get upgrade -y
        apt-get install -y gawk curl
    else
        yum update -y && yum upgrade -y
        yum install -y epel-release gawk curl
    fi
}

get_random_port() {    
    local port    
    port=$(shuf -i 1024-65000 -n 1)
    while ss -ltn | grep -q ":$port"; do
        port=$(shuf -i 1024-65000 -n 1)
    done    
    
    echo "$port"   
}

install_portfwd() {
    check_root
    update_system
    
    echo -e "${GREEN}正在安装端口转发服务...${RESET}"
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    PORT=$(get_random_port)
    
    psk=$(openssl rand -base64 16 | tr -d '\n')

    cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${psk}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    systemctl enable xray.service && systemctl restart xray.service
    
    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    if [[ -z "${HOST_IP}" ]]; then
        HOST_IP=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    fi
    
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
    
    cat << EOF > /usr/local/etc/xray/config.txt
# 链接
ss://2022-blake3-aes-128-gcm:${psk}@${HOST_IP}:${PORT}#${IP_COUNTRY}

# 格式
${IP_COUNTRY} = ss, ${HOST_IP}, ${PORT}, encrypt-method=2022-blake3-aes-128-gcm, password=${psk}, udp-relay=true

EOF

    echo -e "${GREEN}端口转发服务安装完成!${RESET}"
    echo -e "${YELLOW}===== 客户端配置信息 =====${RESET}"
    cat /usr/local/etc/xray/config.txt
    echo -e "${YELLOW}=========================${RESET}"
}

# 卸载端口转发服务
uninstall_portfwd() {
    check_root
    echo -e "${YELLOW}正在卸载端口转发服务...${RESET}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
    echo -e "${GREEN}端口转发服务已卸载!${RESET}"
}

# 检查端口转发安装状态
check_portfwd_status() {
    if command -v xray &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查端口转发运行状态
check_portfwd_running() {
    if systemctl is-active --quiet xray; then
        return 0
    else
        return 1
    fi
}

# 启动端口转发服务
start_portfwd() {
    check_root
    echo -e "${GREEN}正在启动端口转发服务...${RESET}"
    systemctl start xray
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}端口转发服务已启动!${RESET}"
    else
        echo -e "${RED}端口转发服务启动失败!${RESET}"
    fi
}

# 停止端口转发服务
stop_portfwd() {
    check_root
    echo -e "${YELLOW}正在停止端口转发服务...${RESET}"
    systemctl stop xray
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}端口转发服务已停止!${RESET}"
    else
        echo -e "${RED}端口转发服务停止失败!${RESET}"
    fi
}

# 重启端口转发服务
restart_portfwd() {
    check_root
    echo -e "${YELLOW}正在重启端口转发服务...${RESET}"
    systemctl restart xray
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}端口转发服务已重启!${RESET}"
    else
        echo -e "${RED}端口转发服务重启失败!${RESET}"
    fi
}

# 查看端口转发状态
status_portfwd() {
    systemctl status xray
}

# 查看端口转发日志
view_logs() {
    journalctl -u xray -f
}

# 查看端口转发配置
view_config() {
    if [ -f "/usr/local/etc/xray/config.txt" ]; then
        echo -e "${YELLOW}===== 客户端配置信息 =====${RESET}"
        cat /usr/local/etc/xray/config.txt
        echo -e "${YELLOW}=========================${RESET}"
    else
        echo -e "${RED}配置文件不存在!${RESET}"
    fi
}

# 显示选项菜单
show_menu() {
    clear
    echo -e "${GREEN}===== 端口转发管理工具 =====${RESET}"
    check_portfwd_status
    portfwd_installed=$?
    check_portfwd_running
    portfwd_running=$?

    echo -e "${GREEN}安装状态: $(if [ ${portfwd_installed} -eq 0 ]; then echo "${GREEN}已安装${RESET}"; else echo "${RED}未安装${RESET}"; fi)${RESET}"
    echo -e "${GREEN}运行状态: $(if [ ${portfwd_running} -eq 0 ]; then echo "${GREEN}已运行${RESET}"; else echo "${RED}未运行${RESET}"; fi)${RESET}"
    echo ""
    echo "1. 安装端口转发服务"
    echo "2. 卸载端口转发服务"
    echo "3. 启动端口转发服务"
    echo "4. 停止端口转发服务"
    echo "5. 重启端口转发服务"
    echo "6. 检查端口转发状态"
    echo "7. 查看端口转发日志"
    echo "8. 查看端口转发配置"
    echo "0. 退出"
    echo -e "${GREEN}=========================${RESET}"
    read -p "请输入选项编号: " choice
}

# 命令行参数处理
if [ $# -gt 0 ]; then
    case "$1" in
        "install")
            install_portfwd
            exit 0
            ;;
        "uninstall")
            uninstall_portfwd
            exit 0
            ;;
        "start")
            start_portfwd
            exit 0
            ;;
        "stop")
            stop_portfwd
            exit 0
            ;;
        "restart")
            restart_portfwd
            exit 0
            ;;
        "status")
            status_portfwd
            exit 0
            ;;
        "logs")
            view_logs
            exit 0
            ;;
        "config")
            view_config
            exit 0
            ;;
        *)
            echo -e "${RED}无效的参数!${RESET}"
            echo "可用参数: install, uninstall, start, stop, restart, status, logs, config"
            exit 1
            ;;
    esac
fi

# 捕获 Ctrl+C 信号
trap 'echo -e "${RED}已取消操作${RESET}"; exit' INT

# 主循环
while true; do
    show_menu
    case "$choice" in
        1) install_portfwd ;;
        2) uninstall_portfwd ;;
        3) start_portfwd ;;
        4) stop_portfwd ;;
        5) restart_portfwd ;;
        6) status_portfwd ;;
        7) view_logs ;;
        8) view_config ;;
        0)
            echo -e "${GREEN}已退出端口转发管理工具${RESET}"
            exit 0
            ;;
        *) echo -e "${RED}无效的选项${RESET}" ;;
    esac
    read -p "按 Enter 键继续..."
done
