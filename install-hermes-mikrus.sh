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

HERMES_HOME="${HERMES_HOME:-${HOME:?HOME must be set (or pass HERMES_HOME)}/.hermes}"
CONFIG_YAML="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"

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
# Steps
# ---------------------------------------------------------------------------

ensure_prereqs() {
  log_step "Checking prerequisites"
  local missing=()
  for c in curl git; do have_cmd "$c" || missing+=("$c"); done
  # xz-utils provides `xz`, needed by the upstream installer on Linux.
  have_cmd xz || missing+=("xz-utils")
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

agent_installed() { [[ -x "$HOME/.local/bin/hermes" || -x /usr/local/bin/hermes ]] || have_cmd hermes; }

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
  bash "$tmp" "${flags[@]}" </dev/null || die "Hermes agent installer failed."
  rm -f "$tmp"
  agent_installed || die "Hermes binary not found after install."
  log_ok "Hermes agent installed."
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
  # The systemd units grant ReadWritePaths=$HOME/workspace; make sure it exists
  # (default WebUI workspace) or ProtectHome=read-only blocks the agent.
  mkdir -p "$HOME/workspace"
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
  local user; user="$(id -un)"
  webui_install_services "$user" "$HOME" "$ENV_FILE"
}

print_summary() {
  log_step "Done"
  log_ok "Hermes stack installed."
  [[ -n "${PUBLIC_URL:-}" ]] && log "  WebUI  : ${C_BOLD}${PUBLIC_URL}${C_RESET}"
  log "  Config : $CONFIG_YAML"
  log "  Secrets: $ENV_FILE (mode 600)"
  log "  Chat   : hermes"
  if systemd_running; then
    log "  Services: systemctl status hermes-gateway hermes-webui"
    log "  Logs    : journalctl -u hermes-webui -f"
  else
    # No systemd (e.g. inside a container): the symlink above lets ctl.sh run
    # with no exported env vars.
    log "  Start WebUI : $HERMES_HOME/hermes-webui/ctl.sh start"
    log "  Start bridges: hermes gateway run"
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
  install_agent
  local CONTINUE_CONFIG=""
  ask_yesno CONTINUE_CONFIG "Agent installed. Continue with configuration (AI provider, bridges, WebUI)?" Y
  if [[ "$CONTINUE_CONFIG" != "yes" ]]; then
    log_info "Stopping after agent install. Configure later with:  bash $SCRIPT_DIR/install-hermes-mikrus.sh --reconfigure"
    exit 0
  fi
  configure_stack
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
  if have_cmd systemctl; then systemctl restart hermes-gateway hermes-webui 2>/dev/null || true; fi
  log_ok "Reconfigured. Services restarted."
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
  local tmp; tmp="$(mktemp)"
  fetch "$INSTALLER_URL" > "$tmp" && bash "$tmp" "${uflags[@]}" </dev/null || log_warn "Agent update step failed."
  rm -f "$tmp"
  webui_clone_or_update || log_warn "WebUI update step failed."

  if have_cmd systemctl; then
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
