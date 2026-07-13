#!/usr/bin/env bash
# messaging.sh — configure Hermes messaging bridges (writes to ~/.hermes/.env).
#
# Bridges are exactly those documented in hermes-agent's .env.example for this
# version: Telegram, Slack, WhatsApp, Email (IMAP/SMTP), Microsoft Teams and
# Google Chat. NOTE: Discord and Signal are NOT configurable via env in the
# current hermes-agent — despite marketing lists elsewhere — so we do not offer
# them here (offering a bridge that writes vars Hermes ignores would be a lie).
#
# Every prompt name matches the env var it sets, so non-interactive answers use
# ANS_<ENVVAR> (e.g. ANS_TELEGRAM_BOT_TOKEN). Enable flags: ANS_ENABLE_<BRIDGE>.

# Warn (do not block) when a bridge is left open to everyone.
_warn_open_allowlist() {
  local users="$1" bridge="$2"
  [[ -z "$users" ]] && log_warn "$bridge: no allow-list set — the bot may respond to anyone who finds it. Consider restricting."
}

_bridge_telegram() {
  local env_file="$1" enable=""
  ask_yesno ENABLE_TELEGRAM "Configure the Telegram bridge?" N
  [[ "$ENABLE_TELEGRAM" != "yes" ]] && return 0
  local TELEGRAM_BOT_TOKEN="" TELEGRAM_ALLOWED_USERS="" TELEGRAM_HOME_CHANNEL=""
  log_info "Create a bot with @BotFather (https://t.me/BotFather) to get the token."
  ask_secret TELEGRAM_BOT_TOKEN "Telegram bot token"
  ask TELEGRAM_ALLOWED_USERS "Allowed Telegram user IDs (comma-separated)" ""
  ask TELEGRAM_HOME_CHANNEL   "Home chat ID for scheduled/cron delivery (optional)" ""
  [[ -z "$TELEGRAM_BOT_TOKEN" ]] && { log_warn "Empty token — skipping Telegram."; return 0; }
  set_env_var "$env_file" TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
  [[ -n "$TELEGRAM_ALLOWED_USERS" ]] && set_env_var "$env_file" TELEGRAM_ALLOWED_USERS "$TELEGRAM_ALLOWED_USERS"
  [[ -n "$TELEGRAM_HOME_CHANNEL" ]] && set_env_var "$env_file" TELEGRAM_HOME_CHANNEL "$TELEGRAM_HOME_CHANNEL"
  _warn_open_allowlist "$TELEGRAM_ALLOWED_USERS" "Telegram"
  log_ok "Telegram bridge configured."
}

_bridge_slack() {
  local env_file="$1"
  ask_yesno ENABLE_SLACK "Configure the Slack bridge?" N
  [[ "$ENABLE_SLACK" != "yes" ]] && return 0
  local SLACK_BOT_TOKEN="" SLACK_APP_TOKEN="" SLACK_ALLOWED_USERS=""
  log_info "From your Slack app (https://api.slack.com/apps): Bot token (xoxb-) and App token (xapp-, Socket Mode)."
  ask_secret SLACK_BOT_TOKEN "Slack bot token (xoxb-...)"
  ask_secret SLACK_APP_TOKEN "Slack app token (xapp-...)"
  ask SLACK_ALLOWED_USERS "Allowed Slack user IDs (comma-separated)" ""
  [[ -z "$SLACK_BOT_TOKEN" ]] && { log_warn "Empty bot token — skipping Slack."; return 0; }
  set_env_var "$env_file" SLACK_BOT_TOKEN "$SLACK_BOT_TOKEN"
  [[ -n "$SLACK_APP_TOKEN" ]] && set_env_var "$env_file" SLACK_APP_TOKEN "$SLACK_APP_TOKEN"
  [[ -n "$SLACK_ALLOWED_USERS" ]] && set_env_var "$env_file" SLACK_ALLOWED_USERS "$SLACK_ALLOWED_USERS"
  _warn_open_allowlist "$SLACK_ALLOWED_USERS" "Slack"
  log_ok "Slack bridge configured."
}

