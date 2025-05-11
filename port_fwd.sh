#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root!${RESET}" 1>&2
        exit 1
    fi
}

update_system() {
    echo -e "${GREEN}Updating system and installing dependencies...${RESET}"
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
    
    echo -e "${GREEN}Installing port forwarding service...${RESET}"
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    PORT=$(get_random_port)
    
    # Generate appropriate key for 2022-blake3-aes-256-gcm method
    psk=$(openssl rand -base64 32)

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
        "method": "2022-blake3-aes-256-gcm",
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
# Connection Information
ss://2022-blake3-aes-256-gcm:${psk}@${HOST_IP}:${PORT}#${IP_COUNTRY}

# Format
${IP_COUNTRY} = ss, ${HOST_IP}, ${PORT}, encrypt-method=2022-blake3-aes-256-gcm, password=${psk}, udp-relay=true

EOF

    echo -e "${GREEN}Port forwarding service installation complete!${RESET}"
    echo -e "${YELLOW}===== Client Configuration Info =====${RESET}"
    cat /usr/local/etc/xray/config.txt
    echo -e "${YELLOW}===================================${RESET}"
}

# Execute installation
install_portfwd
