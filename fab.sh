#!/usr/bin/env bash
# Copyright (c) community-scripts
# Author: LostMedia
# License: MIT

set -euo pipefail

# ---- DEBUG / TRACE ----
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
set -x
trap 'echo "❌ ERROR at line $LINENO. Last command: $BASH_COMMAND"' ERR

# Force TTY for interactive prompts
exec </dev/tty

APP="Decypharr"
HOSTNAME="decypharr"
MEMORY="1024"
CORES="2"
DISK_SIZE="8G"
PORT="8282"
REPO="sirrobot01/decypharr"
TEMPLATE=""
STORAGE="local-lvm"

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

get_ctid() {
  while true; do
    read -rp "Enter CTID to use for Decypharr LXC: " CTID </dev/tty
    [[ -z "$CTID" ]] && echo "CTID cannot be empty." && continue
    [[ ! "$CTID" =~ ^[0-9]+$ ]] && echo "CTID must be numeric." && continue
    if pct status "$CTID" &>/dev/null; then
      echo "CTID $CTID already exists. Choose another."
    else
      break
    fi
  done
}

ensure_template() {
  msg "Locating latest Debian 12 LXC template"

  TEMPLATE=$(pveam available | awk '/debian-12-standard/ && /amd64/ {print $2}' | sort -V | tail -n1)

  [[ -z "$TEMPLATE" ]] && error_exit "Unable to locate Debian 12 LXC template"

  if ! pveam list "$STORAGE" | grep -q "$TEMPLATE"; then
    msg "Downloading Debian 12 template: $TEMPLATE"
    pveam update
    pveam download "$STORAGE" "$TEMPLATE"
  fi
}

# ----------------------
# LXC Creation
# ----------------------

create_container() {
  msg "Creating LXC container (CTID: $CTID)"

  pct create "$CTID" "$STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --onboot 1 \
    --unprivileged 1 \
    --features nesting=1

  pct start "$CTID"
}

# ----------------------
# Inside-Container Setup
# ----------------------

install_dependencies() {
  msg "Installing dependencies inside container"

  pct exec "$CTID" -- bash -c "
    apt update &&
    apt install -y curl jq ca-certificates
  "
}

install_decypharr_binary() {
  msg "Downloading Decypharr binary"

  pct exec "$CTID" -- bash -c "
    ARCH=\$(dpkg --print-architecture)
    case \"\$ARCH\" in
      amd64) BIN=decypharr-linux-amd64 ;;
      arm64) BIN=decypharr-linux-arm64 ;;
      *) echo 'Unsupported architecture'; exit 1 ;;
    esac

    VERSION=\$(curl -fsSL https://api.github.com/repos/${REPO}/releases/latest | jq -r '.tag_name')
    [[ -z \"\$VERSION\" ]] && exit 1

    curl -fsSL https://github.com/${REPO}/releases/download/\$VERSION/\$BIN \
      -o /usr/local/bin/decypharr

    chmod +x /usr/local/bin/decypharr
  "
}

setup_config() {
  msg "Creating config directory"
  pct exec "$CTID" -- mkdir -p /opt/decypharr/config
}

create_service() {
  msg "Creating systemd service"

  pct exec "$CTID" -- bash -c "
cat >/etc/systemd/system/decypharr.service <<EOF
[Unit]
Description=Decypharr Service
After=network.target

[Service]
ExecStart=/usr/local/bin/decypharr --config /opt/decypharr/config
Restart=always
User=root
WorkingDirectory=/opt/decypharr

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now decypharr
"
}

cleanup() {
  msg "Cleaning up"
  pct exec "$CTID" -- bash -c "apt autoremove -y && apt clean"
}

done_msg() {
  LXC_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
  echo ""
  echo "✅ Decypharr LXC installed successfully!"
  echo "📡 LXC IP: $LXC_IP"
  echo "🌐 Web UI: http://$LXC_IP:$PORT"
  echo "📁 Config Path: /opt/decypharr/config"
  echo ""
}

# ----------------------
# Main
# ----------------------

header_info
check_root
check_proxmox
get_ctid
ensure_template
create_container
install_dependencies
install_decypharr_binary
setup_config
create_service
cleanup
done_msg
