#!/usr/bin/env bash
#
# install-hermes-mikrus.sh
# Interactive installer for the Hermes agent (+ WebUI) on a Mikrus VPS.
# Native (uv) install, tuned for small boxes (Mikrus 3.0 = 2 GB RAM).
#
#   curl --proto '=https' --tlsv1.2 -fsSL <raw-url> -o install-hermes-mikrus.sh
#   bash install-hermes-mikrus.sh
#
# Flags:
#   --update         Update an already-installed stack (agent + WebUI together).
#   --reconfigure    Re-run the wizard without reinstalling.
#   --expose         (Re)run only the Mikrus exposure step (nginx + subdomain).
#   --uninstall      Remove the stack (delegates to uninstall-hermes-mikrus.sh).
#   --check-only     Run the capability check and exit (no changes).
#   --dry-run        Run the wizard + write config, but skip the heavy install.
#   --force          Proceed even if the capability check fails (test the limits).
#   --answers FILE   Non-interactive mode; read answers from FILE (ANS_* vars).
#   --service-user N Run the agent/WebUI/gateway as this account (default: hermes
#                    when installing as root). Created if missing.
#   --as-root        Do NOT drop to a service user; run as root (not recommended —
#                    the agent has a shell tool, so root = full blast radius).
#   --auto-update    Schedule a weekly `--update` (systemd timer, cron fallback).
#   --agent-version REF  Pin the agent to a git tag or commit (skips the version prompt).
#   --webui-version REF  Pin the WebUI to a git tag, branch or commit (skips the prompt).
#   -h, --help       Show this help.
#
# On start you are asked which version to install: latest release tag
# (recommended), bleeding-edge main/master, or a custom tag/commit — unless you
# pin with --agent-version / --webui-version.

set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

for m in common capability provider messaging webui mikrus; do
  # shellcheck source=/dev/null
  source "$LIB_DIR/$m.sh" 2>/dev/null || { echo "Missing module lib/$m.sh (run from the unpacked repo)"; exit 1; }
done

MODE="install"
FORCE="no"
ANSWERS_FILE=""
AS_ROOT="no"
SERVICE_USER=""
AUTO_UPDATE="no"
AGENT_REF=""            # git tag/commit for the agent ("" = installer default / main)
WEBUI_REF="master"      # git tag/branch/commit for the WebUI clone
VERSION_PINNED="no"     # set when --agent-version/--webui-version is passed
INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"
# SERVICE_HOME / HERMES_HOME / CONFIG_YAML / ENV_FILE / HERMES_BIN are set by
# resolve_identity() (they depend on the resolved service user).
SERVICE_HOME=""
HERMES_HOME="${HERMES_HOME:-}"
HERMES_BIN="hermes"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while (( $# )); do
    case "$1" in
      --update)      MODE="update" ;;
      --reconfigure) MODE="reconfigure" ;;
      --expose)      MODE="expose" ;;
      --uninstall)   MODE="uninstall" ;;
      --check-only)  MODE="check" ;;
      --dry-run)     MODE="dryrun" ;;
      --force)       FORCE="yes" ;;
      --answers)     shift; ANSWERS_FILE="${1:-}" ;;
      --answers=*)   ANSWERS_FILE="${1#*=}" ;;
      --as-root)     AS_ROOT="yes" ;;
      --service-user) shift; SERVICE_USER="${1:-}" ;;
      --service-user=*) SERVICE_USER="${1#*=}" ;;
      --auto-update) AUTO_UPDATE="yes" ;;
      --agent-version)  shift; AGENT_REF="${1:-}"; VERSION_PINNED="yes" ;;
      --agent-version=*) AGENT_REF="${1#*=}"; VERSION_PINNED="yes" ;;
      --webui-version)  shift; WEBUI_REF="${1:-}"; VERSION_PINNED="yes" ;;
      --webui-version=*) WEBUI_REF="${1#*=}"; VERSION_PINNED="yes" ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "Unknown flag: $1 (use --help)" ;;
    esac
    shift
  done
}

