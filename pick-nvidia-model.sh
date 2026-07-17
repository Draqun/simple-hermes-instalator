#!/usr/bin/env bash
#
# pick-nvidia-model.sh — list the live NVIDIA NIM catalog, drop the models that
# can't be used as a Hermes chat model (embeddings / rerankers / reward / safety
# / parsers), suggest a fast large-context pick, write it to the Hermes config,
# and verify it with a real request.
#
# Run as the Hermes service user, e.g. on Mikrus:
#   su - hermes -c 'bash /path/to/hermes-mikrus/pick-nvidia-model.sh'
# then restart the services as root (the script prints the command).
#
# Non-interactive: HERMES_INSTALL_NONINTERACTIVE=1 ANS_PICK=<index|id>.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/provider.sh"   # _write_model_block

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
ENV_FILE="$HERMES_HOME/.env"
CONFIG_YAML="$HERMES_HOME/config.yaml"
NIM="https://integrate.api.nvidia.com/v1"

# --- key ---------------------------------------------------------------------
KEY="${NVIDIA_API_KEY:-}"
if [[ -z "$KEY" && -f "$ENV_FILE" ]]; then
  KEY="$(grep -E '^NVIDIA_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi
[[ -n "$KEY" ]] || die "No NVIDIA_API_KEY found (set it in $ENV_FILE or export it)."

# --- catalog -----------------------------------------------------------------
log_step "Fetching the NVIDIA NIM catalog"
raw="$(curl --proto '=https' --tlsv1.2 -fsSL -m 30 "$NIM/models" -H "Authorization: Bearer $KEY" || true)"
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

log_step "Verifying '${PICK}' with a live request (may cold-start ~15–30 s)"
verified="unknown"
if have_cmd hermes; then
  out="$(timeout 150 hermes -z hi 2>&1 || true)"
  if   [[ "$out" == *"context window"* ]]; then log_warn "Rejected — context < 64K: $out"; verified="too-small"
  elif [[ "$out" == *"404"* || "$out" == *"not found"* ]]; then log_warn "404 — '${PICK}' not in the catalog anymore. Run again and pick another."; verified="404"
  elif [[ -n "$out" ]]; then log_ok "Works ✔  model replied: ${out}"; verified="ok"
  else log_warn "No reply (likely cold-start). Try 'hermes -z hi' again in a moment."; verified="timeout"
  fi
else
  log_warn "hermes CLI not on PATH — skipping verification. Run this as the Hermes service user."
fi

log_step "Done"
log "  Model set to: ${C_BOLD}${PICK}${C_RESET} (provider: nvidia)"
log "  Apply it — restart the services as root:"
log "    systemctl restart hermes-gateway hermes-webui"
[[ "$verified" == "too-small" || "$verified" == "404" ]] && log_warn "Not usable — re-run and choose a different model."
