# Hermes-on-Mikrus — installer design

Date: 2026-07-13
Status: implemented and verified (see §8)

## 1. Goal

A painless, interactive installer for the **Hermes agent** (`NousResearch/hermes-agent`) plus its
**WebUI** (`nesquena/hermes-webui`) on a **Mikrus** VPS — in the spirit of Mikrus's `n8n_install`.
Two equal goals:

1. **Real, daily use** on a Mikrus 3.0 (2 GB RAM) → memory-conscious by default.
2. **A reusable, generic installer** for a broader audience → idempotent, parameterizable, with a
   capability check and conditional warnings rather than hard blocks.

Cross-cutting requirements: **security** and an **`--update`** flag that upgrades an installed stack.

## 2. Reality check (verified)

| Resource | Hermes min (own docs) | Hermes recommended | Mikrus 3.0 | Mikrus 3.5 |
|---|---|---|---|---|
| RAM | 1 GB | 2–4 GB | 2 GB | 4 GB |
| CPU | 1 core | 2 cores | shared | shared |
| Disk (data) | 500 MB | 2+ GB | 25 GB | 40 GB |

Key quote from Hermes's own Docker docs: *"If you don't need browser tools, 1 GB is sufficient.
With browser tools active, allocate at least 2 GB."* → **Mikrus 3.0 sits within Hermes's
recommendation** with browser tools off. Hostinger's 8 GB figure was for their managed VPS product,
not a real minimum.

## 3. Architecture — NATIVE (uv) install

