#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../misc/build.func" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Community (copied for ProxmoxVED)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/bluesky-social/pds

APP="Bluesky PDS"
var_tags="${var_tags:-social;bluesky}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /pds ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "pds" "bluesky-social/pds"; then
    msg_info "Stopping PDS Service"
    systemctl stop pds || true
    msg_ok "Stopped Service"

    msg_info "Backing up Data"
    cp -r /pds /opt/pds_backup || true
    msg_ok "Backed up Data to /opt/pds_backup"

    msg_info "Attempting in-place update"
    if command -v pdsadmin >/dev/null 2>&1; then
      pdsadmin update || true
    else
      if [[ -d /opt/pds-src ]]; then
        msg_info "Pulling latest source in /opt/pds-src"
        git -C /opt/pds-src pull || true
        msg_info "Reinstalling node dependencies"
        cp -r /opt/pds-src/service /opt/pds-service || true
        cd /opt/pds-service
        corepack prepare --activate || true
        pnpm install --production --frozen-lockfile || true
        msg_ok "Rebuilt service from source"
      else
        msg_info "No local source found; fetching release tarball"
        CLEAN_INSTALL=1 fetch_and_deploy_gh_release "pds" "bluesky-social/pds" "tarball"
      fi
    fi

    msg_info "Starting PDS Service"
    systemctl start pds || true
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  else
    msg_ok "No new release detected"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}https://<your-domain> (HTTPS on port 443)${CL}"
