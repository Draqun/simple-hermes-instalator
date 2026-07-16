#!/usr/bin/env bash
#
# uninstall-hermes-mikrus.sh — remove the Hermes stack installed by
# install-hermes-mikrus.sh. Data in ~/.hermes (memories, sessions, config) is
# preserved by default; you are asked before anything destructive.
#
# Flags:
#   --purge          Also delete ~/.hermes (ALL data + secrets). Irreversible.
#   --answers FILE   Non-interactive mode (ANS_* vars; e.g. ANS_PURGE=yes).
#   -h, --help       Show this help.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null || { echo "Missing lib/common.sh"; exit 1; }

HERMES_HOME="${HERMES_HOME:-${HOME:?HOME must be set (or pass HERMES_HOME)}/.hermes}"
PURGE="no"; ANSWERS_FILE=""

while (( $# )); do
  case "$1" in
    --purge)     PURGE="yes" ;;
    --answers)   shift; ANSWERS_FILE="${1:-}" ;;
    --answers=*) ANSWERS_FILE="${1#*=}" ;;
    -h|--help)   sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "Unknown flag: $1" ;;
  esac
  shift
done

if [[ -n "$ANSWERS_FILE" && -r "$ANSWERS_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ANSWERS_FILE"   # no `set -a`: keep ANS_* out of child environments
  HERMES_INSTALL_NONINTERACTIVE=1
fi

log_step "Stopping and removing services"
if [[ -d /run/systemd/system ]] && have_cmd systemctl; then
  systemctl disable --now hermes-update.timer 2>/dev/null || true
  for svc in hermes-webui hermes-gateway; do
    systemctl disable --now "$svc" 2>/dev/null || true
  done
  for ud in /usr/lib/systemd/system /etc/systemd/system; do
    rm -f "$ud/hermes-gateway.service" "$ud/hermes-webui.service" \
          "$ud/hermes-update.service" "$ud/hermes-update.timer"
  done
  systemctl daemon-reload 2>/dev/null || true
  log_ok "systemd services + auto-update timer removed."
else
  log_info "systemd not present — nothing to disable."
  # cron fallback: drop any auto-update line we added.
  have_cmd crontab && { crontab -l 2>/dev/null | grep -vF -- '--update' | crontab - 2>/dev/null || true; }
fi

log_step "Removing the reverse proxy site"
rm -f /etc/nginx/sites-available/hermes-webui /etc/nginx/sites-enabled/hermes-webui 2>/dev/null || true
if have_cmd nginx; then nginx -t >/dev/null 2>&1 && { nginx -s reload 2>/dev/null || true; }; fi
log_ok "nginx site removed (nginx itself left installed)."

log_step "Data directory"
if [[ "$PURGE" != "yes" ]]; then
  local_purge=""
  ask_yesno local_purge "Delete ALL Hermes data in $HERMES_HOME (memories, sessions, secrets)?" N
  [[ "$local_purge" == "yes" ]] && PURGE="yes"
fi
if [[ "$PURGE" == "yes" ]]; then
  rm -rf "$HERMES_HOME"
  log_ok "Removed $HERMES_HOME."
else
  log_info "Kept $HERMES_HOME (agent code, config, memories). Delete manually or re-run with --purge."
fi

log_ok "Uninstall complete."
