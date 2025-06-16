#!/bin/bash

GREEN_BG='\033[42;30m'   # Underlined, green background, black text
RED_BG='\033[41;97m'     # Red background (41), white text (97)
WHITE_BG='\033[47;30m'   # White background (47), black text (30)
NORMAL='\033[0m'         # Reset formatting

print_usage() {
  echo -e "${WHITE_BG}Usage:${NORMAL} $0 [-p PORT] [CIPHER] [VERSION] [IP]"
  echo "  -p PORT     Custom port number (default: random between 10000-59999)"
  echo "  CIPHER      Encryption method (default: 2022-blake3-aes-128-gcm)"
  echo "  VERSION     shadowsocks-rust release tag (default: latest)"
  echo "  IP          Server IP (default: Cloudflare trace)"
  exit 1
}

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED_BG}This script requires root privileges.${NORMAL} Please run as root or use sudo."
  exit 1
fi

# Parse options
port_arg=""
while getopts ":p:h" opt; do
  case ${opt} in
    p)
      port_arg="${OPTARG}"
      ;;
    h)
      print_usage
      ;;
    \?)
      echo -e "${RED_BG}Invalid option: -${OPTARG}${NORMAL}"
      print_usage
      ;;
    :)  
      echo -e "${RED_BG}Option -${OPTARG} requires an argument.${NORMAL}"
      print_usage
      ;;
  esac
done
shift $((OPTIND -1))

# Positional args after options
cipher_arg="$1"
version_arg="$2"
ip_arg="$3"

# Detect CPU architecture
cpu_arch=$(uname -m)
case "$cpu_arch" in
  x86_64) arch="x86_64" ;;
  aarch64) arch="aarch64" ;;
  *) echo -e "${RED_BG}Unsupported architecture: $cpu_arch${NORMAL}"; exit 1 ;;
esac

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

# Install dependencies if missing
install_packages() {
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
    echo -e "${RED_BG}[ERROR] Unsupported package manager.${NORMAL} Please install curl, jq, tar, and openssl manually."
    exit 1
  fi
}
is_busybox_grep() { grep --version 2>&1 | grep -q BusyBox; }
if is_busybox_grep; then
  echo -e "${GREEN_BG}[Requirements] BusyBox grep detected. Installing GNU grep.${NORMAL}"
  install_packages
fi
for tool in curl jq tar openssl xz; do
  if ! command -v "$tool" &>/dev/null; then
    echo -e "${GREEN_BG}[Requirements] Installing missing dependencies...${NORMAL}"
    install_packages
    break
  fi
done

# Get latest release tag
get_latest_version() {
  tag=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r .tag_name)
  [[ "$tag" == null ]] && echo "v1.22.0" || echo "$tag"
}

# Download and install ssserver
download_ss_rust() {
  mkdir -p /opt/skim-ss/
  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/shadowsocks-${version}.${arch}-unknown-linux-musl.tar.xz"
  echo -e "${GREEN_BG}Downloading ${url}...${NORMAL}"
  curl -sL -o shadowsocks.tar.xz "$url"
  tar -xJf shadowsocks.tar.xz -C /opt/skim-ss/ && rm -f shadowsocks.tar.xz
  find /opt/skim-ss/ -type f ! -name ssserver -delete
  echo -e "${GREEN_BG}ss-rust ssserver installed to /opt/skim-ss/${NORMAL}"
}

# Determine port
if [[ -n "$port_arg" && "$port_arg" != "auto" ]]; then
  port=$port_arg
elif [[ -z "$port_arg" || "$port_arg" = "auto" ]]; then
  port=$((RANDOM % 50000 + 10000))
fi
# Determine cipher
cipher=${cipher_arg:-2022-blake3-aes-128-gcm}
# Determine version
version=${version_arg:-auto}
[[ "$version" == "auto" ]] && version=$(get_latest_version)
# Determine IP
if [[ -n "$ip_arg" && "$ip_arg" != "auto" ]]; then
  ip=$ip_arg
else
  ip=$(curl -s https://cloudflare.com/cdn-cgi/trace -4 | grep -oP '(?<=ip=).*' || \
       curl -s https://cloudflare.com/cdn-cgi/trace -6 | grep -oP '(?<=ip=).*')
  [[ "$ip" =~ : ]] && ip="[$ip]"
fi

# Install or update ssserver
if [[ -x "/opt/skim-ss/ssserver" ]]; then
  installed=$(/opt/skim-ss/ssserver --version | awk '{print "v" $2}')
  if [[ "$installed" == "$version" ]]; then
    echo -e "${GREEN_BG}[Requirements] ss-rust ssserver core ${version} is already installed.${NORMAL}"
  else
    echo -e "${GREEN_BG}[Requirements] Updating ss-rust ssserver to ${version}.${NORMAL}"
    download_ss_rust
  fi
else
  echo -e "${GREEN_BG}[Requirements] Installing ss-rust ssserver core ${version}.${NORMAL}"
  download_ss_rust
fi

# Generate password
if [[ "$cipher" == "2022-blake3-aes-256-gcm" ]]; then
  password=$(openssl rand -base64 32)
else
  password=$(openssl rand -base64 16)
fi

# Display config
cat <<EOF
${GREEN_BG}Address:${NORMAL} $ip:$port
${GREEN_BG}Cipher:${NORMAL}  $cipher
${GREEN_BG}Password:${NORMAL} $password
EOF

# Install system service
echo -e "${GREEN_BG}Installing system service...${NORMAL}"
init_system=$(cat /proc/1/comm)
if [[ "$init_system" == "systemd" ]]; then
  cat > /etc/systemd/system/ssserver-${port}.service <<EOF
[Unit]
Description=Shadowsocks Rust Server on :${port}
After=network.target

[Service]
ExecStart=/opt/skim-ss/ssserver -U --server-addr [::]:$port --encrypt-method $cipher --password $password
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now ssserver-${port}
  echo -e "${WHITE_BG}To remove:${NORMAL} systemctl disable --now ssserver-${port} && rm /etc/systemd/system/ssserver-${port}.service"
else
  echo -e "${RED_BG}Unsupported init system: $init_system.${NORMAL}"
  exit 1
fi

# Output ss:// URL and JSON
ss_url="ss://$(echo -n "${cipher}:${password}" | base64 | urlencode)@$ip:$port#$(urlencode "SkimProxy.sh Shadowsocks $cipher $ip:$port")"
json_config=$(cat <<EOC
{
  "type": "shadowsocks",
  "tag":  "shadowsocks-server",
  "server": "$ip",
  "server_port": $port,
  "method": "$cipher",
  "password": "$password"
}
EOC
)

echo -e "${GREEN_BG}SS URL:${NORMAL} $ss_url"
echo -e "${GREEN_BG}JSON config:${NORMAL}\n$json_config"

echo -e "${GREEN_BG}Shadowsocks Rust installed and service started on port $port.${NORMAL}"
