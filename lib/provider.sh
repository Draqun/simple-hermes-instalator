#!/usr/bin/env bash
# provider.sh — configure the LLM provider + model for hermes-agent.
#
# Facts verified against hermes-agent source (hermes_cli/auth.py PROVIDER_REGISTRY,
# hermes_cli/config.py, website/docs/integrations/providers.md):
#   * Minimal config is just `model.default`; `model.provider` defaults to "auto".
#   * A native provider needs: model.provider = <id> + its API-key env var in .env
#     (+ optional model.base_url; the registry supplies sane defaults).
#   * Custom OpenAI-compatible endpoint: provider "custom" + model.base_url + a key
#     referenced via model.key_env (OPENAI_API_KEY is honoured ONLY for "openai-api").
#   * `hermes setup` cannot be scripted, so writing config.yaml + .env directly is
#     the supported non-interactive path.
#
# Native providers offered below. Each row: "Label|provider_id|KEY_ENV|default_model|signup_url".
# Only provider_ids confirmed in PROVIDER_REGISTRY are listed; use "Other" for the rest.
_PROVIDERS=(
  "OpenRouter — aggregator, 200+ models|openrouter|OPENROUTER_API_KEY|anthropic/claude-sonnet-4.6|https://openrouter.ai/keys"
  "Anthropic — Claude (direct)|anthropic|ANTHROPIC_API_KEY|claude-opus-4-6|https://console.anthropic.com/"
  "Google — Gemini|gemini|GEMINI_API_KEY|gemini-3-flash|https://aistudio.google.com/apikey"
  "OpenAI|openai-api|OPENAI_API_KEY|gpt-5.4|https://platform.openai.com/api-keys"
  "NVIDIA — NIM cloud|nvidia|NVIDIA_API_KEY|deepseek-ai/deepseek-r1|https://build.nvidia.com/"
  "DeepSeek|deepseek|DEEPSEEK_API_KEY|deepseek-chat|https://platform.deepseek.com/"
  "xAI — Grok|xai|XAI_API_KEY|grok-4|https://console.x.ai/"
  "z.ai — GLM|zai|GLM_API_KEY|glm-4-plus|https://z.ai/"
  "Kimi — Moonshot|kimi-coding|KIMI_API_KEY|kimi-k2.5|https://platform.kimi.ai/"
  "MiniMax|minimax|MINIMAX_API_KEY|MiniMax-M2.7|https://www.minimax.io/"
  "Ollama Cloud|ollama-cloud|OLLAMA_API_KEY||https://ollama.com/settings"
  "Hugging Face — Inference Providers|huggingface|HF_TOKEN||https://huggingface.co/settings/tokens"
)

DEFER_HERMES_SETUP="no"

# Strip an existing top-level `model:` entry, then we append a fresh one.
# Extra `key: value` lines can be passed as trailing args (e.g. "base_url: ...").
_write_model_block() {
  local file="$1" provider="$2" model="$3"; shift 3
  local -a extra=("$@")
  local tmp; tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp"
  if [[ -f "$file" ]]; then
    # Consume the whole `model:` block (blank lines, indented values AND indented
    # comments) up to the next top-level key — see the corruption regression test.
    awk '
      skip==1 {
        if ($0 ~ /^[^[:space:]]/) { skip=0; print; next }
        next
      }
      /^model:/ { skip=1; next }
      { print }
    ' "$file" > "$tmp"
  else
    printf '# Hermes config — managed by install-hermes-mikrus.sh\n' > "$tmp"
  fi
  {
    printf 'model:\n'
    [[ -n "$provider" ]] && printf '  provider: %s\n' "$provider"
    printf '  default: "%s"\n' "$model"
    local kv
    for kv in "${extra[@]}"; do [[ -n "$kv" ]] && printf '  %s\n' "$kv"; done
  } >> "$tmp"
  mv -f "$tmp" "$file"
  chmod 600 "$file"
}

# _provider_native CFG ENV PROVIDER_ID KEY_ENV DEFAULT_MODEL URL
# Generic handler for any registry provider: key in .env, provider+model in yaml.
_provider_native() {
  local cfg="$1" env_file="$2" pid="$3" keyenv="$4" defmodel="$5" url="$6"
  local MODEL=""
  [[ -n "$url" ]] && log_info "Get your ${keyenv} at: ${url}"
  ask_secret "$keyenv" "${keyenv}"          # non-interactive: reads ANS_<KEY_ENV>
  local key="${!keyenv:-}"
  ask MODEL "Model for ${pid}" "$defmodel"
  if [[ -n "$key" ]]; then
    set_env_var "$env_file" "$keyenv" "$key"
  else
    log_warn "No key entered — set ${keyenv} later in ${env_file} (or run 'hermes setup')."
  fi
  _write_model_block "$cfg" "$pid" "$MODEL"
  log_ok "Provider: ${pid} · model: ${MODEL:-<unset>}"
}

