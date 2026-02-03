#!/usr/bin/env bash
# Copyright (c) community-scripts
# Author: LostMedia
# License: MIT

set -euo pipefail

# ---------------- DEBUG ----------------
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

# ---------------- HELPERS ----------------

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
  set +e
  if [[ "$(id -u)" -ne 0 ]]; then
    set -e
    error_exit "Run this script as root on the Proxmox host"
  fi
  set -e
}

check_proxmox() {
  set +e
  if ! command -v pct >/dev/null 2>&1; then
    set -e
    error_exit "This script must be run on a Proxmox host"
  fi
  set -e
}

# ---------------- INPUT ----------------

get_ctid() {
  while true; do
    read -rp "Enter CTID for Decypharr LXC: " CTID </dev/tty
    [[ -z "$CTID" ]] && continue
    [[ ! "$CTID" =~ ^[0-9]+$ ]] && continue
    pct status "$CTID" &>/dev/null || break
    echo "CTID $CTID already exists."
  done
}

select_storage() {
  msg "Detected Proxmox storages:"
  pvesm status | awk 'NR>1 {print " - "$1" ("$2")"}'

  echo ""
  read -rp "Template storage (dir ONLY): " TEMPLATE_STORAGE </dev/tty
  read -rp "RootFS storage (dir / lvmthin / zfspool): " ROOTFS_STORAGE </dev/tty

  if [[ -z "$TEMPLATE_STORAGE" || -z "$ROOTFS_STORAGE" ]]; then
    error_exit "Storage selection cannot be empty"
  fi

  TEMPLATE_TYPE=$(pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s {print $2}')
  ROOTFS_TYPE=$(pvesm status | awk -v s="$ROOTFS_STORAGE" '$1==s {print $2}')

  [[ "$TEMPLATE_TYPE" != "dir" ]] && error_exit "Template storage must be type: dir"
  [[ ! "$ROOTFS_TYPE" =~ ^(dir|lvmthin|zfspool)$ ]] && error_exit "Invalid RootFS storage type"
}

# ---------------- TEMPLATE ----------------

ensure_template() {
  msg "Locating latest Debian 12 template"

  TEMPLATE=$(pveam available | awk '/debian-12-standard/ && /amd64/ {print $2}' | sort -V | tail -n1)
  [[ -z "$TEMPLATE" ]] && error_exit "Debian 12 template not found"

  if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
    msg "Downloading template: $TEMPLATE"
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi
}

# ---------------- LXC ----------------

create_container() {
  msg "Creating LXC CTID $CTID"

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

# ---------------- INSTALL ----------------

install_dependencies() {
  pct exec "$CTID" -- bash -c "apt update && apt install -y curl jq ca-certificates"
}

install_decypharr() {
  pct exec "$CTID" -- bash -c "
ARCH=\$(dpkg --print-architecture)
case \$ARCH in
  amd64) BIN=decypharr-linux-amd64 ;;
  arm64) BIN=decypharr-linux-arm64 ;;
  *) exit 1 ;;
esac

VERSION=\$(curl -fsSL https://api.github.com/repos/${REPO}/releases/latest | jq -r .tag_name)
curl -fsSL https://github.com/${REPO}/releases/download/\$VERSION/\$BIN -o /usr/local/bin/decypharr
chmod +x /usr/local/bin/decypharr
"
}

create_service() {
pct exec "$CTID" -- bash -c "
mkdir -p /opt/decypharr/config
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

systemctl daemon-reload
systemctl enable --now decypharr
"
}

# ---------------- DONE ----------------

done_msg() {
  IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
  echo ""
  echo "✅ Decypharr LXC installed"
  echo "📡 IP: $IP"
  echo "🌐 Web: http://$IP:$PORT"
  echo ""
}

# ---------------- MAIN ----------------

header_info
check_root
check_proxmox
get_ctid
select_storage
ensure_template
create_container
install_dependencies
install_decypharr
create_service
done_msg
