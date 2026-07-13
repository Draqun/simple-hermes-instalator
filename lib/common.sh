#!/usr/bin/env bash
# common.sh — shared helpers for the Hermes-on-Mikrus installer.
# Sourced by install-hermes-mikrus.sh and the lib/* modules.
#
# Design goals:
#   - No secrets ever reach argv / ps / shell history / logs.
#   - Works interactively (prompts) and non-interactively (--answers FILE),
#     so the whole flow is testable in CI / a memory-capped container.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_CYN=
fi

log()      { printf '%s\n' "$*" >&2; }
log_info() { printf '%s\n' "${C_BLU}·${C_RESET} $*" >&2; }
log_ok()   { printf '%s\n' "${C_GRN}✔${C_RESET} $*" >&2; }
log_warn() { printf '%s\n' "${C_YEL}⚠${C_RESET} $*" >&2; }
log_err()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }
log_step() { printf '\n%s\n' "${C_BOLD}${C_CYN}==>${C_RESET} ${C_BOLD}$*${C_RESET}" >&2; }

die() { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Non-interactive mode
# ---------------------------------------------------------------------------
# In non-interactive mode (HERMES_INSTALL_NONINTERACTIVE=1, set via --answers),
# every prompt resolves from an ANS_<NAME> environment variable, falling back
# to the supplied default. This is what the local test harness drives.

is_noninteractive() { [[ "${HERMES_INSTALL_NONINTERACTIVE:-0}" == "1" ]]; }

# _answer NAME -> echoes the value of ANS_<NAME> if set, else empty.
_answer() {
  local var="ANS_$1"
  printf '%s' "${!var-}"
}

# ask VARNAME "prompt" ["default"]
# Sets the named global to the user's answer (or ANS_<VARNAME> / default).
ask() {
  local __var="$1" __prompt="$2" __default="${3-}" __reply=""
  if is_noninteractive; then
    __reply="$(_answer "$__var")"
    [[ -z "$__reply" ]] && __reply="$__default"
  else
    local __suffix=""
    [[ -n "$__default" ]] && __suffix=" ${C_DIM}[$__default]${C_RESET}"
    read -r -p "$(printf '%s%s: ' "$__prompt" "$__suffix")" __reply </dev/tty || true
    [[ -z "$__reply" ]] && __reply="$__default"
  fi
  printf -v "$__var" '%s' "$__reply"
}

# ask_secret VARNAME "prompt"
# Reads without echo; never appears on screen or in history.
ask_secret() {
  local __var="$1" __prompt="$2" __reply=""
  if is_noninteractive; then
    __reply="$(_answer "$__var")"
  else
    read -r -s -p "$(printf '%s: ' "$__prompt")" __reply </dev/tty || true
    printf '\n' >&2
  fi
  printf -v "$__var" '%s' "$__reply"
}

# ask_yesno VARNAME "prompt" ["Y"|"N"]  -> sets global to "yes"/"no"
ask_yesno() {
  local __var="$1" __prompt="$2" __default="${3:-N}" __reply=""
  local __hint="[y/N]"; [[ "$__default" =~ ^[Yy]$ ]] && __hint="[Y/n]"
  if is_noninteractive; then
    __reply="$(_answer "$__var")"
    [[ -z "$__reply" ]] && __reply="$__default"
  else
    read -r -p "$(printf '%s %s ' "$__prompt" "$__hint")" __reply </dev/tty || true
    [[ -z "$__reply" ]] && __reply="$__default"
  fi
  if [[ "$__reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    printf -v "$__var" 'yes'
  else
    printf -v "$__var" 'no'
  fi
}

# ask_menu VARNAME "prompt" "opt1" "opt2" ...
# Interactive: numbered choice. Non-interactive: ANS_<VARNAME> matched against
# option text (case-insensitive) or a 1-based index.
ask_menu() {
  local __var="$1" __prompt="$2"; shift 2
  local -a __opts=("$@")
  if is_noninteractive; then
    local __want; __want="$(_answer "$__var")"
    if [[ "$__want" =~ ^[0-9]+$ ]] && (( __want >= 1 && __want <= ${#__opts[@]} )); then
      printf -v "$__var" '%s' "${__opts[$((__want-1))]}"; return
    fi
    local o
    for o in "${__opts[@]}"; do
      if [[ "${o,,}" == "${__want,,}" ]]; then printf -v "$__var" '%s' "$o"; return; fi
    done
    printf -v "$__var" '%s' "${__opts[0]}"; return
  fi
  [[ -r /dev/tty ]] || die "No terminal available for the '$__prompt' prompt — use --answers FILE for non-interactive installs."
  log "$__prompt"
  local i=1 o
  for o in "${__opts[@]}"; do printf '  %s) %s\n' "$i" "$o" >&2; ((i++)); done
  local __reply=""
  while :; do
    # A failed read (EOF / vanished tty) must abort, not spin forever.
    if ! read -r -p "$(printf 'Choice [1-%s]: ' "${#__opts[@]}")" __reply </dev/tty; then
      die "Input stream closed while choosing '$__prompt' — use --answers FILE for non-interactive installs."
    fi
    if [[ "$__reply" =~ ^[0-9]+$ ]] && (( __reply >= 1 && __reply <= ${#__opts[@]} )); then
      printf -v "$__var" '%s' "${__opts[$((__reply-1))]}"; return
    fi
    log_warn "Enter a number in range 1-${#__opts[@]}."
  done
}

# ---------------------------------------------------------------------------
# Misc utilities
# ---------------------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }
require_cmd() { have_cmd "$1" || die "Missing required command: $1"; }

# Secure HTTPS download to stdout (TLS 1.2+, https only, fail on error).
fetch() {
  local url="$1"
  curl --proto '=https' --tlsv1.2 -fsSL "$url"
}

# Generate a strong URL-safe password (used when the user does not provide one).
gen_password() {
  if have_cmd openssl; then
    openssl rand -base64 24 | tr -d '/+=' | cut -c1-24
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32
  fi
}

# Write a KEY=VALUE line into a dotenv file, replacing any existing KEY.
# The file is kept at mode 600. Value is written via a temp file so it never
# appears in argv/ps.
set_env_var() {
  local file="$1" key="$2" value="$3"
  local tmp; tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp"
  if [[ -f "$file" ]]; then
    grep -v -E "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$file"
  chmod 600 "$file"
}
