#!/bin/bash

#================================================================================#
#           Shadowsocks-rust 一键安装与管理脚本 (增强交互版)                     #
#================================================================================#

# --- 全局变量和颜色定义 ---
GREEN_BG='\033[42;30m'   # 绿色背景，黑色文字
RED_BG='\033[41;97m'     # 红色背景，白色文字
WHITE_BG='\033[47;30m'   # 白色背景，黑色文字
BLUE_BG='\033[44;97m'    # 蓝色背景，白色文字
GREEN='\033[0;32m'       # 绿色
RED='\033[0;31m'         # 红色
NORMAL='\033[0m'         # 重置格式

SS_CORE_PATH="/opt/skim-ss/ssserver"
SS_CONFIG_PATH="/etc/systemd/system"
LATEST_VERSION="" # 用于缓存最新版本号

# --- 核心工具函数 ---

# URL 编码
urlencode() {
  local LANG=C input c
  input="${1:-$(cat)}"
  for (( i=0; i<${#input}; i++ )); do
    c="${input:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) printf "%s" "$c" ;;
      $'\n') printf '%%0A' ;;
      *) printf '%%%02X' "'${c}" ;;
    esac
  done
echo
}

# 依赖安装
install_packages() {
  echo -e "${GREEN_BG}[依赖检查] 正在安装必需的软件包...${NORMAL}"
  if command -v apk &>/dev/null; then
    apk update && apk add curl jq tar openssl xz
  elif command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y curl jq tar openssl xz-utils
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm curl jq tar openssl xz
  elif command -v dnf &>/dev/null; then
    dnf install -y curl jq tar openssl xz
  elif command -v zypper &>/dev/null; then
    zypper install -y curl jq tar openssl xz
  elif command -v yum &>/dev/null; then
    yum install -y curl jq tar openssl xz
  else
    echo -e "${RED_BG}[错误] 不支持的包管理器。${NORMAL} 请手动安装 curl, jq, tar, openssl, xz。"
    exit 1
  fi
}

# 检查并安装依赖
check_dependencies() {
  local missing_deps=0
  for tool in curl jq tar openssl xz; do
    if ! command -v "$tool" &>/dev/null; then
      missing_deps=1
      break
    fi
  done
  if [ "$missing_deps" -eq 1 ]; then
    install_packages
  fi
}

# --- Shadowsocks-rust 核心管理 ---

# 获取最新版本号
get_latest_version() {
  if [ -z "$LATEST_VERSION" ]; then
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r .tag_name)
    [[ "$LATEST_VERSION" == "null" ]] && LATEST_VERSION="v1.22.0" # Fallback
  fi
  echo "$LATEST_VERSION"
}

# 下载并安装 ssserver
download_ss_rust() {
  local version=$1
  local arch=$2
  
  mkdir -p "$(dirname "$SS_CORE_PATH")"
  local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/shadowsocks-${version}.${arch}-unknown-linux-musl.tar.xz"
  
  echo -e "${GREEN_BG}正在下载 ${url}...${NORMAL}"
  if curl -sL -o shadowsocks.tar.xz "$url"; then
    tar -xJf shadowsocks.tar.xz -C "$(dirname "$SS_CORE_PATH")" && rm -f shadowsocks.tar.xz
    find "$(dirname "$SS_CORE_PATH")" -type f ! -name ssserver -delete
    echo -e "${GREEN}ss-rust核心已安装至 ${SS_CORE_PATH}${NORMAL}"
  else
    echo -e "${RED_BG}[错误] 下载失败，请检查网络或版本号。${NORMAL}"
    exit 1
  fi
}

# 检查并按需安装/更新 ssserver 核心
check_and_install_ss_core() {
  echo -e "${BLUE_BG}正在检查 ssserver 核心程序...${NORMAL}"
  local latest_version
  latest_version=$(get_latest_version)
  
  if [ -x "$SS_CORE_PATH" ]; then
    local installed_version
    installed_version=$($SS_CORE_PATH --version | awk '{print "v" $2}')
    if [ "$installed_version" == "$latest_version" ]; then
      echo -e "${GREEN}[检查通过] 已安装最新版 ssserver 核心 (${latest_version})。${NORMAL}"
    else
      echo -e "${GREEN_BG}[需要更新] 发现新版本，准备从 ${installed_version} 更新到 ${latest_version}...${NORMAL}"
      local cpu_arch
      cpu_arch=$(detect_arch)
      download_ss_rust "$latest_version" "$cpu_arch"
    fi
  else
    echo -e "${GREEN_BG}[首次安装] 未发现 ssserver 核心，准备安装 ${latest_version}...${NORMAL}"
    local cpu_arch
    cpu_arch=$(detect_arch)
    download_ss_rust "$latest_version" "$cpu_arch"
  fi
}

# --- 服务管理功能 ---

