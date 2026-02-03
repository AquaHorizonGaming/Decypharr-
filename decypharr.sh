#!/usr/bin/env bash
# Copyright (c) community-scripts
# Author: LostMedia
# License: MIT

set -euo pipefail

APP="Decypharr"
HOSTNAME="decypharr"
MEMORY="1024"
CORES="2"
DISK_SIZE="8G"
PORT="8282"
REPO="sirrobot01/decypharr"
TEMPLATE="local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst"

# ----------------------
# Helper Functions
# ----------------------

function header_info {
  cat <<EOF
==============================
  Decypharr LXC Installer
==============================
EOF
}

function error_exit {
  echo "❌ ERROR: $1"
  exit 1
}

function msg {
  echo -e "➡️ $1"
}

function check_root {
  [[ "$(id -u)" -ne 0 ]] && error_exit "Run this script as root on the Proxmox host"
}

function get_ctid {
  while true; do
    read -rp "Enter CTID to use for Decypharr LXC: " CTID

    [[ -z "$CTID" ]] && echo "CTID cannot be empty." && continue
    [[ ! "$CTID" =~ ^[0-9]+$ ]] && echo "CTID must be a number." && continue

    if pct status "$CTID" &>/dev/null; then
      echo "CTID $CTID already exists. Choose another."
    else
      break
    fi
  done
}

# ----------------------
# LXC Creation
# ----------------------

function create_container {
  msg "Creating LXC container (CTID: $CTID)"

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs local-lvm:"$DISK_SIZE" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --onboot 1 \
    --unprivileged 1 \
    --features nesting=1

  pct start "$CTID"
}

# ----------------------
# Inside-Container Setup
# ----------------------

function install_dependencies {
  msg "Installing dependencies inside container"

  pct exec "$CTID" -- bash -c "
    apt update &&
    apt install -y curl jq ca-certificates
  "
}

function install_decypharr_binary {
  msg "Downloading Decypharr binary"

  pct exec "$CTID" -- bash -c "
    ARCH=\$(dpkg --print-architecture)

    case \"\$ARCH\" in
      amd64) BIN=decypharr-linux-amd64 ;;
      arm64) BIN=decypharr-linux-arm64 ;;
      *) echo 'Unsupported architecture'; exit 1 ;;
    esac

    VERSION=\$(curl -fsSL https://api.github.com/repos/${REPO}/releases/latest | jq -r .tag_name)

    curl -fsSL \
      https://github.com/${REPO}/releases/download/\$VERSION/\$BIN \
      -o /usr/local/bin/decypharr

    chmod +x /usr/local/bin/decypharr
  "
}

function setup_config {
  msg "Creating config directory"

  pct exec "$CTID" -- bash -c "
    mkdir -p /opt/decypharr/config
  "
}

function create_service {
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

function cleanup {
  msg "Cleaning up"

  pct exec "$CTID" -- bash -c "
    apt autoremove -y
    apt clean
  "
}

function done_msg {
  echo ""
  echo "✅ Decypharr LXC installed successfully!"
  echo "🌐 Web UI: http://<LXC-IP>:${PORT}"
  echo "📁 Config Path: /opt/decypharr/config"
  echo ""
}

# ----------------------
# Main
# ----------------------

header_info
check_root
get_ctid
create_container
install_dependencies
install_decypharr_binary
setup_config
create_service
cleanup
done_msg
