#!/usr/bin/env bash
#
# local-test.sh — run the installer inside a memory-capped container that
# mimics a Mikrus 3.0 box (2 GB RAM + 1 GB swap, 1 CPU), and assert behaviour.
#
# This is the feedback loop for the installer. Two layers:
#   (default)  fast checks: capability detection + verdicts (no network/apt)
#   --full     heavy end-to-end: real uv/agent/WebUI install + /health probe
#
# Usage:
#   test/local-test.sh            # fast assertions
#   test/local-test.sh --full     # full end-to-end install in the container
#
set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
IMAGE="ubuntu:24.04"
MOUNT="/opt/hermers"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); return 0; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); return 0; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

command -v docker >/dev/null || { echo "Docker is required for local tests."; exit 1; }

# run_check MEM SWAP CPUS ARGS...  -> prints combined output, returns exit code
run_check() {
  local mem="$1" swap="$2" cpus="$3"; shift 3
  docker run --rm \
    --memory="$mem" --memory-swap="$swap" --cpus="$cpus" \
    -v "$REPO_DIR":"$MOUNT":ro -w "$MOUNT" \
    -e NO_COLOR=1 \
    "$IMAGE" \
    bash install-hermes-mikrus.sh "$@" 2>&1
}

# --- Fast assertions --------------------------------------------------------
# Mikrus 3.0 = 2 GB RAM, LXC, and file-based swap is documented as NOT stable
# (wiki: ograniczenia_techniczne). So the faithful sim is 2 GB with NO swap
# (--memory-swap == --memory disables container swap).

fast_tests() {
  info "Test 1: capability-check @ 2 GB, no swap (Mikrus 3.0 sim)"
  local out rc
  out="$(run_check 2g 2g 1 --check-only)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  if (( rc == 0 )); then ok "exit 0 (not blocked)"; else bad "expected exit 0, got $rc"; fi
  if grep -qE 'RAM \(effective limit\).*(1\.9|2\.0) GB' <<<"$out"; then
    ok "detected ~2 GB from cgroup (not host RAM)"
  else
    bad "did not detect 2 GB cgroup limit — showed host RAM?"
  fi
  if grep -q 'sufficient' <<<"$out"; then ok "classified as 'ok' tier"; else bad "wrong tier"; fi
  if grep -q 'OFF' <<<"$out"; then ok "browser tools default off"; else bad "browser tools not off"; fi

  info "Test 2: capability-check @ 512 MB without --force (must block)"
  out="$(run_check 512m 512m 1 --check-only)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  if (( rc != 0 )); then ok "exit != 0 (blocked)"; else bad "expected block, got exit 0"; fi
  if grep -q 'not recommended' <<<"$out"; then ok "'not recommended' warning"; else bad "missing warning"; fi

  info "Test 3: capability-check @ 512 MB with --force (must pass conditionally)"
  out="$(run_check 512m 512m 1 --check-only --force)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  if (( rc == 0 )); then ok "exit 0 with --force"; else bad "expected exit 0 with --force, got $rc"; fi
  if grep -q 'testing the limits' <<<"${out,,}"; then ok "limits-test message shown"; else bad "missing --force message"; fi
}

# --- Full end-to-end (heavy) ------------------------------------------------

dryrun_test() {
  info "Dry-run wizard @ 2 GB (writes config.yaml + .env, no heavy install)"
  local out rc
  out="$(docker run --rm --memory=2g --memory-swap=2g --cpus=1 \
    -v "$REPO_DIR":"$MOUNT":ro -w "$MOUNT" -e NO_COLOR=1 "$IMAGE" \
    bash -c '
      bash install-hermes-mikrus.sh --dry-run --answers test/answers.example.env >/tmp/log 2>&1
      rc=$?
      echo "___RC=$rc"
      echo "___CONFIG___"; cat "$HOME/.hermes/config.yaml" 2>/dev/null
      echo "___ENVPERM=$(stat -c %a "$HOME/.hermes/.env" 2>/dev/null)"
      echo "___ENVKEYS___"; cut -d= -f1 "$HOME/.hermes/.env" 2>/dev/null
      echo "___LOGTAIL___"; tail -3 /tmp/log
    ' 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  grep -q '___RC=0' <<<"$out" && ok "dry-run exit 0" || bad "dry-run non-zero exit"
  grep -q 'provider: openrouter' <<<"$out" && ok "config.yaml: provider written" || bad "no provider in config.yaml"
  grep -qE 'default: "anthropic/claude' <<<"$out" && ok "config.yaml: model written" || bad "no model in config.yaml"
  grep -q '___ENVPERM=600' <<<"$out" && ok ".env mode 600" || bad ".env not 600"
  grep -q 'OPENROUTER_API_KEY' <<<"$out" && ok ".env has provider key" || bad ".env missing provider key"
  grep -q 'HERMES_WEBUI_PASSWORD' <<<"$out" && ok ".env has WebUI password (auto-generated)" || bad ".env missing WebUI password"
  grep -q 'HERMES_WEBUI_HOST' <<<"$out" && ok ".env pins WebUI host (127.0.0.1)" || bad ".env missing WebUI host"
}

