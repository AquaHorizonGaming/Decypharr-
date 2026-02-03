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
OS="debian"
OS_VERSION="12"
PORT="8282"
REPO="sirrobot01/decypharr"

function header_info {
  clear
  cat <<EOF
==============================
  Decypharr LXC Installer
==============================
EOF
}

function error_exit {
  echo "❌ $1"
  exit 1
}

function msg {
  echo -e "➡️ $1"
}

function check_root {
  [[ "$(id -u)" -ne 0 ]] && error_exit "Run as root on Proxmox host"
}

function get_next_ctid {
  CTID=$(pvesh get /cluster/nextid)
}

function create_container {
  msg "Creating LXC container ($CTID)"

  pct create "$CTID" local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs local-lvm:"$DISK_SIZE" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --features nesting=1 \
    --onboot 1 \
    --unprivileged 1

  pct start "$CTID"
}

function install_dependencies {
  msg "Installing dependencies"

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

    VERSION=\$(curl -s https://api.github.com/repos/${REPO}/releases/latest | jq -r .tag_name)

    curl -L \
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
  echo "✅ Decypharr installed successfully!"
  echo "🌐 Web UI: http://<LXC-IP>:${PORT}"
  echo "📁 Config Path: /opt/decypharr/config"
  echo ""
}

# ---- Main ----
header_info
check_root
get_next_ctid
create_container
install_dependencies
install_decypharr_binary
setup_config
create_service
cleanup
done_msg