load_answers() {
  [[ -z "$ANSWERS_FILE" ]] && return 0
  [[ -r "$ANSWERS_FILE" ]] || die "Cannot read answers file: $ANSWERS_FILE"
  # Warn if the answers file (which may hold secrets and is executed via source)
  # is writable by others.
  local perm; perm="$(stat -c '%a' "$ANSWERS_FILE" 2>/dev/null || echo '')"
  [[ "$perm" =~ [2367]$ || "$perm" =~ ^.[2367] ]] && log_warn "Answers file $ANSWERS_FILE is group/world-writable — tighten with 'chmod 600'."
  # NOT `set -a`: we do not want ANS_* secrets exported into child processes
  # (e.g. the upstream installer). Plain `source` leaves them as shell vars,
  # which _answer() reads via ${!var}.
  # shellcheck source=/dev/null
  source "$ANSWERS_FILE"
  HERMES_INSTALL_NONINTERACTIVE=1
  log_info "Non-interactive mode (answers from $ANSWERS_FILE)."
}

banner() {
  log "${C_BOLD}Hermes on Mikrus — installer v${VERSION}${C_RESET}"
  log "${C_DIM}agent: NousResearch/hermes-agent · UI: nesquena/hermes-webui${C_RESET}"
}

# ---------------------------------------------------------------------------
# Service identity (run as a dedicated non-root user by default)
# ---------------------------------------------------------------------------

# Decide which account runs Hermes and derive all its paths. SERVICE_USER is
# read by as_user() to run steps unprivileged. When we're root and the operator
# didn't pass --as-root, we default to a dedicated 'hermes' account so the
# agent's shell/browser tools never run as root.
resolve_identity() {
  local cur; cur="$(id -un)"
  if [[ "$(id -u)" == "0" && "$AS_ROOT" != "yes" ]]; then
    SERVICE_USER="${SERVICE_USER:-hermes}"
  else
    SERVICE_USER="${SERVICE_USER:-$cur}"
  fi
  if [[ "$SERVICE_USER" == "$cur" ]]; then
    SERVICE_HOME="${HOME:?HOME must be set (or pass HERMES_HOME)}"
  else
    # getent exits 2 when the user does not exist yet — guard so `set -e`/pipefail
    # does not abort here (the user is created later by ensure_service_user).
    SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
    SERVICE_HOME="${SERVICE_HOME:-/home/$SERVICE_USER}"
  fi
  HERMES_HOME="${HERMES_HOME:-$SERVICE_HOME/.hermes}"
  CONFIG_YAML="$HERMES_HOME/config.yaml"
  ENV_FILE="$HERMES_HOME/.env"
  if [[ "$SERVICE_USER" != "$cur" ]]; then
    log_info "Running Hermes as dedicated user '${SERVICE_USER}' (use --as-root to override)."
  fi
}

# Create the service account if it does not exist (root only).
ensure_service_user() {
  [[ "$SERVICE_USER" == "$(id -un)" ]] && return 0
  if id "$SERVICE_USER" &>/dev/null; then
    log_ok "Service user '$SERVICE_USER' exists."
  else
    log_info "Creating service user '$SERVICE_USER'..."
    useradd --create-home --shell /bin/bash "$SERVICE_USER" \
      || die "Could not create service user '$SERVICE_USER' (need root)."
  fi
  SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6 || true)"
  SERVICE_HOME="${SERVICE_HOME:-/home/$SERVICE_USER}"
  HERMES_HOME="${HERMES_HOME:-$SERVICE_HOME/.hermes}"
  CONFIG_YAML="$HERMES_HOME/config.yaml"; ENV_FILE="$HERMES_HOME/.env"
}

# Give the service user ownership of everything we wrote as root.
fix_ownership() {
  [[ "$SERVICE_USER" == "$(id -un)" ]] && return 0
  chown -R "$SERVICE_USER":"$SERVICE_USER" "$HERMES_HOME" "$SERVICE_HOME/workspace" 2>/dev/null || true
}

