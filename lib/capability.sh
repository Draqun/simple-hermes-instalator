#!/usr/bin/env bash
# capability.sh — inspect the machine and decide whether Hermes can run here.
#
# CRITICAL: on a container / LXC box (Mikrus is LXC-based) the RAM limit is
# enforced via cgroups, while /proc/meminfo often reports the HOST's total
# memory. Reading only `free` would wildly over-report available RAM. We
# therefore take min(cgroup limit, /proc/meminfo MemTotal).

# Results (set by detect_capabilities), consumed by the installer:
CAP_RAM_MB=0
CAP_SWAP_MB=0
CAP_DISK_FREE_MB=0
CAP_CPUS=0
CAP_ARCH=""
CAP_TIER=""            # comfort | ok | conditional | discouraged
CAP_BROWSER_DEFAULT="" # on | off

# Mikrus detection (best-effort, from hostname — no plan-query API exists):
MIKRUS_DETECTED="no"
MIKRUS_SERVER=""       # e.g. emil100
MIKRUS_ID=""           # e.g. 100

# --- RAM -------------------------------------------------------------------

_cgroup_mem_limit_mb() {
  local bytes=""
  # cgroup v2
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    local v; v="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
    [[ "$v" != "max" && "$v" =~ ^[0-9]+$ ]] && bytes="$v"
  fi
  # cgroup v1
  if [[ -z "$bytes" && -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    local v; v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
    # v1 uses a huge sentinel (~PAGE_COUNTER_MAX) for "unlimited"; ignore it.
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v < 9223372036854000000 )); then bytes="$v"; fi
  fi
  [[ -n "$bytes" ]] && echo $(( bytes / 1024 / 1024 )) || echo ""
}

_meminfo_total_mb() {
  local kb; kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  [[ -n "$kb" ]] && echo $(( kb / 1024 )) || echo 0
}

detect_ram_mb() {
  local host cg
  host="$(_meminfo_total_mb)"
  cg="$(_cgroup_mem_limit_mb)"
  if [[ -n "$cg" ]] && (( cg > 0 )) && (( cg < host )); then
    echo "$cg"
  else
    echo "$host"
  fi
}

detect_swap_mb() {
  local kb; kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  [[ -n "$kb" ]] && echo $(( kb / 1024 )) || echo 0
}

# --- Disk ------------------------------------------------------------------

detect_disk_free_mb() {
  local target="${HERMES_HOME:-$HOME/.hermes}"
  # Check the nearest existing ancestor (dir may not exist yet).
  while [[ ! -d "$target" && "$target" != "/" ]]; do target="$(dirname "$target")"; done
  df -Pm "$target" 2>/dev/null | awk 'NR==2{print $4}'
}

# --- CPU / arch ------------------------------------------------------------

detect_cpus() { nproc 2>/dev/null || echo 1; }
detect_arch() { uname -m 2>/dev/null || echo unknown; }

# --- Mikrus detection ------------------------------------------------------
# Mikrus containers are named like emil100 / monika100 / f853 (frog). The
# trailing digits are the machine ID used for the port formula and subdomains.
# There is no plan/spec query command, so this is purely name-based.

# The machine ID is the TRAILING digits of the hostname (bob305 -> 305,
# emil100 -> 100, f853 -> 853). Base-10-normalised so a leading zero (008)
# doesn't get mis-read as octal in the port arithmetic.
_mikrus_id_from_hostname() {
  local h="$1"
  [[ "$h" =~ ([0-9]+)$ ]] || { echo ""; return; }
  echo "$((10#${BASH_REMATCH[1]}))"
}

detect_mikrus() {
  local h; h="$(hostname 2>/dev/null || echo)"
  if [[ -d /opt/noobs || -f /etc/mikrus_version ]]; then
    # MIKRUS_SERVER is the FULL hostname (used verbatim in serverName-port.wykr.es).
    MIKRUS_DETECTED="yes"; MIKRUS_SERVER="$h"; MIKRUS_ID="$(_mikrus_id_from_hostname "$h")"
  fi
}

# --- Verdict ---------------------------------------------------------------
# Tiers mirror the design doc's RAM table. Browser tools (Playwright/Chromium)
# are the memory-hungry feature; default them off below 4 GB.

