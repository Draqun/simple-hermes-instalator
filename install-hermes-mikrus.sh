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
#   --uninstall      Remove the stack (delegates to uninstall-hermes-mikrus.sh).
#   --check-only     Run the capability check and exit (no changes).
#   --dry-run        Run the wizard + write config, but skip the heavy install.
#   --force          Proceed even if the capability check fails (test the limits).
#   --answers FILE   Non-interactive mode; read answers from FILE (ANS_* vars).
#   --service-user N Run the agent/WebUI/gateway as this account (default: hermes
#                    when installing as root). Created if missing.
#   --as-root        Do NOT drop to a service user; run as root (not recommended —
#                    the agent has a shell tool, so root = full blast radius).
#   -h, --help       Show this help.

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
      --uninstall)   MODE="uninstall" ;;
      --check-only)  MODE="check" ;;
      --dry-run)     MODE="dryrun" ;;
      --force)       FORCE="yes" ;;
      --answers)     shift; ANSWERS_FILE="${1:-}" ;;
      --answers=*)   ANSWERS_FILE="${1#*=}" ;;
      --as-root)     AS_ROOT="yes" ;;
      --service-user) shift; SERVICE_USER="${1:-}" ;;
      --service-user=*) SERVICE_USER="${1#*=}" ;;
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
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
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
  mikrus_expose_webui 8787 || log_warn "Exposure step incomplete — see notes above."
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
    dryrun)      do_install "yes" ;;
    install)     do_install "no" ;;
  esac
}

main "$@"