Decision: **native, not Docker.** Rationale: lighter disk (venv ~1–2 GB vs a 5 GB+ Docker image),
no Docker daemon overhead on a 2 GB box, and a natural topology — the WebUI runs the agent
**in-process** (it imports the agent's modules from the agent venv), so multi-container Docker would
introduce documented coupling hacks (a shared source volume; issue #681: tools run in the wrong
container).

Root vs non-root layout differ (the upstream installer's convention):

```
# root install (the Mikrus case)
/usr/local/lib/hermes-agent/   # agent code + uv venv
/usr/local/bin/hermes          # CLI
/root/.hermes/                 # data: config.yaml, .env (600), sessions/, memories/, skills/, cron/, logs/
/root/.hermes/hermes-webui/    # WebUI clone + ctl.sh (webui.pid / webui.log)

# non-root install
~/.hermes/hermes-agent/, ~/.local/bin/hermes, ~/.hermes/...
```

- Agent: installed by the official `curl … install.sh | bash` (bundles uv, Python 3.11, Node,
  ripgrep, ffmpeg). We pass `--skip-setup` (we run our own wizard) and `--skip-browser` unless the
  user opts into browser tools.
- WebUI: `git clone` (branch `master`), run as a daemon. It is pointed at the real agent dir via
  `HERMES_WEBUI_AGENT_DIR` (critical: on a root install the agent is in `/usr/local/lib`, which the
  WebUI's own auto-discovery does not check). Bound to `127.0.0.1:8787`.
- Exposure: an **nginx reverse proxy** on port `20000+ID` (IPv4 + IPv6) proxies to the loopback
  WebUI, reachable via Mikrus's automatic-HTTPS subdomains (`wykr.es` over IPv4, `mikrus.cloud` over
  IPv6). The WebUI never faces the internet directly; a password is mandatory.
- Agent API (8642) and dashboard (9119) stay disabled / loopback-only.

## 4. Installer flow (interactive, n8n-style)

1. **Capability check** (auto) → report + recommendation (never a hard block).
2. **Browser tools** → default OFF below 4 GB RAM (decided before install so we can pass
   `--skip-browser` to the upstream installer).
3. **AI provider** → menu (OpenRouter / Anthropic direct / custom OpenAI-compatible / defer to
   `hermes setup`) → key (`read -s`) → model. Written to `config.yaml` + `.env`.
4. **Messaging bridges** → per-bridge yes/no (Telegram / Slack / WhatsApp / Email / MS Teams /
   Google Chat) → tokens.
5. **WebUI** → clone, mandatory password, bind 127.0.0.1.
6. **systemd services** (hardened) → `hermes-gateway` (always-on agent) + `hermes-webui`.
7. **Exposure** → nginx reverse proxy + print the public URL.

Non-interactive mode: `--answers FILE` (`ANS_*` variables) for tests/CI/repeatability.

### CLI flags
- `--update` — back up `config.yaml`+`.env`, re-run the upstream installer (same flags, `</dev/null`),
  `git pull` the WebUI ("upgrade both together"), restart services, probe `/health`.
- `--reconfigure` — re-run the wizard without reinstalling.
- `--uninstall` — clean teardown (separate script; keeps data unless `--purge`).
- `--check-only` — capability report only.
- `--dry-run` — wizard + write config, skip the heavy install.
- `--force` — proceed past capability warnings (test the limits).
- `--answers FILE` — non-interactive.

## 5. Capability check — thresholds

Reads the **cgroup memory limit**, not host RAM (Mikrus is LXC; `/proc/meminfo` reports host memory).

| RAM | Verdict | Default |
|---|---|---|
| ≥ 4 GB (Mikrus 3.5+) | ✅ comfortable | browser tools allowed |
| 2–4 GB (Mikrus 3.0) | ✅ OK | browser tools OFF |
| 1–2 GB (Mikrus 2.1) | ⚠️ conditional | OFF, watch memory |
| < 1 GB | ⛔ discouraged | `--force` only |

Also checks: free disk ≥ ~3 GB, x86_64/arm64 arch, git/curl present, and best-effort Mikrus
detection (server name + ID parsed from `hostname`; there is no plan/spec query command).

## 6. Configuration keys (verified against source)

**AI provider** — minimal `config.yaml` is just `model.default`; `model.provider` defaults to `auto`
and is resolved from whichever credential is present. Provider values come from
`hermes_cli/auth.py::PROVIDER_REGISTRY`. Written forms:
- OpenRouter: `provider: openrouter`, `OPENROUTER_API_KEY`, model `vendor/model`.
- Anthropic direct: `provider: anthropic`, `ANTHROPIC_API_KEY`, model bare (`claude-opus-4-6`).
- Custom OpenAI-compatible: `provider: custom` + `model.base_url` + `model.key_env` → a `.env` var.
  (`OPENAI_API_KEY`/`OPENAI_BASE_URL` only apply to `provider: openai-api`, not generic custom.)

Secrets go to `.env` (mode 600); non-secrets to `config.yaml`. `hermes setup --non-interactive` is a
no-op (prints guidance), so writing the files directly is the supported non-interactive path.
Validation: `hermes doctor` (its exit code is always 0 → parse stdout).

**Messaging bridges** (`.env`), exactly those in the agent's `.env.example`:
Telegram (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`),
Slack (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`),
WhatsApp (`WHATSAPP_ENABLED`, `WHATSAPP_ALLOWED_USERS`; `hermes whatsapp` to pair),
Email (`EMAIL_ADDRESS`, `EMAIL_PASSWORD`, `EMAIL_IMAP_HOST/PORT`, `EMAIL_SMTP_HOST/PORT`,
`EMAIL_ALLOWED_USERS`), MS Teams (`TEAMS_CLIENT_ID/SECRET/TENANT_ID/…`),
Google Chat (`GOOGLE_CHAT_PROJECT_ID/SUBSCRIPTION_NAME/…`).
**Discord and Signal are NOT offered** — they are not configurable via env in this agent version.

**WebUI** (`.env`): `HERMES_WEBUI_PORT=8787`, `HERMES_WEBUI_HOST=127.0.0.1`,
`HERMES_WEBUI_PASSWORD` (mandatory), `HERMES_WEBUI_AGENT_DIR`.

## 7. Security

- **Secrets**: `~/.hermes/.env` at mode 600; keys read with `read -s`, never in argv/ps/history/logs.
  The answers file is `source`-d without `set -a` (so `ANS_*` are not exported into child processes).
- **Downloads**: `curl --proto '=https' --tlsv1.2 -fsSL`; the upstream installer's size + SHA-256 are
  printed before it runs.
- **Exposure**: mandatory strong `HERMES_WEBUI_PASSWORD` (the box has public IPv6 on all ports); WebUI
  bound to 127.0.0.1 behind nginx; TLS terminated at the Mikrus edge; agent API/dashboard loopback.
- **systemd hardening**: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only` +
  scoped `ReadWritePaths`, `PrivateTmp`, `PrivateDevices`, `ProtectKernelModules/Logs`, `ProtectClock`,
  `RestrictNamespaces`, empty `CapabilityBoundingSet`, `UMask=0077`. (SystemCallFilter/
  RestrictAddressFamilies deliberately omitted — they commonly break Python/Node and couldn't be
  validated without live systemd.)
- **Root note**: Mikrus gives root in an *unprivileged* LXC container; the installer follows Mikrus
  conventions (root + system units) and relies on the hardening above. A dedicated service user is a
  reasonable future step.
- **Attack surface**: browser tools default off; minimal extras.

## 8. Verification

`test/unit-test.sh` (host, no Docker): 41 assertions — env writes (mode 600), password generator,
prompt resolution, nginx/systemd render functions, and `config.yaml` generation incl. block/inline/
commented `model:` replacement.

`test/local-test.sh` (container mimicking Mikrus 3.0: `--memory=2g --memory-swap=2g --cpus=1`):
capability tiers + `--force`, and a `--dry-run` wizard writing config. `--full` runs a real
end-to-end install and probes `/health`.

**Verified end-to-end in a 2 GB container:** the agent installs (headless), the WebUI answers
`GET /health` with 200, and the stack runs within the 2 GB cap.

`test/measure.sh` (PSS footprint, browser off vs on):

| Scenario | RAM (working set) | Disk | Mikrus plan |
|---|---|---|---|
| Browser OFF | ~110–300 MB | ~1.1 GB | 3.0 (2 GB) |
| Browser ON, active | +~320 MB per Chromium tab; heavy pages 0.5–1.5 GB | ~1.8 GB | 3.5 (4 GB) |

Not verifiable off-Mikrus: real `wykr.es`/`mikrus.cloud` reachability (no account). nginx listens on
both IPv4 and IPv6 of `20000+ID` so either proxy path works; confirmed against the wiki.

## 9. Deliverables

```
hermers/
├── install-hermes-mikrus.sh
├── uninstall-hermes-mikrus.sh
├── lib/{common,capability,provider,messaging,webui,mikrus}.sh
├── test/{unit-test.sh,local-test.sh,measure.sh,answers.example.env,answers.browser-on.env}
├── README.md · LICENSE (MIT)
└── docs/plans/2026-07-13-hermes-mikrus-installer-design.md
```

## 10. Notes / Mikrus facts that shaped the design

- Mikrus is unprivileged LXC, shared kernel; **file-based swap is documented as unstable** → we do
  not create a swapfile there and lean on memory frugality instead.
- Ports: `10000+ID` (SSH), `20000+ID`, `30000+ID` are the forwarded IPv4 ports; up to 7 total, opened
  only via the panel (no CLI). Each VPS also has a full IPv6 with all ports open.
- `wykr.es` works on an allocated IPv4 port; `mikrus.cloud` works on any port over IPv6. Mikrus
  terminates HTTPS; the backend stays plain HTTP.
- Follows the NOOBS convention (`/opt/noobs`, `github.com/unkn0w/noobs`).
