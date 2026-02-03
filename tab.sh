#!/usr/bin/env bash
# Copyright (c) community-scripts
# Author: LostMedia
# License: MIT

set -euo pipefail

# ---- DEBUG / TRACE ----
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
set -x
trap 'echo "❌ ERROR at line $LINENO. Last command: $BASH_COMMAND"' ERR

exec </dev/tty

APP="Decypharr"
HOSTNAME="decypharr"
MEMORY="1024"
CORES="2"
DISK_SIZE="8G"
PORT="8282"
REPO="sirrobot01/decypharr"

TEMPLATE=""
TEMPLATE_STORAGE=""
ROOTFS_STORAGE=""

# ----------------------
# Helper Functions
# ----------------------

header_info() {
cat <<EOF
==============================
  Decypharr LXC Installer
==============================
EOF
}

error_exit() {
  echo "❌ ERROR: $1"
  exit 1
}

msg() {
  echo -e "➡️ $1"
}

check_root() {
  [[ "$(id -u)" -ne 0 ]] && error_exit "Run this script as root on the Proxmox host"
}

check_proxmox() {
  command -v pct >/dev/null 2>&1 || error_exit "This script must be run on a Proxmox host"
}

select_storage() {
  msg "Available Proxmox storages:"
  pvesm status | awk 'NR>1 {print " - "$1" ("$2")"}'

  read -rp "Template storage (usually 'local'): " TEMPLATE_STORAGE
  read -rp "RootFS storage (usually 'local-lvm'): " ROOTFS_STORAGE

  [[ -z "$TEMPLATE_STORAGE" || -z "$ROOTFS_STORAGE" ]] && error_exit "Storage selection cannot be empty"
}

get_ctid() {
  while true; do
    read -rp "Enter CTID to use: " CTID
    [[ ! "$CTID" =~ ^[0-9]+$ ]] && echo "CTID must be numeric" && continue
    pct status "$CTID" &>/dev/null && echo "CTID exists, choose another" || break
  done
}

ensure_template() {
  msg "Locating latest Debian 12 template"

  TEMPLATE=$(pveam available \
    | awk '/debian-12-standard/ && /amd64/ {print $2}' \
    | sort -V \
    | tail -n1)

  [[ -z "$TEMPLATE" ]] && error_exit "Could not locate Debian 12 template"

  if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
    msg "Downloading template: $TEMPLATE"
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi
}

# ----------------------
# LXC Creation
# ----------------------

create_container() {
  msg "Creating LXC $CTID"

  pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "$ROOTFS_STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --onboot 1 \
    --unprivileged 1 \
    --features nesting=1

  pct start "$CTID"
}

# ----------------------
# Inside Container
# ----------------------

install_dependencies() {
  pct exec "$CTID" -- bash -c "
    apt update &&
    apt install -y curl jq ca-certificates
  "
}

install_decypharr() {
  pct exec "$CTID" -- bash -c "
    ARCH=\$(dpkg --print-architecture)
    case \$ARCH in
      amd64) BIN=decypharr-linux-amd64 ;;
      arm64) BIN=decypharr-linux-arm64 ;;
      *) echo 'Unsupported arch'; exit 1 ;;
    esac

    VERSION=\$(curl -fsSL https://api.github.com/repos/${REPO}/releases/latest | jq -r '.tag_name')
    curl -fsSL https://github.com/${REPO}/releases/download/\$VERSION/\$BIN -o /usr/local/bin/decypharr
    chmod +x /usr/local/bin/decypharr
  "
}

create_service() {
  pct exec "$CTID" -- bash -c "
cat >/etc/systemd/system/decypharr.service <<EOF
[Unit]
Description=Decypharr
After=network.target

[Service]
ExecStart=/usr/local/bin/decypharr --config /opt/decypharr/config
Restart=always

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /opt/decypharr/config
systemctl daemon-reload
systemctl enable --now decypharr
"
}

finish() {
  IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
  echo ""
  echo "✅ Decypharr installed successfully"
  echo "🌐 Web UI: http://$IP:$PORT"
  echo "📁 Config: /opt/decypharr/config"
}

# ----------------------
# Main
# ----------------------

header_info
check_root
check_proxmox
select_storage
get_ctid
ensure_template
create_container
install_dependencies
install_decypharr
create_service
finish
