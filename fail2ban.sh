#!/bin/bash
# https://github.com/zmh2024/Script
set -e
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
# 默认配置
DEFAULT_BANTIME="1h"
DEFAULT_MAXRETRY=3
DEFAULT_FINDTIME="5m"
DEFAULT_IGNOREIP="127.0.0.1/8 ::1"
DEFAULT_BANTIME_INCREMENT="true"
DEFAULT_BANTIME_FACTOR=168
DEFAULT_BANTIME_MAXTIME="8w"
BANTIME=$DEFAULT_BANTIME
MAXRETRY=$DEFAULT_MAXRETRY
FINDTIME=$DEFAULT_FINDTIME
IGNOREIP="$DEFAULT_IGNOREIP"
BANTIME_INCREMENT=$DEFAULT_BANTIME_INCREMENT
BANTIME_FACTOR=$DEFAULT_BANTIME_FACTOR
BANTIME_MAXTIME=$DEFAULT_BANTIME_MAXTIME
# 日志输出函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
# 帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -b, --bantime <时间>       封禁时长，默认: $DEFAULT_BANTIME"
    echo "  -m, --maxretry <次数>      最大尝试次数，默认: $DEFAULT_MAXRETRY"
    echo "  -f, --findtime <时间>      检测时间窗口，默认: $DEFAULT_FINDTIME"
    echo "  -i, --ignoreip <IP列表>    白名单 IP，用逗号分隔，默认: $DEFAULT_IGNOREIP"
    echo "  --increment <true|false>   是否开启增量禁止，默认: $DEFAULT_BANTIME_INCREMENT"
    echo "  --factor <数值>            增量禁止指数因子，默认: $DEFAULT_BANTIME_FACTOR"
    echo "  --maxtime <时间>           最大封禁时间，默认: $DEFAULT_BANTIME_MAXTIME"
    echo "  -h, --help                 显示帮助信息"
    echo
    echo "示例: $0 -b 2h -m 5 -i '127.0.0.1/8,192.168.1.0/24'"
    exit 0
}
# 参数解析
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b|--bantime)
                BANTIME="$2"; shift 2 ;;
            -m|--maxretry)
                MAXRETRY="$2"; shift 2 ;;
            -f|--findtime)
                FINDTIME="$2"; shift 2 ;;
            -i|--ignoreip)
                IGNOREIP="$2"; shift 2 ;;
            --increment)
                BANTIME_INCREMENT="$2"; shift 2 ;;
            --factor)
                BANTIME_FACTOR="$2"; shift 2 ;;
            --maxtime)
                BANTIME_MAXTIME="$2"; shift 2 ;;
            -h|--help)
                show_help ;;
            *)
                log_error "未知参数: $1"
                show_help ;;
        esac
    done
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "必须以 root 用户运行本脚本"
        exit 1
    fi
}
check_system() {
    if ! command -v apt-get &>/dev/null; then
        log_error "仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
}
install_fail2ban() {
    if dpkg -s fail2ban &>/dev/null; then
        log_info "Fail2ban 已安装，跳过安装步骤"
        return
    fi
    log_info "更新软件包列表..."
    apt-get update
    log_info "安装 fail2ban..."
    apt-get install -y fail2ban
}
configure_fail2ban() {
    log_info "正在配置 Fail2ban..."
    if [ -f /etc/fail2ban/jail.local ]; then
        log_warn "备份原配置文件..."
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%Y%m%d%H%M%S)
    fi
    # 检测日志后端（是否使用 systemd）
    if journalctl -u ssh &>/dev/null; then
        BACKEND="systemd"
        LOGPATH="auto"
    else
        BACKEND="auto"
        LOGPATH="/var/log/auth.log"
    fi
    cat > /etc/fail2ban/jail.local << EOL
[DEFAULT]
bantime = $BANTIME
findtime = $FINDTIME
maxretry = $MAXRETRY
ignoreip = $IGNOREIP
bantime.increment = $BANTIME_INCREMENT
bantime.factor = $BANTIME_FACTOR
bantime.maxtime = $BANTIME_MAXTIME
banaction = iptables-multiport
loglevel = INFO
logtarget = /var/log/fail2ban.log
[sshd]
enabled = true
port = ssh
filter = sshd
backend = $BACKEND
logpath = $LOGPATH
maxretry = $MAXRETRY
findtime = $FINDTIME
bantime = $BANTIME
EOL
}
start_service() {
    log_info "重启 Fail2ban 服务..."
    systemctl restart fail2ban
    systemctl enable fail2ban
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2ban 服务运行中"
    else
        log_error "Fail2ban 启动失败，请检查日志"
        journalctl -u fail2ban --no-pager | tail -n 20
        exit 1
    fi
}
show_status() {
    log_info "当前 Fail2ban 状态："
    fail2ban-client status || log_warn "无法获取 Fail2ban 状态"
    echo -e "\n配置详情："
    echo "- 封禁时间: $BANTIME"
    echo "- 最大尝试: $MAXRETRY 次"
    echo "- 检测时间: $FINDTIME"
    echo "- 白名单 IP: $IGNOREIP"
    echo "- 增量禁止: $BANTIME_INCREMENT"
    echo "- 增量因子: $BANTIME_FACTOR"
    echo "- 最大封禁: $BANTIME_MAXTIME"
    echo -e "\n常用命令："
    echo "- 查看状态: fail2ban-client status"
    echo "- 查看 SSH jail: fail2ban-client status sshd"
    echo "- 封禁 IP: fail2ban-client set sshd banip <IP>"
    echo "- 解封 IP: fail2ban-client set sshd unbanip <IP>"
    echo "- 查看日志: tail -f /var/log/fail2ban.log"
}
main() {
    parse_args "$@"
    check_root
    check_system
    install_fail2ban
    configure_fail2ban
    start_service
    show_status
}
main "$@"
