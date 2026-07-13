#!/usr/bin/env bash
#
# measure.sh — measure the real RAM + disk footprint of the Hermes stack with
# browser tools OFF vs ON, so you can pick a Mikrus plan up front.
#
# Runs each scenario in its own container with generous RAM (6 GB headroom) so
# we measure TRUE usage instead of hitting the OOM killer. RAM is reported as
# total PSS (Proportional Set Size, from /proc/*/smaps_rollup) — this excludes
# page cache (which inflates cgroup memory.current in a large container) and
# does NOT double-count shared pages (important for multi-process Chromium), so
# it is the honest "resident working set" the box must provide.
#
#   bash test/measure.sh
#
set -uo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
IMAGE="ubuntu:24.04"
MOUNT="/opt/hermers"
MEM=6g

command -v docker >/dev/null || { echo "Docker required."; exit 1; }

# scenario: "off" or "on"
measure() {
  local scenario="$1" answers="$2" extra="$3"
  docker run --rm --memory="$MEM" --memory-swap="$MEM" --cpus=2 \
    -v "$REPO_DIR":"$MOUNT":ro -w "$MOUNT" -e NO_COLOR=1 "$IMAGE" \
    bash -c '
      set +e
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq curl git xz-utils ca-certificates procps >/dev/null 2>&1
      bash install-hermes-mikrus.sh --answers '"$answers"' >/tmp/install.log 2>&1
      export HERMES_HOME=/root/.hermes
      export HERMES_WEBUI_AGENT_DIR="$(ls -d /usr/local/lib/hermes-agent /root/.hermes/hermes-agent 2>/dev/null | head -1)"
      WUI=/root/.hermes/hermes-webui
      [ -f "$WUI/ctl.sh" ] && bash "$WUI/ctl.sh" start >/tmp/webui.log 2>&1
      for i in $(seq 1 40); do
        [ "$(curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8787/health 2>/dev/null)" = "200" ] && break; sleep 2
      done
      sleep 3
      pss_mb() { awk "/^Pss:/{s+=\$2} END{printf \"%d\", s/1024}" /proc/*/smaps_rollup 2>/dev/null; }
      echo "___IDLE_MB=$(pss_mb)"

      '"$extra"'

      # Disk: agent code + venv + data + playwright caches.
      echo "___DISK_MB=$(du -sm --total /usr/local/lib/hermes-agent /root/.hermes /root/.cache/ms-playwright 2>/dev/null | tail -1 | cut -f1)"
      # Did a LOCAL chromium get installed?
      CH="$(find / -type f \( -name chrome -o -name headless_shell \) -path "*chromium*" 2>/dev/null | head -1)"
      echo "___CHROMIUM=${CH:-none}"
      echo "___LOGTAIL___"; tail -4 /tmp/install.log
    ' 2>&1
}

# For browser ON: after the stack is up, launch the installed Playwright
# chromium headless and re-measure — a proxy for "browser tool active".
CHROMIUM_PROBE='
  CH="$(find / -type f \( -name chrome -o -name headless_shell \) -path "*chromium*" 2>/dev/null | head -1)"
  if [ -n "$CH" ]; then
    apt-get install -y -qq libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2t64 >/dev/null 2>&1
    "$CH" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-port=0 about:blank >/tmp/chrome.log 2>&1 &
    sleep 8
    echo "___ACTIVE_MB=$(pss_mb)"
  else
    echo "___ACTIVE_MB=n/a (no local chromium — likely cloud Browserbase)"
  fi
'

echo "==> Measuring browser OFF (this takes a few minutes) ..."
OFF="$(measure off test/answers.example.env '')"
printf '%s\n' "$OFF" | sed 's/^/   off | /'

echo "==> Measuring browser ON (installs Playwright/Chromium — several minutes) ..."
ON="$(measure on test/answers.browser-on.env "$CHROMIUM_PROBE")"
printf '%s\n' "$ON" | sed 's/^/   on  | /'

g() { grep -oE "$1=[^ ]*|$1=.*" <<<"$2" | head -1 | cut -d= -f2-; }
echo
echo "======================= FOOTPRINT (PSS) ================="
printf '%-28s %-14s %-14s %-10s\n' "Scenario" "RAM idle" "RAM active" "Disk"
printf '%-28s %-14s %-14s %-10s\n' "Browser OFF" "$(g ___IDLE_MB "$OFF") MB" "-" "$(g ___DISK_MB "$OFF") MB"
printf '%-28s %-14s %-14s %-10s\n' "Browser ON" "$(g ___IDLE_MB "$ON") MB" "$(g ___ACTIVE_MB "$ON") MB" "$(g ___DISK_MB "$ON") MB"
echo "Local chromium (ON): $(g ___CHROMIUM "$ON")"
echo "========================================================="