# Resolve the hermes binary path for the resolved layout (per-user vs root FHS).
resolve_hermes_bin() {
  if   [[ -x "$SERVICE_HOME/.local/bin/hermes" ]]; then HERMES_BIN="$SERVICE_HOME/.local/bin/hermes"
  elif [[ -x /usr/local/bin/hermes ]];            then HERMES_BIN="/usr/local/bin/hermes"
  else HERMES_BIN="hermes"; fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

ensure_prereqs() {
  log_step "Checking prerequisites"
  local missing=()
  for c in curl git; do have_cmd "$c" || missing+=("$c"); done
  # xz-utils provides `xz`, needed by the upstream installer on Linux.
  have_cmd xz || missing+=("xz-utils")
  # The WebUI launcher (bootstrap.py / ctl.sh) needs a system python3 to boot
  # before re-execing under the agent venv. Usually present on Mikrus.
  have_cmd python3 || missing+=("python3")
  if (( ${#missing[@]} )); then
    log_info "Installing: ${missing[*]}"
    if have_cmd apt-get; then
      # Wait for a busy apt lock (Mikrus first-boot / unattended-upgrades) rather than failing.
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq "${missing[@]}" \
        || die "Could not install prerequisites: ${missing[*]}"
    else
      die "Missing ${missing[*]} and no apt-get to install them."
    fi
  fi
  log_ok "Prerequisites present."
}

agent_installed() {
  [[ -x "$SERVICE_HOME/.local/bin/hermes" || -x /usr/local/bin/hermes ]] && return 0
  as_user command -v hermes >/dev/null 2>&1
}

# The upstream installer lays code out differently for root vs non-root:
#   root  -> /usr/local/lib/hermes-agent   (data still in $HERMES_HOME)
#   user  -> $HERMES_HOME/hermes-agent
# The WebUI must be pointed at whichever exists, or its auto-discovery
# ($HERMES_HOME/hermes-agent) fails on a root install.
detect_agent_dir() {
  for d in "/usr/local/lib/hermes-agent" "$HERMES_HOME/hermes-agent"; do
    [[ -d "$d" ]] && { echo "$d"; return 0; }
  done
  echo ""
}

BROWSER_ENABLED="no"
decide_browser() {
  # Browser tools (Playwright/Chromium) are the memory hog. Off unless RAM is
  # comfortable or the user overrides. Decided BEFORE install so we can pass
  # --skip-browser to the upstream installer and save disk/time.
  ask_yesno ENABLE_BROWSER_TOOLS "Enable browser automation tools? (heavy on RAM; skips Playwright if off)" \
    "$([[ "$CAP_BROWSER_DEFAULT" == "on" ]] && echo Y || echo N)"
  BROWSER_ENABLED="$ENABLE_BROWSER_TOOLS"
  [[ "$BROWSER_ENABLED" == "yes" ]] \
    && log_warn "Browser tools enabled — expect higher memory use (≥2 GB recommended)." \
    || log_ok "Browser tools off (recommended on small boxes) — Playwright/Chromium skipped."
}

# Latest release tag for a GitHub repo (empty on failure). No jq dependency.
gh_latest_tag() {
  fetch "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' || true
}

# Ask which version to install: latest release tag (recommended), bleeding-edge
# main/master, or a custom tag/commit. Sets AGENT_REF + WEBUI_REF/WEBUI_BRANCH.
choose_version() {
  log_step "Version to install"
  # Pinned via --agent-version/--webui-version: skip the prompt, use them as given.
  if [[ "$VERSION_PINNED" == "yes" ]]; then
    WEBUI_BRANCH="${WEBUI_REF:-master}"
    log_ok "Pinned via flags — agent: ${AGENT_REF:-main}, WebUI: ${WEBUI_REF:-master}"
    return 0
  fi
  local VERSION_CHOICE=""
  ask_menu VERSION_CHOICE "Which version?" \
    "Latest release tag (recommended)" \
    "Bleeding edge (agent main / WebUI master)" \
    "Custom (enter a tag or commit)"
  case "$VERSION_CHOICE" in
    "Latest release tag"*)
      log_info "Resolving latest release tags from GitHub..."
      AGENT_REF="$(gh_latest_tag NousResearch/hermes-agent)"
      WEBUI_REF="$(gh_latest_tag nesquena/hermes-webui)"
      [[ -n "$AGENT_REF" ]] && log_ok "Agent: $AGENT_REF" || log_warn "Could not resolve agent tag — falling back to main."
      [[ -n "$WEBUI_REF" ]] && log_ok "WebUI: $WEBUI_REF" || WEBUI_REF="master"
      ;;
    "Bleeding edge"*)
      AGENT_REF=""; WEBUI_REF="master"
      log_ok "Using agent main / WebUI master (bleeding edge)."
      ;;
    *)
      ask AGENT_REF "Agent tag or commit (blank = main)" ""
      ask WEBUI_REF "WebUI tag or branch" "master"
      ;;
  esac
  WEBUI_BRANCH="${WEBUI_REF:-master}"   # consumed by webui.sh:webui_clone_or_update
}

install_agent() {
  log_step "Installing the Hermes agent (uv)"
  if agent_installed; then
    log_ok "Hermes agent already installed — skipping (use --update to upgrade)."
    return 0
  fi
  # Security: fetch over TLS1.2+/https-only, show provenance, then run.
  log_info "Downloading the official installer from ${INSTALLER_URL}"
  local tmp; tmp="$(mktemp)"
  fetch "$INSTALLER_URL" > "$tmp" || die "Failed to download the Hermes installer."
  log_info "Installer size: $(wc -c < "$tmp") bytes, sha256: $(sha256sum "$tmp" | cut -d' ' -f1)"
  # We run our own config wizard, so skip the upstream setup. Skip Playwright
  # unless the user opted into browser tools.
  local -a flags=(--skip-setup)
  [[ "$BROWSER_ENABLED" != "yes" ]] && flags+=(--skip-browser)
  # Pin the agent version if the user chose a tag/commit (git tags → --branch,
  # 7-40 hex → --commit, per the upstream installer's flags).
  if [[ -n "$AGENT_REF" ]]; then
    if [[ "$AGENT_REF" =~ ^[0-9a-f]{7,40}$ ]]; then flags+=(--commit "$AGENT_REF")
    else flags+=(--branch "$AGENT_REF"); fi
    log_info "Pinning agent to: $AGENT_REF"
  fi
  # Install AS the service user (per-user layout under its home), not root.
  chmod 755 "$tmp"   # the public installer must be readable/executable by the service user
  as_user env HOME="$SERVICE_HOME" HERMES_HOME="$HERMES_HOME" bash "$tmp" "${flags[@]}" </dev/null \
    || die "Hermes agent installer failed."
  rm -f "$tmp"
  resolve_hermes_bin
  agent_installed || die "Hermes binary not found after install."
  log_ok "Hermes agent installed (as ${SERVICE_USER})."
}

configure_stack() {
  log_step "Configuration"
  mkdir -pm 700 "$HERMES_HOME" 2>/dev/null || mkdir -p "$HERMES_HOME"
  chmod 700 "$HERMES_HOME"
  [[ -f "$ENV_FILE" ]] || { : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }

  configure_provider "$CONFIG_YAML" "$ENV_FILE"
  set_env_var "$ENV_FILE" HERMES_ENABLE_BROWSER_TOOLS "$([[ "$BROWSER_ENABLED" == "yes" ]] && echo true || echo false)"
  configure_messaging "$ENV_FILE"
}

install_ui_and_services() {
  # The systemd units grant ReadWritePaths=$SERVICE_HOME/workspace; make sure it
  # exists (default WebUI workspace) or ProtectHome=read-only blocks the agent.
  mkdir -p "$SERVICE_HOME/workspace"
  webui_clone_or_update || return 1
  # Point the WebUI at the actual agent code dir (root vs user layout differ).
  local agent_dir; agent_dir="$(detect_agent_dir)"
  if [[ -n "$agent_dir" ]]; then
    set_env_var "$ENV_FILE" HERMES_WEBUI_AGENT_DIR "$agent_dir"
    # Symlink so the WebUI's own auto-discovery ($HERMES_HOME/hermes-agent) works
    # with ZERO environment variables — no manual `export` needed to run ctl.sh.
    if [[ "$agent_dir" != "$HERMES_HOME/hermes-agent" && ! -e "$HERMES_HOME/hermes-agent" ]]; then
      ln -s "$agent_dir" "$HERMES_HOME/hermes-agent" && log_ok "Linked $HERMES_HOME/hermes-agent → $agent_dir"
    fi
    log_ok "WebUI will use agent at: $agent_dir"
  else
    log_warn "Could not locate the agent code dir — WebUI auto-discovery may fail."
  fi
  webui_set_password "$ENV_FILE"
  webui_configure "$ENV_FILE" 8787
  # Hand everything to the service user BEFORE starting services so they run
  # with the right ownership.
  fix_ownership
  webui_install_services "$SERVICE_USER" "$SERVICE_HOME" "$ENV_FILE" "$HERMES_BIN"
}

# Opt-in: schedule a weekly `--update` (systemd timer preferred, cron fallback).
install_auto_update() {
  [[ "$AUTO_UPDATE" == "yes" ]] || return 0
  log_step "Scheduling weekly auto-update"
  local self="$SCRIPT_DIR/install-hermes-mikrus.sh"
  if systemd_running; then
    local ud="/usr/lib/systemd/system"; [[ -d "$ud" ]] || ud="/etc/systemd/system"
    cat > "$ud/hermes-update.service" <<EOF
[Unit]
Description=Hermes stack auto-update (agent + WebUI)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${self} --update
EOF
    cat > "$ud/hermes-update.timer" <<EOF
[Unit]
Description=Weekly Hermes stack auto-update

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || true
    systemctl enable --now hermes-update.timer 2>/dev/null \
      && log_ok "Auto-update on (systemd timer, weekly). Off: systemctl disable --now hermes-update.timer" \
      || log_warn "Could not enable hermes-update.timer."
  elif have_cmd crontab; then
    local line="0 4 * * 0 bash ${self} --update >> ${HERMES_HOME}/update.log 2>&1"
    { crontab -l 2>/dev/null | grep -vF -- "--update" || true; echo "$line"; } | crontab - \
      && log_ok "Auto-update on (cron, Sundays 04:00)." \
      || log_warn "Could not install cron entry."
  else
    log_warn "No systemd or cron available — cannot schedule auto-update."
  fi
}

print_summary() {
  log_step "Done"
  log_ok "Hermes stack installed."
  [[ -n "${PUBLIC_URL:-}" ]] && log "  WebUI  : ${C_BOLD}${PUBLIC_URL}${C_RESET}"
  log "  Runs as: ${C_BOLD}${SERVICE_USER}${C_RESET} (non-root)"
  log "  Config : $CONFIG_YAML"
  log "  Secrets: $ENV_FILE (mode 600)"
  local as_prefix=""
  [[ "$SERVICE_USER" != "$(id -un)" ]] && as_prefix="runuser -u ${SERVICE_USER} -- "
  log "  Chat   : ${as_prefix}$HERMES_BIN"
  if systemd_running; then
    log "  Services: systemctl status hermes-gateway hermes-webui"
    log "  Logs    : journalctl -u hermes-webui -f"
  else
    # No systemd (e.g. inside a container): the symlink above lets ctl.sh run
    # with no exported env vars.
    log "  Start WebUI : ${as_prefix}$HERMES_HOME/hermes-webui/ctl.sh start"
    log "  Start bridges: ${as_prefix}$HERMES_BIN gateway run"
  fi
}

do_install() {
  local dry="$1"
  detect_capabilities
  report_capabilities "$FORCE" || exit 1
  decide_browser
  if [[ "$dry" == "yes" ]]; then
    log_warn "DRY RUN — writing config only, skipping agent/UI/services/exposure."
    configure_stack
    webui_set_password "$ENV_FILE"
    webui_configure "$ENV_FILE" 8787
    log_ok "Dry run complete. Inspect $CONFIG_YAML and $ENV_FILE."
    return 0
  fi
  ensure_prereqs
  choose_version
  ensure_service_user
  install_agent
  local CONTINUE_CONFIG=""
  ask_yesno CONTINUE_CONFIG "Agent installed. Continue with configuration (AI provider, bridges, WebUI)?" Y
  if [[ "$CONTINUE_CONFIG" != "yes" ]]; then
    fix_ownership
    log_info "Stopping after agent install. Configure later with:  bash $SCRIPT_DIR/install-hermes-mikrus.sh --reconfigure"
    exit 0
  fi
  configure_stack
  fix_ownership              # hand config to the service user so 'hermes doctor' can read it
  validate_provider_config
  install_ui_and_services
  if mikrus_expose_webui 8787; then
    harden_webui_for_proxy
  else
    log_warn "Exposure step incomplete — see notes above."
  fi
  install_auto_update
  print_summary
  if [[ "${DEFER_HERMES_SETUP:-no}" == "yes" ]]; then
    log_warn "Provider deferred — run 'hermes setup' to finish AI configuration."
  fi
  return 0
}

do_reconfigure() {
  agent_installed || die "Hermes is not installed. Run without --reconfigure first."
  configure_stack
  webui_set_password "$ENV_FILE"
  webui_configure "$ENV_FILE" 8787
  fix_ownership
  validate_provider_config
  if systemd_running; then systemctl restart hermes-gateway hermes-webui 2>/dev/null || true; fi
  log_ok "Reconfigured${SERVICE_USER:+ (runs as $SERVICE_USER)}."
}

# Once exposed behind the public HTTPS proxy, harden the WebUI: enable passkeys,
# Secure cookies, trust the forwarded proto, and allow the public origin(s).
harden_webui_for_proxy() {
  [[ -n "${PUBLIC_ORIGINS:-}" ]] || return 0
  webui_secure_behind_proxy "$ENV_FILE" "$PUBLIC_ORIGINS"
  fix_ownership
  if systemd_running; then systemctl restart hermes-webui 2>/dev/null || true; fi
}

do_expose() {
  agent_installed || die "Hermes is not installed — run the installer first."
  detect_capabilities            # sets MIKRUS_DETECTED / MIKRUS_SERVER / MIKRUS_ID
  mikrus_expose_webui 8787 || die "Exposure failed — see the notes above."
  harden_webui_for_proxy
  [[ -n "${PUBLIC_URL:-}" ]] && log_ok "WebUI exposed at ${PUBLIC_URL}"
}

do_update() {
  agent_installed || die "Nothing to update — Hermes is not installed."
  log_step "Updating the Hermes stack"
  # Back up config + secrets first (preserve mode).
  local stamp backup
  stamp="$(hostname)-update"
  backup="$HERMES_HOME/backup-$stamp"
  mkdir -pm 700 "$backup" 2>/dev/null || { mkdir -p "$backup"; chmod 700 "$backup"; }
  [[ -f "$CONFIG_YAML" ]] && cp -p "$CONFIG_YAML" "$backup/"
  [[ -f "$ENV_FILE" ]] && cp -p "$ENV_FILE" "$backup/"
  log_ok "Backed up config + secrets to $backup"

  # Upgrade both together (compatibility policy of the WebUI). Mirror the
  # install flags: skip the interactive setup, keep the original browser choice,
  # and feed /dev/null so the upstream installer never blocks on a prompt.
  log_info "Upgrading the agent (re-running the official installer)..."
  local -a uflags=(--skip-setup)
  grep -q '^HERMES_ENABLE_BROWSER_TOOLS=true' "$ENV_FILE" 2>/dev/null || uflags+=(--skip-browser)
  local tmp; tmp="$(mktemp)"; chmod 755 "$tmp"
  if fetch "$INSTALLER_URL" > "$tmp"; then
    as_user env HOME="$SERVICE_HOME" HERMES_HOME="$HERMES_HOME" bash "$tmp" "${uflags[@]}" </dev/null \
      || log_warn "Agent update step failed."
  else
    log_warn "Could not download the installer."
  fi
  rm -f "$tmp"
  webui_clone_or_update || log_warn "WebUI update step failed."
  fix_ownership

  if systemd_running; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart hermes-gateway hermes-webui 2>/dev/null || true
  fi

  validate_provider_config

  # Post-update health probe.
  if have_cmd curl; then
    if curl -fsS -m 5 http://127.0.0.1:8787/health >/dev/null 2>&1; then
      log_ok "WebUI healthy after update (/health OK)."
    else
      log_warn "WebUI /health did not respond yet — check 'journalctl -u hermes-webui'."
    fi
  fi
  log_ok "Update complete."
}

main() {
  parse_args "$@"
  load_answers
  banner
  # Dry run must not create a system account or write into another user's home.
  [[ "$MODE" == "dryrun" ]] && AS_ROOT="yes"
  resolve_identity
  resolve_hermes_bin

  case "$MODE" in
    check)       detect_capabilities; report_capabilities "$FORCE"; exit $? ;;
    uninstall)   exec bash "$SCRIPT_DIR/uninstall-hermes-mikrus.sh" ${ANSWERS_FILE:+--answers "$ANSWERS_FILE"} ;;
    update)      do_update ;;
    reconfigure) do_reconfigure ;;
    expose)      do_expose ;;
    dryrun)      do_install "yes" ;;
    install)     do_install "no" ;;
  esac
}

main "$@"