full_test() {
  info "FULL test: real install in a 2 GB container (uv + agent + WebUI + /health)"
  info "Default path now runs as a dedicated non-root user 'hermes' — this asserts that too."
  local out
  # No systemd in a plain container, so after the installer runs we start the
  # WebUI by hand — AS the hermes user — and probe /health. We also assert the
  # WebUI process is owned by hermes (the whole point of the non-root default).
  out="$(docker run --rm --memory=2g --memory-swap=2g --cpus=1 \
    -v "$REPO_DIR":"$MOUNT":ro -w "$MOUNT" -e NO_COLOR=1 "$IMAGE" \
    bash -c '
      set +e
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq curl git xz-utils ca-certificates procps >/dev/null 2>&1
      bash install-hermes-mikrus.sh --answers test/answers.example.env >/tmp/install.log 2>&1
      echo "___INSTALL_RC=$?"
      id hermes >/dev/null 2>&1 && echo "___HERMES_USER=yes" || echo "___HERMES_USER=no"
      HH="$(getent passwd hermes | cut -d: -f6)/.hermes"
      echo "___HH=$HH"
      runuser -l hermes -c "hermes --version" >/tmp/hv 2>&1
      echo "___HERMES=$(grep -io "Hermes Agent v[0-9.]*" /tmp/hv | head -1)"
      ls -d "$HH/hermes-agent" /usr/local/lib/hermes-agent 2>/dev/null | head -1 | sed "s#^#___AGENTDIR=#"
      # Start the WebUI AS hermes (no exports — symlink/per-user layout handles discovery).
      setsid runuser -u hermes -- bash "$HH/hermes-webui/ctl.sh" start >/tmp/webui_start.log 2>&1
      echo "___CTL_OUT___"; sed -E "s/[0-9]{6,}:[A-Za-z0-9_-]{20,}/<TOKEN>/g" /tmp/webui_start.log | tail -12
      for i in $(seq 1 40); do
        [ "$(curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8787/health 2>/dev/null)" = "200" ] && break; sleep 2
      done
      echo "___WEBUI_LOG___"; tail -15 "$HH/webui.log" 2>/dev/null || echo "(no webui.log)"
      echo "___HEALTH=$(curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8787/health 2>/dev/null)"
      echo "___WEBUI_OWNER=$(ps -eo user:20,args | grep -iE "server.py|hermes-webui" | grep -v grep | awk "{print \$1}" | head -1)"
      runuser -l hermes -c "hermes config show" >/tmp/cfg.txt 2>&1
      grep -q "Failed to parse" /tmp/cfg.txt && echo "___CONFIG=BAD" || echo "___CONFIG=OK"
      echo "___MEM_BYTES=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)"
      echo "___INSTALL_LOG_TAIL___"; tail -12 /tmp/install.log
    ' 2>&1)"
  printf '%s\n' "$out" | sed 's/^/     | /'
  grep -q '___INSTALL_RC=0' <<<"$out" && ok "installer exit 0" || bad "installer non-zero exit"
  grep -q '___HERMES_USER=yes' <<<"$out" && ok "dedicated 'hermes' user created" || bad "hermes user not created"
  grep -q '___HERMES=Hermes' <<<"$out" && ok "hermes binary works for the service user" || bad "hermes binary missing for user"
  grep -q '___AGENTDIR=' <<<"$out" && ok "agent code dir present" || bad "agent code dir missing"
  grep -q '___HEALTH=200' <<<"$out" && ok "WebUI /health returned 200" || bad "WebUI /health not 200"
  grep -q '___WEBUI_OWNER=hermes' <<<"$out" && ok "WebUI process runs as hermes (non-root)" || bad "WebUI not running as hermes"
  grep -q '___CONFIG=OK' <<<"$out" && ok "config.yaml parses cleanly (model block intact)" || bad "config.yaml failed to parse"
  local mem; mem="$(grep -oE '___MEM_BYTES=[0-9]+' <<<"$out" | cut -d= -f2)"
  if [[ -n "$mem" && "$mem" -gt 0 ]]; then
    local mb=$(( mem / 1024 / 1024 ))
    if (( mb < 2048 )); then ok "peak RAM ${mb} MB fits in 2 GB"; else bad "RAM ${mb} MB exceeded 2 GB"; fi
  fi
}

main() {
  case "${1:-}" in
    --full)   full_test ;;
    --dryrun) dryrun_test ;;
    *)        fast_tests; dryrun_test ;;
  esac
  echo
  info "Result: ${PASS} PASS / ${FAIL} FAIL"
  (( FAIL == 0 ))
}

main "$@"
