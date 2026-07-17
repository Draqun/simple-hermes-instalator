#!/usr/bin/env bash
#
# unit-test.sh — fast, host-side unit tests for the pure helpers and render
# functions. No Docker, no network, no Hermes required.
#
set -uo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
export NO_COLOR=1

# shellcheck source=/dev/null
source "$REPO_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/capability.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/mikrus.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/webui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/provider.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); return 0; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); return 0; }
sec() { printf '\033[36m==>\033[0m %s\n' "$*"; }
has() { grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
hasre() { grep -qE -- "$2" <<<"$1" && ok "$3" || bad "$3"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

sec "set_env_var: write, replace, mode 600"
ENVF="$TMP/.env"
set_env_var "$ENVF" FOO bar
set_env_var "$ENVF" BAZ qux
set_env_var "$ENVF" FOO bar2   # replace
grep -q '^FOO=bar2$' "$ENVF" && ok "replaces existing key" || bad "did not replace key"
grep -q '^BAZ=qux$' "$ENVF" && ok "keeps other keys" || bad "lost other key"
[[ "$(grep -c '^FOO=' "$ENVF")" == "1" ]] && ok "no duplicate keys" || bad "duplicate key left"
perm="$(stat -c '%a' "$ENVF")"; [[ "$perm" == "600" ]] && ok "file mode 600 (was $perm)" || bad "file mode $perm (want 600)"

sec "gen_password: strong-ish, no whitespace"
p="$(gen_password)"
[[ -n "$p" ]] && ok "non-empty" || bad "empty"
[[ ${#p} -ge 16 ]] && ok "length >= 16 (${#p})" || bad "too short (${#p})"
[[ "$p" != *" "* && "$p" != *$'\n'* ]] && ok "no whitespace" || bad "contains whitespace"

sec "ask_menu / ask: non-interactive resolution"
HERMES_INSTALL_NONINTERACTIVE=1
ANS_PROV="Anthropic"; ask_menu PROV "pick" "OpenRouter" "Anthropic" "Custom"
[[ "$PROV" == "Anthropic" ]] && ok "matches option by name" || bad "got '$PROV'"
ANS_PROV2="3"; ask_menu PROV2 "pick" "OpenRouter" "Anthropic" "Custom"
[[ "$PROV2" == "Custom" ]] && ok "matches option by index" || bad "got '$PROV2'"
ANS_CITY=""; ask CITY "town" "Helsinki"
[[ "$CITY" == "Helsinki" ]] && ok "falls back to default" || bad "got '$CITY'"
unset HERMES_INSTALL_NONINTERACTIVE

sec "render_nginx_site"
NG="$(render_nginx_site 20123 8787 emil123)"
has "$NG" "listen [::]:20123;" "listens on IPv6 (mikrus.cloud requirement)"
has "$NG" "listen 20123;" "listens on IPv4 (wykr.es requirement)"
has "$NG" "proxy_pass http://127.0.0.1:8787;" "proxies to loopback WebUI"
has "$NG" "emil123-20123.wykr.es" "server_name has wykr.es"
has "$NG" "emil123-20123.mikrus.cloud" "server_name has mikrus.cloud"
has "$NG" "proxy_buffering off;" "SSE-friendly (no buffering)"

sec "mikrus port + URL helpers"
MIKRUS_ID=123
[[ "$(mikrus_default_public_port)" == "20123" ]] && ok "default port = 20000+ID" || bad "wrong default port"
U="$(mikrus_public_urls emil123 20123)"
has "$U" "https://emil123-20123.wykr.es" "wykr.es URL"
has "$U" "https://emil123-20123.mikrus.cloud" "mikrus.cloud URL"

sec "systemd units + hardening"
GU="$(render_gateway_unit root /root)"
has "$GU" "ExecStart=/root/.local/bin/hermes gateway run" "gateway ExecStart"
has "$GU" "NoNewPrivileges=yes" "gateway: NoNewPrivileges"
has "$GU" "ProtectSystem=strict" "gateway: ProtectSystem=strict"
has "$GU" "ReadWritePaths=/root/.hermes /root/workspace" "gateway: ReadWritePaths scoped"
has "$GU" "Restart=on-failure" "gateway: restarts on failure"
WU="$(render_webui_unit root /root /root/.hermes/.env /root/.hermes/hermes-webui)"
has "$WU" "After=network-online.target hermes-gateway.service" "webui starts after gateway"
has "$WU" "EnvironmentFile=/root/.hermes/.env" "webui: env file wired"
has "$WU" "NoNewPrivileges=yes" "webui: NoNewPrivileges"

sec "webui_secure_behind_proxy: passkeys + secure + allowed origins"
EFX="$TMP/proxy.env"; : > "$EFX"; chmod 600 "$EFX"
webui_secure_behind_proxy "$EFX" "https://a.wykr.es,https://a.mikrus.cloud" >/dev/null 2>&1
grep -q '^HERMES_WEBUI_PASSKEY=1' "$EFX" && ok "passkey feature flag enabled" || bad "passkey flag missing"
grep -q '^HERMES_WEBUI_SECURE=1' "$EFX" && ok "Secure cookie flag set" || bad "secure flag missing"
grep -q '^HERMES_WEBUI_TRUST_FORWARDED_PROTO=1' "$EFX" && ok "trusts X-Forwarded-Proto" || bad "trust-proto missing"
grep -q '^HERMES_WEBUI_ALLOWED_ORIGINS=https://a.wykr.es,https://a.mikrus.cloud' "$EFX" && ok "allowed origins = both URLs" || bad "origins missing/wrong"

sec "systemd unit for a dedicated (non-root) service user"
GU2="$(render_gateway_unit hermes /home/hermes /home/hermes/.local/bin/hermes)"
has "$GU2" "User=hermes" "gateway runs as hermes (not root)"
has "$GU2" "ExecStart=/home/hermes/.local/bin/hermes gateway run" "gateway uses the service user's bin"
has "$GU2" "ReadWritePaths=/home/hermes/.hermes /home/hermes/workspace" "RW paths scoped to hermes home"

sec "provider: _write_model_block (config.yaml generation)"
CFG="$TMP/config.yaml"
_write_model_block "$CFG" openrouter "anthropic/claude-sonnet-4.6"
has "$(cat "$CFG")" "provider: openrouter" "fresh file: provider written"
has "$(cat "$CFG")" 'default: "anthropic/claude-sonnet-4.6"' "fresh file: model default written"
# Replace the block; must not duplicate model: and must switch provider.
_write_model_block "$CFG" anthropic "claude-opus-4-6"
[[ "$(grep -c '^model:' "$CFG")" == "1" ]] && ok "no duplicate model: block after replace" || bad "duplicate model: block"
has "$(cat "$CFG")" "provider: anthropic" "replaced provider"
grep -q 'openrouter' "$CFG" && bad "old provider lingered" || ok "old provider removed"
# Custom endpoint with extra keys + preserve surrounding content.
printf 'terminal:\n  backend: local\n' >> "$CFG"
_write_model_block "$CFG" custom "my-model" 'base_url: "http://127.0.0.1:8000/v1"' 'key_env: HERMES_CUSTOM_API_KEY'
has "$(cat "$CFG")" 'base_url: "http://127.0.0.1:8000/v1"' "custom: base_url extra line"
has "$(cat "$CFG")" "key_env: HERMES_CUSTOM_API_KEY" "custom: key_env extra line"
has "$(cat "$CFG")" "backend: local" "preserved unrelated (terminal) config"
perm="$(stat -c '%a' "$CFG")"; [[ "$perm" == "600" ]] && ok "config.yaml mode 600" || bad "config.yaml mode $perm"
# Regression: inline mapping form must be stripped (no duplicate model:).
CFG2="$TMP/config2.yaml"
printf 'model: {provider: openrouter, default: "old"}\nterminal:\n  backend: local\n' > "$CFG2"
_write_model_block "$CFG2" anthropic "claude-opus-4-6"
[[ "$(grep -c '^model:' "$CFG2")" == "1" ]] && ok "inline model: stripped (no duplicate)" || bad "inline model: left a duplicate"
has "$(cat "$CFG2")" "backend: local" "inline case: preserved other keys"
# Regression: commented header form.
CFG3="$TMP/config3.yaml"
printf 'model:  # main config\n  provider: openrouter\n  default: "old"\nx: 1\n' > "$CFG3"
_write_model_block "$CFG3" anthropic "claude-opus-4-6"
[[ "$(grep -c '^model:' "$CFG3")" == "1" ]] && ok "commented model: stripped (no duplicate)" || bad "commented model: left a duplicate"
grep -q 'old' "$CFG3" && bad "commented case: stale model lingered" || ok "commented case: stale model removed"

sec "capability: Mikrus ID = trailing digits of hostname (regression)"
[[ "$(_mikrus_id_from_hostname bob305)" == "305" ]] && ok "bob305 -> 305" || bad "bob305 -> $(_mikrus_id_from_hostname bob305) (want 305)"
[[ "$(_mikrus_id_from_hostname emil100)" == "100" ]] && ok "emil100 -> 100" || bad "emil100 wrong"
[[ "$(_mikrus_id_from_hostname f853)" == "853" ]] && ok "f853 -> 853" || bad "f853 wrong"
[[ "$(_mikrus_id_from_hostname f008)" == "8" ]] && ok "f008 -> 8 (base-10, no octal)" || bad "f008 -> $(_mikrus_id_from_hostname f008) (want 8)"
[[ -z "$(_mikrus_id_from_hostname nodigits)" ]] && ok "no digits -> empty" || bad "no-digits not empty"

sec "provider: strip model block with blank lines + comments (corruption regression)"
CFG4="$TMP/config4.yaml"
printf 'top_key: 1\n\n# Model Configuration\nmodel:\n  # inference provider selection\n  provider: "auto"\n\n  default: "old-model"\n  base_url: "https://old"\nterminal:\n  backend: local\n' > "$CFG4"
_write_model_block "$CFG4" gemini "gemini-3-flash"
[[ "$(grep -c '^model:' "$CFG4")" == "1" ]] && ok "single model: block after replace" || bad "duplicate model: block"
grep -qE '^[[:space:]]+provider: "auto"' "$CFG4" && bad "orphaned old model lines remain" || ok "no orphaned indented lines left"
grep -q 'old-model' "$CFG4" && bad "old model value lingered" || ok "old model value removed"
has "$(cat "$CFG4")" "backend: local" "preserved trailing section (terminal)"
has "$(cat "$CFG4")" "top_key: 1" "preserved leading key"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  python3 -c "import yaml; yaml.safe_load(open('$CFG4'))" 2>/dev/null && ok "result parses as valid YAML" || bad "result is INVALID YAML"
else
  echo "  (python3+yaml unavailable — skipping YAML validity check)"
fi

sec "provider: native selection (NVIDIA) writes provider id + its key env"
CFGP="$TMP/prov.yaml"; EFP="$TMP/prov.env"; : > "$EFP"; chmod 600 "$EFP"
HERMES_INSTALL_NONINTERACTIVE=1
ANS_PROVIDER="NVIDIA — NIM cloud"; ANS_NVIDIA_API_KEY="nvapi-test123"; ANS_MODEL="deepseek-ai/deepseek-r1"
configure_provider "$CFGP" "$EFP" >/dev/null 2>&1
has "$(cat "$CFGP")" "provider: nvidia" "config.yaml: provider: nvidia"
has "$(cat "$CFGP")" 'default: "deepseek-ai/deepseek-r1"' "config.yaml: model written"
grep -q '^NVIDIA_API_KEY=nvapi-test123' "$EFP" && ok "NVIDIA_API_KEY written to .env" || bad "key env not written"
unset HERMES_INSTALL_NONINTERACTIVE ANS_PROVIDER ANS_NVIDIA_API_KEY ANS_MODEL NVIDIA_API_KEY

sec "messaging: providing an allow-list must not abort under set -e (regression)"
EFM="$TMP/msg.env"; : > "$EFM"; chmod 600 "$EFM"
msg_out="$(cd "$REPO_DIR" && \
  HERMES_INSTALL_NONINTERACTIVE=1 NO_COLOR=1 \
  ANS_ENABLE_TELEGRAM=yes ANS_TELEGRAM_BOT_TOKEN='123:abc' ANS_TELEGRAM_ALLOWED_USERS='8753277875' \
  ANS_ENABLE_SLACK=no ANS_ENABLE_WHATSAPP=no ANS_ENABLE_EMAIL=no ANS_ENABLE_TEAMS=no ANS_ENABLE_GOOGLECHAT=no \
  bash -euo pipefail -c 'source lib/common.sh; source lib/messaging.sh; configure_messaging "'"$EFM"'" >/dev/null 2>&1; echo COMPLETED' 2>&1)"
[[ "$msg_out" == *COMPLETED* ]] && ok "configure_messaging completes with allow-list set (no set -e abort)" || bad "aborted under set -e when allow-list provided"
grep -q '^TELEGRAM_ALLOWED_USERS=8753277875' "$EFM" && ok "allow-list persisted to env" || bad "allow-list not written"

sec "webui_set_password: reuse existing on empty answer (idempotency)"
EF="$TMP/webui.env"; : > "$EF"; chmod 600 "$EF"
set_env_var "$EF" HERMES_WEBUI_PASSWORD "keepme123"
HERMES_INSTALL_NONINTERACTIVE=1; ANS_HERMES_WEBUI_PASSWORD=""
webui_set_password "$EF" >/dev/null 2>&1
grep -q '^HERMES_WEBUI_PASSWORD=keepme123$' "$EF" && ok "kept existing password on empty re-run" || bad "password changed on re-run"
unset HERMES_INSTALL_NONINTERACTIVE ANS_HERMES_WEBUI_PASSWORD

echo
sec "Result: ${PASS} PASS / ${FAIL} FAIL"
(( FAIL == 0 ))