# 获取公网 IP 地址
get_public_ip() {
    local ip
    ip=$(curl -s https://cloudflare.com/cdn-cgi/trace -4 | grep -oP '(?<=ip=).*' || \
         curl -s https://cloudflare.com/cdn-cgi/trace -6 | grep -oP '(?<=ip=).*')
    [[ "$ip" =~ : ]] && ip="[$ip]" # Add brackets for IPv6
    echo "$ip"
}

# 显示连接信息
display_connection_info() {
    local port=$1
    local cipher=$2
    local password=$3
    local ip
    ip=$(get_public_ip)

    echo -e "--------------------------------------------------"
    echo -e "${GREEN_BG}服务配置成功！${NORMAL}"
    echo -e "${GREEN_BG}地址:${NORMAL} $ip:$port"
    echo -e "${GREEN_BG}加密:${NORMAL}  $cipher"
    echo -e "${GREEN_BG}密码:${NORMAL} $password"
    
    local ss_url="ss://$(echo -n "${cipher}:${password}" | base64 | tr -d '\n' | urlencode)@$ip:$port#$(urlencode "ss-rust-$port")"
    local json_config
    json_config=$(cat <<EOC
{
  "type": "shadowsocks",
  "tag":  "ss-rust-$port",
  "server": "$ip",
  "server_port": $port,
  "method": "$cipher",
  "password": "$password"
}
EOC
)
    echo -e "${GREEN_BG}SS URL:${NORMAL} ${GREEN}${ss_url}${NORMAL}"
    echo -e "${GREEN_BG}JSON 配置:${NORMAL}\n${json_config}"
    echo -e "--------------------------------------------------"
}

# 创建一个新的 SS 服务
create_new_service() {
    echo -e "${BLUE_BG}--- 创建新的 Shadowsocks 服务 ---${NORMAL}"
    
    # 端口设置
    local port
    while true; do
        read -rp "请输入端口号 [10000-65535]，或输入 'auto' 随机生成: " port
        if [[ "$port" == "auto" ]]; then
            port=$((RANDOM % 50000 + 10000))
            echo -e "已随机生成端口: ${GREEN}$port${NORMAL}"
            break
        elif [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 10000 ] && [ "$port" -le 65535 ]; then
            if systemctl list-units --type=service | grep -q "ssserver-${port}.service"; then
                echo -e "${RED}错误: 端口 $port 已被占用，请选择其他端口。${NORMAL}"
            else
                break
            fi
        else
            echo -e "${RED}输入无效，请输入 10000-65535 之间的数字或 'auto'。${NORMAL}"
        fi
    done

    # 加密方法设置
    local cipher
    read -rp "请输入加密方法 (默认: 2022-blake3-aes-128-gcm): " cipher
    cipher=${cipher:-2022-blake3-aes-128-gcm}

    # 生成密码
    local password
    if [[ "$cipher" == "2022-blake3-aes-256-gcm" ]]; then
        password=$(openssl rand -base64 32)
    else
        password=$(openssl rand -base64 16)
    fi

    # 创建 systemd 服务文件
    echo -e "${GREEN_BG}正在创建并启动 systemd 服务...${NORMAL}"
    cat > ${SS_CONFIG_PATH}/ssserver-${port}.service <<EOF
[Unit]
Description=Shadowsocks Rust Server on :${port}
After=network.target

[Service]
ExecStart=${SS_CORE_PATH} -U --server-addr [::]:${port} --encrypt-method ${cipher} --password ${password}
Restart=on-failure
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload && systemctl enable --now ssserver-${port} &>/dev/null
    
    # 检查服务状态
    if systemctl is-active --quiet "ssserver-${port}.service"; then
        display_connection_info "$port" "$cipher" "$password"
    else
        echo -e "${RED_BG}[错误] 服务 ssserver-${port} 启动失败！${NORMAL}"
        echo -e "请使用 'journalctl -u ssserver-${port}' 查看日志。 "
        # 清理失败的服务文件
        rm -f "${SS_CONFIG_PATH}/ssserver-${port}.service"
        systemctl daemon-reload
    fi
}

# 列出现有的 SS 服务
list_services() {
    echo -e "${BLUE_BG}--- 现有的 Shadowsocks 服务 ---${NORMAL}"
    
    # 使用 systemctl 查找所有匹配的服务
    local services
    services=$(systemctl list-unit-files --full --all --type=service | grep -o 'ssserver-[0-9]\+\.service' | sed 's/\.service//')
    
    if [ -z "$services" ]; then
        echo "未找到任何 Shadowsocks 服务。"
        return 1
    fi

    printf "+----------+--------------------------------------+------------+\n"
    printf "| %-8s | %-36s | %-10s |\n" "端口" "加密方法" "状态"
    printf "+----------+--------------------------------------+------------+\n"

    for service_name in $services; do
        local port
        port=$(echo "$service_name" | grep -oP '[0-9]+')
        local service_file="${SS_CONFIG_PATH}/${service_name}.service"
        
        if [ -f "$service_file" ]; then
            local exec_start_line
            exec_start_line=$(grep -E '^ExecStart=' "$service_file")
            local cipher
            cipher=$(echo "$exec_start_line" | grep -oP -- '--encrypt-method \K\S+')
            
            local status
            if systemctl is-active --quiet "$service_name"; then
                status="${GREEN}active${NORMAL}"
            else
                status="${RED}inactive${NORMAL}"
            fi
            
            printf "| %-8s | %-36s | %-18s |\n" "$port" "$cipher" "$status"
        fi
    done
    printf "+----------+--------------------------------------+------------+\n"
    return 0
}

# 删除指定的服务
delete_service() {
    local port=$1
    local service_name="ssserver-${port}"
    local service_file="${SS_CONFIG_PATH}/${service_name}.service"

    if [ ! -f "$service_file" ]; then
        echo -e "${RED}错误: 未找到端口为 ${port} 的服务。${NORMAL}"
        return
    fi

    read -rp "你确定要删除端口为 ${RED}$port${NORMAL} 的服务吗? [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "正在停止并禁用服务 ${service_name}..."
        systemctl disable --now "$service_name" &>/dev/null
        
        echo -e "正在删除服务文件 ${service_file}..."
        rm -f "$service_file"
        
        echo -e "正在重载 systemd 配置..."
        systemctl daemon-reload
        
        echo -e "${GREEN}端口为 ${port} 的服务已成功删除。${NORMAL}"
    else
        echo "操作已取消。"
    fi
}

# 查看指定服务的连接信息
view_service_info() {
    local port=$1
    local service_name="ssserver-${port}"
    local service_file="${SS_CONFIG_PATH}/${service_name}.service"

    if [ ! -f "$service_file" ]; then
        echo -e "${RED}错误: 未找到端口为 ${port} 的服务。${NORMAL}"
        return
    fi
    
    local exec_start_line
    exec_start_line=$(grep -E '^ExecStart=' "$service_file")
    local cipher
    cipher=$(echo "$exec_start_line" | grep -oP -- '--encrypt-method \K\S+')
    local password
    password=$(echo "$exec_start_line" | grep -oP -- '--password \K\S+')
    
    display_connection_info "$port" "$cipher" "$password"
}

# --- 菜单界面 ---

# 管理服务的子菜单
manage_services_menu() {
    while true; do
        list_services
        if [ $? -ne 0 ]; then return; fi # 如果没有服务，直接返回主菜单

        read -rp "请输入要管理的服务的端口号 (输入 '0' 返回主菜单): " port
        if [[ "$port" == "0" ]]; then break; fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ ! -f "${SS_CONFIG_PATH}/ssserver-${port}.service" ]; then
            echo -e "${RED}端口号无效或服务不存在，请重新输入。${NORMAL}"
            continue
        fi

        echo -e "\n你选择了端口 ${GREEN}${port}${NORMAL}，请选择操作:"
        echo "  1. 查看连接信息"
        echo "  2. 删除此服务"
        echo "  0. 返回上一级"
        read -rp "请输入选项 [0-2]: " choice

        case $choice in
            1) view_service_info "$port" ;;
            2) delete_service "$port"; break ;; # 删除后直接跳出管理菜单
            0) ;;
            *) echo -e "${RED}无效选项，请重新输入。${NORMAL}" ;;
        esac
        echo -e "\n按 Enter 键继续..."
        read -r
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${WHITE_BG}=========================================${NORMAL}"
        echo -e "${WHITE_BG}   Shadowsocks-rust 管理脚本 (交互版)    ${NORMAL}"
        echo -e "${WHITE_BG}=========================================${NORMAL}"
        echo "  1. 新建 Shadowsocks 服务"
        echo "  2. 管理现有服务"
        echo "  0. 退出脚本"
        echo -e "-----------------------------------------"
        read -rp "请输入选项 [0-2]: " choice

        case $choice in
            1) create_new_service ;;
            2) manage_services_menu ;;
            0) echo "感谢使用，脚本退出。"; exit 0 ;;
            *) echo -e "${RED}无效选项，请重新输入。${NORMAL}" ;;
        esac
    done
}


# --- 脚本入口 ---

# 必须以 root 身份运行
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED_BG}此脚本需要 root 权限。${NORMAL} 请使用 sudo 或以 root 用户身份运行。"
  exit 1
fi

# 检查 Init System 是否为 systemd
if ! [[ "$(cat /proc/1/comm)" == "systemd" ]]; then
    echo -e "${RED_BG}错误: 此脚本仅支持使用 systemd 的系统。${NORMAL}"
    exit 1
fi

# 检测CPU架构
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        *) echo -e "${RED_BG}不支持的CPU架构: $(uname -m)${NORMAL}"; exit 1 ;;
    esac
}

# 执行初始化检查
check_dependencies
check_and_install_ss_core

# 显示主菜单
main_menu
