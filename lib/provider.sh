#!/usr/bin/env bash
# provider.sh — configure the LLM provider + model for hermes-agent.
#
# Facts verified against hermes-agent source (hermes_cli/auth.py PROVIDER_REGISTRY,
# hermes_cli/config.py, website/docs/integrations/providers.md):
#   * Minimal config is just `model.default`; `model.provider` defaults to "auto"
#     and is resolved from whichever credential is present.
#   * OpenRouter: provider "openrouter", key OPENROUTER_API_KEY, model "vendor/model".
#   * Anthropic direct: provider "anthropic", key ANTHROPIC_API_KEY, model bare
#     ("claude-opus-4-6"); needs the lazy-installed `anthropic` extra.
#   * Custom OpenAI-compatible endpoint: provider "custom" + model.base_url; the
#     key is referenced via model.key_env -> a .env var (OPENAI_API_KEY is ONLY
#     honoured for provider "openai-api" / real openai.com, not generic custom).
#   * `hermes setup` cannot be scripted (its --non-interactive just prints help),
#     so writing config.yaml + .env directly is the supported non-interactive path.
#
# Non-interactive answers: ANS_PROVIDER, ANS_MODEL, ANS_OPENROUTER_API_KEY,
# ANS_ANTHROPIC_API_KEY, ANS_CUSTOM_BASE_URL, ANS_CUSTOM_API_KEY.

DEFER_HERMES_SETUP="no"

# Strip an existing top-level `model:` block, then append a fresh one.
# Extra `key: value` lines can be passed as trailing args (e.g. "base_url: ...").
_write_model_block() {
  local file="$1" provider="$2" model="$3"; shift 3
  local -a extra=("$@")
  local tmp; tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp"
  if [[ -f "$file" ]]; then
    # Strip an existing top-level `model:` entry, then we append a fresh one.
    # Once inside the block (after a line starting with "model:") we drop every
    # following line — blank lines, indented values AND indented comments alike —
    # until the next line that begins in column 0 (the next top-level key), which
    # ends the block. This correctly handles block form, inline "model: {...}",
    # a "model:  # note" header, and (crucially) blank lines *within* the block —
    # the previous version stopped at the first blank line and orphaned the rest,
    # producing invalid YAML.
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

_provider_openrouter() {
  local cfg="$1" env_file="$2"
  local OPENROUTER_API_KEY="" MODEL=""
  log_info "OpenRouter routes 200+ models through one key. Get it at https://openrouter.ai/keys"
  ask_secret OPENROUTER_API_KEY "OpenRouter API key (sk-or-...)"
  ask MODEL "Model (vendor/model form)" "anthropic/claude-sonnet-4.6"
  if [[ -n "$OPENROUTER_API_KEY" ]]; then
    set_env_var "$env_file" OPENROUTER_API_KEY "$OPENROUTER_API_KEY"
  else
    log_warn "No key entered — set it later with 'hermes config set OPENROUTER_API_KEY ...' or edit $env_file."
  fi
  _write_model_block "$cfg" "openrouter" "$MODEL"
  log_ok "Provider: OpenRouter · model: $MODEL"
}

_provider_anthropic() {
  local cfg="$1" env_file="$2"
  local ANTHROPIC_API_KEY="" MODEL=""
  log_info "Direct Anthropic API (console.anthropic.com). Uses the lazy-installed 'anthropic' extra."
  ask_secret ANTHROPIC_API_KEY "Anthropic API key (sk-ant-...)"
  ask MODEL "Model (bare name)" "claude-opus-4-6"
  if [[ -n "$ANTHROPIC_API_KEY" ]]; then
    set_env_var "$env_file" ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
  else
    log_warn "No key entered — set it later or edit $env_file."
  fi
  _write_model_block "$cfg" "anthropic" "$MODEL"
  log_ok "Provider: Anthropic · model: $MODEL"
}

_provider_custom_openai() {
  local cfg="$1" env_file="$2"
  local CUSTOM_BASE_URL="" CUSTOM_API_KEY="" MODEL=""
  log_info "Custom OpenAI-compatible endpoint (vLLM, SGLang, LM Studio, Ollama, ...)."
  ask        CUSTOM_BASE_URL "Base URL (e.g. http://127.0.0.1:8000/v1)" ""
  ask_secret CUSTOM_API_KEY  "API key (leave empty for keyless local servers)"
  ask        MODEL           "Model name as the endpoint expects it" ""
  if [[ -z "$CUSTOM_BASE_URL" || -z "$MODEL" ]]; then
    log_warn "Base URL/model missing — deferring to 'hermes setup'."; _provider_defer; return
  fi
  # provider: custom resolves the key via model.key_env, NOT OPENAI_API_KEY.
  local -a extra=("base_url: \"$CUSTOM_BASE_URL\"")
  if [[ -n "$CUSTOM_API_KEY" ]]; then
    set_env_var "$env_file" HERMES_CUSTOM_API_KEY "$CUSTOM_API_KEY"
    extra+=("key_env: HERMES_CUSTOM_API_KEY")
  fi
  _write_model_block "$cfg" "custom" "$MODEL" "${extra[@]}"
  log_ok "Provider: custom ($CUSTOM_BASE_URL) · model: $MODEL"
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
  local PROVIDER=""
  ask_menu PROVIDER "Choose your AI provider:" \
    "OpenRouter" "Anthropic (direct)" "Custom OpenAI-compatible endpoint" "Nous Portal / other (hermes setup)"
  case "$PROVIDER" in
    "OpenRouter")                        _provider_openrouter   "$cfg" "$env_file" ;;
    "Anthropic (direct)")                _provider_anthropic    "$cfg" "$env_file" ;;
    "Custom OpenAI-compatible endpoint") _provider_custom_openai "$cfg" "$env_file" ;;
    *)                                   _provider_defer ;;
  esac
}

# Best-effort post-install validation. `hermes doctor` never signals via exit
# code (always 0), so we parse its stdout instead.
validate_provider_config() {
  have_cmd hermes || return 0
  log_step "Validating configuration (hermes doctor)"
  local out; out="$(hermes doctor 2>&1 || true)"
  printf '%s\n' "$out" | grep -E '✗|not a recognised|no API key|missing|issue' | sed 's/^/  /' >&2 || true
  if grep -qE 'All checks passed|🎉' <<<"$out"; then
    log_ok "hermes doctor: all checks passed."
  else
    log_warn "hermes doctor reported items above — review with 'hermes doctor'."
  fi
}