_bridge_whatsapp() {
  local env_file="$1"
  ask_yesno ENABLE_WHATSAPP "Configure the WhatsApp bridge?" N
  [[ "$ENABLE_WHATSAPP" != "yes" ]] && return 0
  local WHATSAPP_ALLOWED_USERS=""
  ask WHATSAPP_ALLOWED_USERS "Allowed WhatsApp numbers, e.g. 15551234567 (comma-separated)" ""
  set_env_var "$env_file" WHATSAPP_ENABLED "true"
  [[ -n "$WHATSAPP_ALLOWED_USERS" ]] && set_env_var "$env_file" WHATSAPP_ALLOWED_USERS "$WHATSAPP_ALLOWED_USERS"
  _warn_open_allowlist "$WHATSAPP_ALLOWED_USERS" "WhatsApp"
  log_info "After install, run 'hermes whatsapp' once to pair the device (scan the QR)."
  log_ok "WhatsApp bridge enabled."
}

_bridge_email() {
  local env_file="$1"
  ask_yesno ENABLE_EMAIL "Configure the Email (IMAP/SMTP) bridge?" N
  [[ "$ENABLE_EMAIL" != "yes" ]] && return 0
  local EMAIL_ADDRESS="" EMAIL_PASSWORD="" EMAIL_IMAP_HOST="" EMAIL_IMAP_PORT="" \
        EMAIL_SMTP_HOST="" EMAIL_SMTP_PORT="" EMAIL_ALLOWED_USERS=""
  log_info "For Gmail: enable 2FA and create an App Password (not your normal password)."
  ask        EMAIL_ADDRESS   "Email address" ""
  ask_secret EMAIL_PASSWORD  "Email password / app password"
  ask        EMAIL_IMAP_HOST "IMAP host" "imap.gmail.com"
  ask        EMAIL_IMAP_PORT "IMAP port" "993"
  ask        EMAIL_SMTP_HOST "SMTP host" "smtp.gmail.com"
  ask        EMAIL_SMTP_PORT "SMTP port" "587"
  ask        EMAIL_ALLOWED_USERS "Allowed sender addresses (comma-separated)" ""
  [[ -z "$EMAIL_ADDRESS" || -z "$EMAIL_PASSWORD" ]] && { log_warn "Missing address/password — skipping Email."; return 0; }
  set_env_var "$env_file" EMAIL_ADDRESS   "$EMAIL_ADDRESS"
  set_env_var "$env_file" EMAIL_PASSWORD  "$EMAIL_PASSWORD"
  set_env_var "$env_file" EMAIL_IMAP_HOST "$EMAIL_IMAP_HOST"
  set_env_var "$env_file" EMAIL_IMAP_PORT "$EMAIL_IMAP_PORT"
  set_env_var "$env_file" EMAIL_SMTP_HOST "$EMAIL_SMTP_HOST"
  set_env_var "$env_file" EMAIL_SMTP_PORT "$EMAIL_SMTP_PORT"
  [[ -n "$EMAIL_ALLOWED_USERS" ]] && set_env_var "$env_file" EMAIL_ALLOWED_USERS "$EMAIL_ALLOWED_USERS"
  _warn_open_allowlist "$EMAIL_ALLOWED_USERS" "Email"
  log_ok "Email bridge configured."
}