classify_tier() {
  local ram="$1"
  if   (( ram >= 3800 )); then CAP_TIER="comfort";     CAP_BROWSER_DEFAULT="on"
  elif (( ram >= 1900 )); then CAP_TIER="ok";          CAP_BROWSER_DEFAULT="off"
  elif (( ram >=  950 )); then CAP_TIER="conditional"; CAP_BROWSER_DEFAULT="off"
  else                         CAP_TIER="discouraged"; CAP_BROWSER_DEFAULT="off"
  fi
}

detect_capabilities() {
  CAP_RAM_MB="$(detect_ram_mb)"
  CAP_SWAP_MB="$(detect_swap_mb)"
  CAP_DISK_FREE_MB="$(detect_disk_free_mb)"
  CAP_CPUS="$(detect_cpus)"
  CAP_ARCH="$(detect_arch)"
  detect_mikrus
  classify_tier "$CAP_RAM_MB"
}

# Minimum free disk we ask for (agent venv + Node + data). Conservative.
CAP_MIN_DISK_MB=3072

# Pretty report + recommendation. Returns:
#   0 -> proceed
#   1 -> blocked unless --force
report_capabilities() {
  local force="${1:-no}"
  log_step "Checking machine capabilities"

  local ram_h="${CAP_RAM_MB} MB"
  (( CAP_RAM_MB >= 1024 )) && ram_h="$(awk "BEGIN{printf \"%.1f GB\", $CAP_RAM_MB/1024}")"
  local disk_h="${CAP_DISK_FREE_MB} MB"
  (( CAP_DISK_FREE_MB >= 1024 )) && disk_h="$(awk "BEGIN{printf \"%.1f GB\", $CAP_DISK_FREE_MB/1024}")"

  log "  RAM (effective limit) : ${ram_h}"
  log "  Swap                  : ${CAP_SWAP_MB} MB"
  log "  Free disk (~/.hermes) : ${disk_h}"
  log "  CPU                   : ${CAP_CPUS}"
  log "  Architecture          : ${CAP_ARCH}"
  [[ "$MIKRUS_DETECTED" == "yes" ]] && log "  Mikrus                : ${MIKRUS_SERVER}${MIKRUS_ID:+ (id ${MIKRUS_ID})}"

  local blocked=0

  case "$CAP_TIER" in
    comfort)     log_ok   "RAM: comfortable — browser tools may be enabled." ;;
    ok)          log_ok   "RAM: sufficient (within Hermes's recommendation). Browser tools default to OFF." ;;
    conditional) log_warn "RAM below 2 GB — will run conditionally. Browser tools OFF; watch memory closely." ;;
    discouraged) log_warn "RAM below 1 GB — not recommended. This is under Hermes's 1 GB minimum."; blocked=1 ;;
  esac

  # Architecture must be supported by upstream images/wheels.
  case "$CAP_ARCH" in
    x86_64|amd64|aarch64|arm64) ;;
    *) log_warn "Unusual architecture ($CAP_ARCH) — Hermes may lack prebuilt packages."; blocked=1 ;;
  esac

  # Disk
  if (( CAP_DISK_FREE_MB < CAP_MIN_DISK_MB )); then
    log_warn "Low free disk (< ${CAP_MIN_DISK_MB} MB). The install may not fit."
    blocked=1
  else
    log_ok "Disk: enough free space."
  fi

  # Mikrus-specific note: file-based swap is documented as unstable there.
  if [[ "$MIKRUS_DETECTED" == "yes" && "$CAP_SWAP_MB" -eq 0 && "$CAP_TIER" != "comfort" ]]; then
    log_info "Mikrus (LXC): a swapfile is not stable here, so memory tuning matters — keeping browser tools off."
  fi

  if (( blocked == 1 )); then
    if [[ "$force" == "yes" ]]; then
      log_warn "Problems detected, but continuing due to --force. You are testing the limits — good luck."
      return 0
    fi
    log_err "Machine does not meet the recommended conditions. To try anyway, re-run with --force."
    return 1
  fi
  return 0
}
