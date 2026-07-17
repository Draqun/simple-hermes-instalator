#!/usr/bin/env bash
# mikrus.sh — expose the (loopback-bound) WebUI to the internet on Mikrus.
#
# Verified Mikrus facts (wiki.mikr.us):
#   * Containers are unprivileged LXC with a shared kernel; you are root inside.
#   * Default forwarded ports: 10000+ID (SSH — never touch), 20000+ID, 30000+ID.
#     Extra ports (up to 7) are opened ONLY via the panel — no CLI exists.
#   * wykr.es: "serwer-port.wykr.es", automatic, Mikrus terminates HTTPS, your
#     app must be plain HTTP. Works ONLY on an already-allocated IPv4 port.
#   * mikrus.cloud: "serwer-port.mikrus.cloud", works for ANY port, but the app
#     must listen on IPv6 ([::]:port). Mikrus terminates HTTPS.
#
# Strategy: keep the WebUI on 127.0.0.1:8787 (never public) and put nginx in
# front, listening on both 0.0.0.0:PORT and [::]:PORT, proxying to the WebUI.
# Using PORT = 20000+ID (an allocated port) makes BOTH wykr.es and mikrus.cloud
# work, and keeps the WebUI itself off the public interface (defence in depth).

# mikrus_default_public_port -> echoes 20000+ID, or empty if ID unknown.
mikrus_default_public_port() {
  [[ -n "${MIKRUS_ID:-}" ]] && echo $(( 20000 + MIKRUS_ID )) || echo ""
}

# mikrus_public_urls SERVER PORT -> prints the two public URLs.
mikrus_public_urls() {
  local server="$1" port="$2"
  printf 'https://%s-%s.wykr.es\n'      "$server" "$port"
  printf 'https://%s-%s.mikrus.cloud\n' "$server" "$port"
}

# Render the nginx site config to stdout (pure function — no side effects, so
# it can be unit-tested). Proxies public PORT to the loopback WebUI.
render_nginx_site() {
  local public_port="$1" webui_port="$2" server_name="$3"
  cat <<EOF
# Managed by install-hermes-mikrus.sh — reverse proxy for Hermes WebUI.
# Mikrus terminates TLS at its edge (wykr.es / mikrus.cloud); backend is HTTP.
server {
    listen ${public_port};
    listen [::]:${public_port};
    server_name ${server_name}-${public_port}.wykr.es ${server_name}-${public_port}.mikrus.cloud _;

    # WebSockets / SSE (the WebUI streams tokens over SSE).
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;   # long-running agent responses
    proxy_buffering off;        # don't buffer SSE

    client_max_body_size 64m;   # chat attachments

    location / {
        proxy_pass http://127.0.0.1:${webui_port};
    }
}
EOF
}

# Side-effecting: install nginx if missing (Debian/Ubuntu apt).
mikrus_ensure_nginx() {
  if have_cmd nginx; then log_ok "nginx already present."; return 0; fi
  log_info "Installing nginx (reverse proxy)..."
  if have_cmd apt-get; then
    # -o DPkg::Lock::Timeout=180 waits for a busy apt lock (Mikrus first-boot /
    # unattended-upgrades often hold it) instead of failing immediately.
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq nginx \
      || { log_warn "Could not install nginx automatically."; return 1; }
  else
    log_warn "No apt-get found — install nginx manually."; return 1
  fi
}

# Write the site config, enable it, test and reload nginx.
# Our server block listens on a DEDICATED port (20000+ID), so it never
# conflicts with the stock port-80 default site — we deliberately leave any
# existing nginx sites (e.g. another app on :80) untouched.
mikrus_write_and_reload() {
  local public_port="$1" webui_port="$2" server_name="$3"
  local avail="/etc/nginx/sites-available/hermes-webui"
  local enabled="/etc/nginx/sites-enabled/hermes-webui"
  # Warn if something already listens on the chosen public port.
  if have_cmd ss && ss -ltnH 2>/dev/null | grep -qE "[:.]${public_port}\b"; then
    log_warn "Port ${public_port} already has a listener — nginx may fail to bind. Pick another allocated port."
  fi
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  render_nginx_site "$public_port" "$webui_port" "$server_name" > "$avail"
  ln -sf "$avail" "$enabled"
  if nginx -t 2>/dev/null; then
    if have_cmd systemctl; then systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    else nginx -s reload 2>/dev/null || true; fi
    log_ok "nginx configured on port ${public_port}."
  else
    log_warn "nginx config test failed — check 'nginx -t'."; return 1
  fi
}

# Full exposure flow. Sets globals PUBLIC_URL (primary) and PUBLIC_ORIGINS
# (both the wykr.es + mikrus.cloud origins, for the WebUI allow-list) for the
# caller to print / feed to webui_secure_behind_proxy.
PUBLIC_URL=""
PUBLIC_ORIGINS=""
mikrus_expose_webui() {
  local webui_port="${1:-8787}"
  log_step "Exposing the WebUI via Mikrus"

  if [[ "${MIKRUS_DETECTED:-no}" != "yes" ]]; then
    log_info "Not a Mikrus box — skipping public exposure."
    log_info "Reach the WebUI over an SSH tunnel: ssh -N -L 8787:127.0.0.1:${webui_port} <user>@<host>"
    return 0
  fi

  local default_port; default_port="$(mikrus_default_public_port)"
  local PUBLIC_PORT=""
  ask PUBLIC_PORT "Public port for the WebUI (an allocated Mikrus port, e.g. 20000+ID)" "${default_port:-20000}"

  if [[ "$PUBLIC_PORT" == "$(( 10000 + ${MIKRUS_ID:-0} ))" ]]; then
    log_warn "That is your SSH port — pick 20000+ID or 30000+ID instead."
    return 1
  fi

  mikrus_ensure_nginx || { log_warn "Skipping exposure (nginx unavailable)."; return 1; }
  mikrus_write_and_reload "$PUBLIC_PORT" "$webui_port" "${MIKRUS_SERVER:-$(hostname)}" || return 1

  local name="${MIKRUS_SERVER:-$(hostname)}"
  PUBLIC_URL="https://${name}-${PUBLIC_PORT}.wykr.es"
  PUBLIC_ORIGINS="https://${name}-${PUBLIC_PORT}.wykr.es,https://${name}-${PUBLIC_PORT}.mikrus.cloud"
  log_ok "Public URL: ${PUBLIC_URL}"
  log_info "Also available (IPv6): https://${name}-${PUBLIC_PORT}.mikrus.cloud"
  log_info "If wykr.es does not resolve, confirm port ${PUBLIC_PORT} is allocated in the Mikrus panel."
}