_provider_custom_openai() {
  local cfg="$1" env_file="$2"
  local CUSTOM_BASE_URL="" CUSTOM_API_KEY="" MODEL=""
  log_info "Custom OpenAI-compatible endpoint (vLLM, SGLang, LM Studio, local Ollama, ...)."
  ask        CUSTOM_BASE_URL "Base URL (e.g. http://127.0.0.1:8000/v1)" ""
  ask_secret CUSTOM_API_KEY  "API key (leave empty for keyless local servers)"
  ask        MODEL           "Model name as the endpoint expects it" ""
  if [[ -z "$CUSTOM_BASE_URL" || -z "$MODEL" ]]; then
    log_warn "Base URL/model missing — deferring to 'hermes setup'."; _provider_defer; return
  fi
  local -a extra=("base_url: \"$CUSTOM_BASE_URL\"")
  if [[ -n "$CUSTOM_API_KEY" ]]; then
    set_env_var "$env_file" HERMES_CUSTOM_API_KEY "$CUSTOM_API_KEY"
    extra+=("key_env: HERMES_CUSTOM_API_KEY")
  fi
  _write_model_block "$cfg" "custom" "$MODEL" "${extra[@]}"
  log_ok "Provider: custom (${CUSTOM_BASE_URL}) · model: ${MODEL}"
}

# Any other registry provider not in the curated list (arcee, stepfun, alibaba,
# xiaomi, kilocode, opencode-zen/go, gmi, ...): the user supplies the id + key env.
_provider_other() {
  local cfg="$1" env_file="$2" PID="" KEYENV="" OTHER_KEY="" MODEL=""
  log_info "Advanced: any provider id from Hermes PROVIDER_REGISTRY (arcee, stepfun, alibaba, xiaomi, kilocode, opencode-zen, ...)."
  ask PID    "Provider id (e.g. arcee)" ""
  ask KEYENV "API-key env var name (e.g. ARCEEAI_API_KEY)" ""
  ask_secret OTHER_KEY "API key"
  ask MODEL  "Model" ""
  if [[ -z "$PID" ]]; then
    log_warn "No provider id — deferring to 'hermes setup'."; _provider_defer; return
  fi
  if [[ -n "$KEYENV" && -n "$OTHER_KEY" ]]; then
    set_env_var "$env_file" "$KEYENV" "$OTHER_KEY"
  fi
  _write_model_block "$cfg" "$PID" "$MODEL"
  log_ok "Provider: ${PID} · model: ${MODEL:-<unset>}"
}

# Defer to Hermes's own wizard (authoritative, version-proof) post-install.
_provider_defer() {
  log_info "Provider will be finished with Hermes's own wizard after install."
  log_info "Run: hermes setup    (or 'hermes setup --portal' for the Nous Portal subscription)."
  DEFER_HERMES_SETUP="yes"
}

configure_provider() {
  local cfg="$1" env_file="$2"
  log_step "AI provider"
  local -a labels=() p
  for p in "${_PROVIDERS[@]}"; do labels+=("${p%%|*}"); done
  labels+=("Custom OpenAI-compatible endpoint" "Other native provider (advanced)" "Nous Portal / skip (configure later)")

  local PROVIDER=""
  ask_menu PROVIDER "Choose your AI provider:" "${labels[@]}"

  case "$PROVIDER" in
    "Custom OpenAI-compatible endpoint") _provider_custom_openai "$cfg" "$env_file"; return ;;
    "Other native provider (advanced)")  _provider_other "$cfg" "$env_file"; return ;;
    "Nous Portal"*)                      _provider_defer; return ;;
  esac
  # Dispatch to the matching curated row.
  for p in "${_PROVIDERS[@]}"; do
    if [[ "${p%%|*}" == "$PROVIDER" ]]; then
      local _l pid keyenv defmodel url
      IFS='|' read -r _l pid keyenv defmodel url <<<"$p"
      _provider_native "$cfg" "$env_file" "$pid" "$keyenv" "$defmodel" "$url"
      return
    fi
  done
  _provider_defer
}

# Best-effort post-install validation. `hermes doctor` never signals via exit
# code (always 0), so we parse its stdout instead.
validate_provider_config() {
  have_cmd hermes || return 0
  log_step "Validating configuration (hermes doctor)"
  local out; out="$(hermes doctor 2>&1 || true)"
  printf '%s\n' "$out" | grep -E '✗|not a recognised|no API key|missing|issue' | sed 's/^/  /' >&2 || true
  if grep -qE 'All checks passed|🎉|API key or custom endpoint configured' <<<"$out"; then
    log_ok "hermes doctor: provider/key looks configured."
  else
    log_warn "hermes doctor reported items above — review with 'hermes doctor'."
  fi
  return 0
}
