#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Community (copied for ProxmoxVED)
# License: MIT | https://github.com/bluesky-social/pds
# Source: https://github.com/bluesky-social/pds

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

PDS_DATADIR="/pds"
PDS_SRC_DIR="/opt/pds-src"
PDS_SERVICE_DIR="/opt/pds-service"
PDS_GIT_REPO="https://github.com/bluesky-social/pds.git"
PDSADMIN_URL="https://raw.githubusercontent.com/bluesky-social/pds/main/pdsadmin.sh"

: "${PDS_HOSTNAME:=$(whiptail --inputbox "Enter your public DNS address (e.g. example.com):" 8 60 3>&1 1>&2 2>&3)}"
: "${PDS_ADMIN_EMAIL:=$(whiptail --inputbox "Enter an admin email address (e.g. you@example.com):" 8 60 3>&1 1>&2 2>&3)}"

msg_info "Installing build and runtime packages"
$STD apt update
$STD apt install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  lsb-release \
  openssl \
  pkg-config \
  python3 \
  python3-dev \
  libsqlite3-dev \
  sqlite3 \
  xxd \
  gnupg
msg_ok "Installed packages"

msg_info "Installing Node.js (v24)"
NODE_VERSION="24" setup_nodejs
msg_ok "Node.js installed"

msg_info "Enabling corepack and preparing pnpm"
corepack enable
corepack prepare --activate
msg_ok "Corepack prepared"

msg_info "Installing Go"
GO_VERSION="1.22" setup_go
msg_ok "Go installed"

msg_info "Creating PDS directories"
mkdir -p ${PDS_DATADIR}
chmod 700 ${PDS_DATADIR}
mkdir -p ${PDS_DATADIR}/caddy/data
mkdir -p ${PDS_DATADIR}/caddy/etc/caddy
msg_ok "Created data directories"

msg_info "Cloning PDS source"
rm -rf ${PDS_SRC_DIR} ${PDS_SERVICE_DIR}
$STD git clone --depth 1 "${PDS_GIT_REPO}" "${PDS_SRC_DIR}"
$STD cp -r "${PDS_SRC_DIR}/service" "${PDS_SERVICE_DIR}"
msg_ok "Cloned PDS source to ${PDS_SRC_DIR}"

msg_info "Installing service dependencies (pnpm)"
cd "${PDS_SERVICE_DIR}"
# Use pnpm via corepack
$STD pnpm install --production --frozen-lockfile
msg_ok "Installed service dependencies"

msg_info "Building goat admin tool"
cd /tmp
rm -rf /tmp/goat-build
$STD git clone --depth 1 https://github.com/bluesky-social/goat.git /tmp/goat-src
cd /tmp/goat-src
$STD GOPATH=/tmp/go_build GO111MODULE=on go build -o /usr/local/bin/goat .
chmod +x /usr/local/bin/goat || true
msg_ok "Built goat into /usr/local/bin/goat"

msg_info "Generating PDS environment config"
PDS_ADMIN_PASSWORD=$(openssl rand -hex 16)
PDS_JWT_SECRET=$(openssl rand -hex 16)
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32)
cat <<PDS_CONFIG >"${PDS_DATADIR}/pds.env"
PDS_HOSTNAME=${PDS_HOSTNAME}
PDS_JWT_SECRET=${PDS_JWT_SECRET}
PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX}
PDS_DATA_DIRECTORY=${PDS_DATADIR}
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_BLOB_UPLOAD_LIMIT=104857600
PDS_DID_PLC_URL=https://plc.directory
PDS_BSKY_APP_VIEW_URL=https://api.bsky.app
PDS_BSKY_APP_VIEW_DID=did:web:api.bsky.app
PDS_REPORT_SERVICE_URL=https://mod.bsky.app
PDS_REPORT_SERVICE_DID=did:plc:ar7c4by46qjdydhdevvrndac
PDS_CRAWLERS=https://bsky.network
LOG_ENABLED=true
PDS_RATE_LIMITS_ENABLED=true
PDS_INVITE_REQUIRED=true
PDS_CONFIG
PDS_ADMIN_PASSWORD="${PDS_ADMIN_PASSWORD}"
PDS_CONFIG
msg_ok "Created PDS environment file at ${PDS_DATADIR}/pds.env"

msg_info "Installing Caddy (reverse proxy)"
if ! $STD apt install -y caddy >/dev/null 2>&1; then
  msg_info "apt install caddy failed, attempting to download binary"
  ARCH=$(dpkg --print-architecture)
  if [[ "$ARCH" == "amd64" ]]; then
    ARCH_DL="linux-amd64"
  else
    ARCH_DL="linux-arm64"
  fi
  $STD curl -fsSL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_${ARCH_DL}.tar.gz" -o /tmp/caddy.tar.gz
  mkdir -p /tmp/caddy && tar -xzf /tmp/caddy.tar.gz -C /tmp/caddy
  $STD mv /tmp/caddy/caddy /usr/local/bin/caddy
  chmod +x /usr/local/bin/caddy
fi
msg_ok "Caddy installed or available"

msg_info "Writing Caddyfile (listening on 8080/8443 inside container)"
cat <<CADDYFILE >/etc/caddy/Caddyfile
{
	email ${PDS_ADMIN_EMAIL}
	on_demand_tls {
		ask http://localhost:3000/tls-check
	}
}

*.${PDS_HOSTNAME}:8443, ${PDS_HOSTNAME}:8443 {
	tls {
		on_demand
	}
	reverse_proxy http://localhost:3000
}

*.${PDS_HOSTNAME}:8080, ${PDS_HOSTNAME}:8080 {
	reverse_proxy http://localhost:3000
}
CADDYFILE

msg_ok "Wrote /etc/caddy/Caddyfile (ports 8080/8443)"

msg_info "Creating systemd service for pds"
cat <<SYSTEMD_UNIT_FILE >/etc/systemd/system/pds.service
[Unit]
Description=Bluesky PDS Service
Documentation=https://github.com/bluesky-social/pds
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${PDS_SERVICE_DIR}
EnvironmentFile=${PDS_DATADIR}/pds.env
ExecStart=/usr/bin/node --enable-source-maps index.ts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD_UNIT_FILE

systemctl daemon-reload
systemctl enable --now pds
msg_ok "Created and started pds service"

msg_info "Installing pdsadmin"
$STD curl -fsSL "${PDSADMIN_URL}" -o /usr/local/bin/pdsadmin
chmod +x /usr/local/bin/pdsadmin
msg_ok "Installed pdsadmin"

cat <<SUMMARY
========================================================================
PDS installation successful!
------------------------------------------------------------------------
Service status: systemctl status pds
Logs: journalctl -u pds -f
Data directory: ${PDS_DATADIR}
PDS Admin command: /usr/local/bin/goat pds admin

The PDS and Caddy are configured to listen on high ports inside the container:
 - HTTP : 8080
 - HTTPS: 8443

Because this container runs unprivileged, forward host ports 80->8080 and 443->8443 to the container.
Example (on host):
  iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination <container-ip>:8080
  iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination <container-ip>:8443

Detected public DNS: ${PDS_HOSTNAME}
To create an account run: pdsadmin account create
========================================================================
SUMMARY

motd_ssh
customize
cleanup_lxc