_bridge_teams() {
  local env_file="$1"
  ask_yesno ENABLE_TEAMS "Configure the Microsoft Teams bridge? (needs an Azure bot registration)" N
  [[ "$ENABLE_TEAMS" != "yes" ]] && return 0
  local TEAMS_CLIENT_ID="" TEAMS_CLIENT_SECRET="" TEAMS_TENANT_ID="" TEAMS_ALLOWED_USERS=""
  log_info "Register a bot in Azure (dev.botframework.com) to get client ID/secret/tenant."
  ask        TEAMS_CLIENT_ID     "Azure AD client (app) ID" ""
  ask_secret TEAMS_CLIENT_SECRET "Azure AD client secret"
  ask        TEAMS_TENANT_ID     "Azure AD tenant ID (or 'common')" "common"
  ask        TEAMS_ALLOWED_USERS "Allowed AAD object IDs / UPNs (comma-separated)" ""
  [[ -z "$TEAMS_CLIENT_ID" || -z "$TEAMS_CLIENT_SECRET" ]] && { log_warn "Missing client ID/secret — skipping Teams."; return 0; }
  set_env_var "$env_file" TEAMS_CLIENT_ID     "$TEAMS_CLIENT_ID"
  set_env_var "$env_file" TEAMS_CLIENT_SECRET "$TEAMS_CLIENT_SECRET"
  set_env_var "$env_file" TEAMS_TENANT_ID     "$TEAMS_TENANT_ID"
  [[ -n "$TEAMS_ALLOWED_USERS" ]] && set_env_var "$env_file" TEAMS_ALLOWED_USERS "$TEAMS_ALLOWED_USERS"
  _warn_open_allowlist "$TEAMS_ALLOWED_USERS" "Teams"
  log_ok "Microsoft Teams bridge configured."
}

_bridge_googlechat() {
  local env_file="$1"
  ask_yesno ENABLE_GOOGLECHAT "Configure the Google Chat bridge? (needs a GCP project + Pub/Sub)" N
  [[ "$ENABLE_GOOGLECHAT" != "yes" ]] && return 0
  local GOOGLE_CHAT_PROJECT_ID="" GOOGLE_CHAT_SUBSCRIPTION_NAME="" \
        GOOGLE_CHAT_SERVICE_ACCOUNT_JSON="" GOOGLE_CHAT_ALLOWED_USERS=""
  log_info "See website/docs/user-guide/messaging/google_chat.md for the GCP/Pub/Sub walkthrough."
  ask GOOGLE_CHAT_PROJECT_ID          "GCP project ID" ""
  ask GOOGLE_CHAT_SUBSCRIPTION_NAME   "Full subscription path (projects/<id>/subscriptions/<name>)" ""
  ask GOOGLE_CHAT_SERVICE_ACCOUNT_JSON "Path to service-account JSON key" ""
  ask GOOGLE_CHAT_ALLOWED_USERS       "Allowed emails (comma-separated)" ""
  [[ -z "$GOOGLE_CHAT_PROJECT_ID" || -z "$GOOGLE_CHAT_SUBSCRIPTION_NAME" ]] && { log_warn "Missing project/subscription — skipping Google Chat."; return 0; }
  set_env_var "$env_file" GOOGLE_CHAT_PROJECT_ID        "$GOOGLE_CHAT_PROJECT_ID"
  set_env_var "$env_file" GOOGLE_CHAT_SUBSCRIPTION_NAME "$GOOGLE_CHAT_SUBSCRIPTION_NAME"
  [[ -n "$GOOGLE_CHAT_SERVICE_ACCOUNT_JSON" ]] && set_env_var "$env_file" GOOGLE_CHAT_SERVICE_ACCOUNT_JSON "$GOOGLE_CHAT_SERVICE_ACCOUNT_JSON"
  [[ -n "$GOOGLE_CHAT_ALLOWED_USERS" ]] && set_env_var "$env_file" GOOGLE_CHAT_ALLOWED_USERS "$GOOGLE_CHAT_ALLOWED_USERS"
  _warn_open_allowlist "$GOOGLE_CHAT_ALLOWED_USERS" "Google Chat"
  log_ok "Google Chat bridge configured."
}

configure_messaging() {
  local env_file="$1"
  log_step "Messaging bridges (all optional)"
  log_info "Configure any chat platforms Hermes should talk on. Press Enter / answer 'n' to skip each."
  _bridge_telegram   "$env_file"
  _bridge_slack      "$env_file"
  _bridge_whatsapp   "$env_file"
  _bridge_email      "$env_file"
  _bridge_teams      "$env_file"
  _bridge_googlechat "$env_file"
}
