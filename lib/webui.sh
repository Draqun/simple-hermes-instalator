#!/usr/bin/env bash
# webui.sh — install the Hermes WebUI and set up long-running services.
#
# Topology (native install):
#   * hermes-gateway.service : `hermes gateway run` — the always-on agent that
#     drives messaging bridges and runs scheduled/cron jobs 24/7.
#   * hermes-webui.service   : the browser UI (nesquena/hermes-webui), which
#     imports the agent in-process. Bound to 127.0.0.1; nginx (mikrus.sh) fronts
#     it. A password is mandatory because the box has public IPv6 on all ports.
#
# The WebUI is NOT vendored/pip-installed by us — it discovers the agent via
# $HERMES_HOME/hermes-agent and runs under the agent's own venv Python.

WEBUI_REPO="https://github.com/nesquena/hermes-webui.git"
WEBUI_BRANCH="master"

# webui_dir -> where we clone the WebUI (next to the agent, per its discovery).
webui_dir() { echo "${HERMES_HOME:-$HOME/.hermes}/hermes-webui"; }

webui_clone_or_update() {
  local dir; dir="$(webui_dir)"
  if [[ -d "$dir/.git" ]]; then
    log_info "Updating hermes-webui..."
    git -C "$dir" pull --ff-only --quiet || log_warn "Could not fast-forward hermes-webui."
  else
    log_info "Cloning hermes-webui..."
    git clone --depth 1 --branch "$WEBUI_BRANCH" "$WEBUI_REPO" "$dir" --quiet \
      || { log_warn "Clone failed."; return 1; }
  fi
  log_ok "hermes-webui at $dir"
}

# webui_set_password ENV_FILE -> ensures a WebUI password exists (mandatory).
# On an empty answer: reuse the existing password if one is already set (so a
# re-run / --reconfigure does not invalidate a working login), else generate a
# strong one and print it once.
webui_set_password() {
  local env_file="$1" pw="" existing="" HERMES_WEBUI_PASSWORD=""
  ask_secret HERMES_WEBUI_PASSWORD "WebUI password (leave empty to keep/auto-generate)"
  pw="$HERMES_WEBUI_PASSWORD"
  if [[ -z "$pw" ]]; then
    existing="$(grep -E '^HERMES_WEBUI_PASSWORD=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [[ -n "$existing" ]]; then
      pw="$existing"
      log_ok "Kept the existing WebUI password."
    else
      pw="$(gen_password)"
      log_warn "Generated WebUI password (save it now — shown only once): ${C_BOLD}${pw}${C_RESET}"
    fi
  fi
  set_env_var "$env_file" HERMES_WEBUI_PASSWORD "$pw"
}

# webui_configure ENV_FILE PORT -> writes WebUI bind settings (loopback only).
webui_configure() {
  local env_file="$1" port="${2:-8787}"
  set_env_var "$env_file" HERMES_WEBUI_HOST "127.0.0.1"
  set_env_var "$env_file" HERMES_WEBUI_PORT "$port"
  log_ok "WebUI bound to 127.0.0.1:${port} (public access via the reverse proxy only)."
}

# --- systemd units (pure render functions; content is unit-testable) --------

render_gateway_unit() {
  local user="$1" home="$2"
  cat <<EOF
[Unit]
Description=Hermes agent gateway (messaging bridges + scheduled jobs)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Environment=HERMES_HOME=${home}/.hermes
ExecStart=${home}/.local/bin/hermes gateway run
Restart=on-failure
RestartSec=5
# --- hardening ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${home}/.hermes ${home}/workspace
PrivateTmp=yes
ProtectControlGroups=yes
ProtectKernelTuning=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
PrivateDevices=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictRealtime=yes
RestrictNamespaces=yes
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

render_webui_unit() {
  local user="$1" home="$2" env_file="$3" webui_dir="$4"
  cat <<EOF
[Unit]
Description=Hermes WebUI (browser chat interface)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=${user}
Environment=HERMES_HOME=${home}/.hermes
EnvironmentFile=${env_file}
WorkingDirectory=${webui_dir}
ExecStart=/usr/bin/env bash ${webui_dir}/start.sh
Restart=on-failure
RestartSec=5
# --- hardening ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${home}/.hermes ${home}/workspace
PrivateTmp=yes
ProtectControlGroups=yes
ProtectKernelTuning=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
PrivateDevices=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictRealtime=yes
RestrictNamespaces=yes
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

# True only when the box actually booted with systemd (not just has the binary,
# which is the case inside a plain Docker container).
systemd_running() { [[ -d /run/systemd/system ]] && have_cmd systemctl; }

# Install + enable + start both services (root, system units).
webui_install_services() {
  local user="$1" home="$2" env_file="$3"
  local dir; dir="$(webui_dir)"
  if ! systemd_running; then
    log_warn "systemd not running here — services not installed."
    log_info "Start the WebUI manually with: $dir/ctl.sh start   (and 'hermes gateway run' for bridges)."
    return 0
  fi
  local ud="/usr/lib/systemd/system"
  [[ -d "$ud" ]] || ud="/etc/systemd/system"
  render_gateway_unit "$user" "$home"                   > "$ud/hermes-gateway.service"
  render_webui_unit   "$user" "$home" "$env_file" "$dir" > "$ud/hermes-webui.service"
  systemctl daemon-reload || { log_warn "daemon-reload failed."; return 1; }
  systemctl enable --now hermes-gateway.service 2>/dev/null || log_warn "Could not start hermes-gateway."
  systemctl enable --now hermes-webui.service   2>/dev/null || log_warn "Could not start hermes-webui."
  log_ok "systemd services installed (hermes-gateway, hermes-webui)."
}
