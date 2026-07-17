#!/usr/bin/env bash
#
# pick-nvidia-model.sh — list the live NVIDIA NIM catalog, drop the models that
# can't be used as a Hermes chat model (embeddings / rerankers / reward / safety
# / parsers), suggest a fast large-context pick, write it to the Hermes config,
# and verify it with a real request.
#
# Run as root or as the Hermes service user. When run as root, the script
# automatically uses the dedicated `hermes` account created by the installer.
#
# Non-interactive: HERMES_INSTALL_NONINTERACTIVE=1 ANS_PICK=<index|id>.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/provider.sh"   # _write_model_block

SERVICE_USER="${SERVICE_USER:-}"
SERVICE_HOME=""

# Match the installer's identity rules. In particular, `sudo bash ...` must not
# silently switch to /root/.hermes when the actual installation belongs to the
# dedicated `hermes` service account.
resolve_runtime_identity() {
  local current target
  current="$(id -un)"
  target="${SERVICE_USER:-$current}"
  if [[ "$(id -u)" == "0" && -z "$SERVICE_USER" ]] && id hermes &>/dev/null; then
    target="hermes"
  fi
  if [[ "$target" != "$current" && "$(id -u)" != "0" ]]; then
    die "Only root can select another service user (requested: $target)."
  fi
  id "$target" &>/dev/null || die "Service user '$target' does not exist."
  SERVICE_USER="$target"
  if [[ "$target" == "$current" ]]; then
    SERVICE_HOME="${HOME:?HOME must be set}"
  else
    SERVICE_HOME="$(getent passwd "$target" 2>/dev/null | cut -d: -f6 || true)"
    SERVICE_HOME="${SERVICE_HOME:-/home/$target}"
    log_info "Using Hermes installation owned by '$target' (${SERVICE_HOME}/.hermes)."
  fi
}

resolve_runtime_identity
HERMES_HOME="${HERMES_HOME:-$SERVICE_HOME/.hermes}"
ENV_FILE="$HERMES_HOME/.env"
CONFIG_YAML="$HERMES_HOME/config.yaml"
if [[ -x "$SERVICE_HOME/.local/bin/hermes" ]]; then
  HERMES_BIN="$SERVICE_HOME/.local/bin/hermes"
elif [[ -x /usr/local/bin/hermes ]]; then
  HERMES_BIN="/usr/local/bin/hermes"
else
  HERMES_BIN=""
fi
NIM="https://integrate.api.nvidia.com/v1"

# --- key ---------------------------------------------------------------------
KEY="${NVIDIA_API_KEY:-}"
if [[ -z "$KEY" && -f "$ENV_FILE" ]]; then
  KEY="$(grep -E '^NVIDIA_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi
[[ -n "$KEY" ]] || die "No NVIDIA_API_KEY found (set it in $ENV_FILE or export it)."

# --- catalog -----------------------------------------------------------------
log_step "Fetching the NVIDIA NIM catalog"
# Feed the authorization header through curl's stdin config. Putting it after
# `-H` would expose the API key in argv/ps while the request is in flight.
raw="$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" \
  | curl --proto '=https' --tlsv1.2 -fsSL -m 30 --config - "$NIM/models" || true)"
[[ -n "$raw" ]] || die "Could not fetch $NIM/models — check the key / network."
mapfile -t all < <(printf '%s' "$raw" \
  | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' | sort -u)
(( ${#all[@]} )) || die "The catalog returned no models."

# Drop models that are not chat/completions models.
chat=()
for m in "${all[@]}"; do
  [[ "$m" =~ (embed|rerank|reward|guard|safety|content-safety|parse) ]] && continue
  chat+=("$m")
done
(( ${#chat[@]} )) || die "No chat-capable models after filtering."
log_ok "${#chat[@]} chat-capable models (of ${#all[@]} total in the catalog)."

# --- suggested fast, large-context shortlist ---------------------------------
# One representative per well-known fast / big-context family, in preference
# order (fast MoE & 'flash' variants first). Specific family patterns keep
# obscure research/calibration models out of the recommendations.
prefs=(
  'deepseek-v4-flash'          # fast DeepSeek
  'qwen3-next-80b-a3b'         # fast MoE (~3B active)
  'nemotron-super-49b'         # mid-size, quick
  'llama-3\.3-70b'             # reliable general default
  'glm-5'                      # GLM
  'deepseek-v4-pro'            # stronger DeepSeek
  'minimax-m'                  # MiniMax
  'kimi-'                      # Kimi / Moonshot
  'gpt-oss-120b'               # OpenAI OSS
)
shortlist=()
for p in "${prefs[@]}"; do
  for m in "${chat[@]}"; do
    if [[ "$m" =~ $p ]]; then
      [[ " ${shortlist[*]-} " == *" $m "* ]] || shortlist+=("$m")
      break                    # one per family, for a diverse shortlist
    fi
  done
done
shortlist=("${shortlist[@]:0:8}")
(( ${#shortlist[@]} )) || shortlist=("${chat[@]:0:8}")

# --- pick --------------------------------------------------------------------
log_step "Pick a model (Hermes needs a ≥64K-context model; the list is ordered fastest-first)"
PICK=""
ask_menu PICK "Recommended NVIDIA models:" "${shortlist[@]}" "Show all chat models" "Type a model id"
case "$PICK" in
  "Show all chat models")
    printf '  %s\n' "${chat[@]}" >&2
    ask PICK "Model id" "${shortlist[0]}" ;;
  "Type a model id")
    ask PICK "Model id" "${shortlist[0]}" ;;
esac
[[ -n "$PICK" ]] || die "No model chosen."

# --- write + verify ----------------------------------------------------------
log_info "Setting model.provider=nvidia, model.default=${PICK} in ${CONFIG_YAML}"
_write_model_block "$CONFIG_YAML" nvidia "$PICK"
if [[ "$(id -u)" == "0" && "$SERVICE_USER" != "$(id -un)" ]]; then
  chown "$SERVICE_USER":"$(id -gn "$SERVICE_USER")" "$CONFIG_YAML"
fi

log_step "Verifying '${PICK}' with a live request (may cold-start ~15–30 s)"
verified="unknown"
if [[ -n "$HERMES_BIN" ]]; then
  out="$(as_user env HOME="$SERVICE_HOME" HERMES_HOME="$HERMES_HOME" \
    PATH="$SERVICE_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    timeout 150 "$HERMES_BIN" -z hi 2>&1 || true)"
  if   [[ "$out" == *"context window"* ]]; then log_warn "Rejected — context < 64K: $out"; verified="too-small"
  elif [[ "$out" == *"404"* || "$out" == *"not found"* ]]; then log_warn "404 — '${PICK}' not in the catalog anymore. Run again and pick another."; verified="404"
  elif [[ -n "$out" ]]; then log_ok "Works ✔  model replied: ${out}"; verified="ok"
  else log_warn "No reply (likely cold-start). Try 'hermes -z hi' again in a moment."; verified="timeout"
  fi
else
  log_warn "hermes CLI not found for '$SERVICE_USER' — skipping verification."
fi

log_step "Done"
log "  Model set to: ${C_BOLD}${PICK}${C_RESET} (provider: nvidia)"
log "  Apply it — restart the stack as root:"
log "    bash $SCRIPT_DIR/install-hermes-mikrus.sh --restart"
if [[ "$verified" == "too-small" || "$verified" == "404" ]]; then
  log_warn "Not usable — re-run and choose a different model."
fi
exit 0
