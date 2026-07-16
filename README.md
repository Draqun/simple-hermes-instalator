# Hermes on Mikrus — installer

Painless, interactive installer for the [Hermes agent](https://github.com/NousResearch/hermes-agent)
and its [WebUI](https://github.com/nesquena/hermes-webui) on a [Mikrus](https://mikr.us) VPS —
in the spirit of Mikrus's own `n8n_install`.

It is a **native (uv)** install, tuned for small boxes: it fits inside a **Mikrus 3.0 (2 GB RAM)**
as long as browser automation stays off (Hermes's own documented minimum is 1 GB / 2 GB with
browser tools). It also runs on larger plans (3.5+/4.x), auto-adapting to the RAM it finds.

## What it does

1. **Checks the machine** (RAM read from the cgroup limit, not the host), and recommends — never
   hard-blocks (use `--force` to push past warnings and test the limits).
2. **Installs the Hermes agent** via the official `uv` installer (Python 3.11 + Node + ripgrep +
   ffmpeg), skipping Playwright/Chromium unless you opt into browser tools.
3. **Configures your AI provider** (OpenRouter / Anthropic / a custom OpenAI-compatible endpoint /
   or defers to `hermes setup`), writing `~/.hermes/config.yaml` + `~/.hermes/.env`.
4. **Configures messaging bridges** (optional): Telegram, Slack, WhatsApp, Email, Microsoft Teams,
   Google Chat.
5. **Installs the WebUI**, bound to `127.0.0.1`, behind an nginx reverse proxy, reachable over
   Mikrus's automatic HTTPS subdomain — protected by a mandatory password.
6. **Sets up systemd services** (`hermes-gateway`, `hermes-webui`) with hardening, so the stack
   survives reboots.

## Requirements

- A Mikrus **2.1+** (Docker/systemd era). Recommended: **3.0 (2 GB)** or **3.5 (4 GB)** for comfort.
- Root shell on the box (the Mikrus default) and outbound HTTPS.
- ~3 GB free disk.

| RAM | Verdict | Default |
|---|---|---|
| ≥ 4 GB (Mikrus 3.5+) | comfortable | browser tools may be enabled |
| 2–4 GB (Mikrus 3.0) | OK | browser tools off |
| 1–2 GB (Mikrus 2.1) | conditional | off, watch memory |
| < 1 GB | discouraged | `--force` only |

### Measured footprint

Measured in a container mimicking Mikrus (RAM as **PSS** — real resident memory, excluding page
cache; disk = agent venv + repos + Chromium). See `test/measure.sh`.

| Scenario | RAM working set (measured) | RAM budget (recommended) | Disk (measured) | Mikrus plan |
|---|---|---|---|---|
| Browser **OFF** (agent + WebUI) | ~110–300 MB | ~1 GB | **~1.1 GB** | **3.0 (2 GB)** ✅ |
| Browser **ON**, idle | ~110–300 MB | ~2 GB | **~1.8 GB** | 3.0 works / 3.5 comfort |
| Browser **ON**, active session | **+~320 MB** per Chromium tab (blank); heavy pages spike to 0.5–1.5 GB | **4 GB** | ~1.8 GB | **3.5 (4 GB)** ✅ |

- The working set is small; the OS uses spare RAM as **reclaimable cache** — a 2 GB box showed
  ~1.67 GB "used" but most of that was cache, not required memory. More RAM = more cache = snappier,
  not strictly needed.
- **Chromium is the swing factor.** One blank tab ≈ +320 MB; real browser automation (multiple
  tabs, heavy sites) can add 0.5–1.5 GB — hence 4 GB for comfortable browser use.
- Mikrus has **no reliable swap** (file swap is documented as unstable), so leave headroom rather
  than counting on swap.

**Rule of thumb:** no browser tools → **Mikrus 3.0 (2 GB)** (verified). Browser tools → **Mikrus 3.5
(4 GB)**. Mikrus 3.0 *can* run browser tools but with thin margin and no swap cushion.

## Quick start

```bash
git clone <this-repo> hermes-mikrus
cd hermes-mikrus
bash install-hermes-mikrus.sh
```

You will be asked about your AI provider + key, optional messaging bridges, and a WebUI password.

### Flags

| Flag | Purpose |
|---|---|
| `--check-only` | Run only the capability check and exit. |
| `--dry-run` | Run the wizard and write config, but skip the heavy install. |
| `--update` | Update an installed stack (agent + WebUI together); backs up config first. |
| `--reconfigure` | Re-run the wizard without reinstalling. |
| `--uninstall` | Remove the stack (keeps data unless `--purge`). |
| `--force` | Proceed despite capability warnings. |
| `--service-user N` | Run the agent/WebUI/gateway as account `N` (default `hermes` when installing as root). |
| `--as-root` | Do **not** drop to a service user; run as root (not recommended). |
| `--auto-update` | Schedule a weekly `--update` (systemd timer, cron fallback). |
| `--answers FILE` | Non-interactive; read answers from an `ANS_*` file (see `test/answers.example.env`). |

## Exposure on Mikrus

Mikrus terminates HTTPS at its edge; your service stays plain HTTP behind it. Two facts drive the
design (verified from the Mikrus wiki):

- `serwer-PORT.wykr.es` works only on an **already-allocated IPv4 port** (`20000+ID`, `30000+ID`,
  or a port you opened in the panel — there is no CLI for that).
- `serwer-PORT.mikrus.cloud` works for **any port**, but the service must listen on **IPv6**.

So the installer keeps the WebUI on `127.0.0.1:8787` and puts **nginx** in front, listening on both
IPv4 and IPv6 of port `20000+ID` (an already-allocated port; a service on it is reachable over the
shared IPv4, and every Mikrus VPS also has a full IPv6 with all ports open). That makes both
`wykr.es` and `mikrus.cloud` work while the WebUI itself never faces the internet. Existing nginx
sites (e.g. an app on port 80) are left untouched — our server block owns only its dedicated port.
If `wykr.es` doesn't resolve, confirm the port is allocated in the Mikrus panel.

> **NOOBS:** this follows Mikrus's [NOOBS](https://github.com/unkn0w/noobs) convention (installer
> scripts in `/opt/noobs`). You can drop the script there alongside `n8n_install`, or contribute it
> upstream.

## Security

- Secrets live in `~/.hermes/.env` (mode `600`); keys are read with `read -s` and never passed on a
  command line (no `ps`/history leak).
- The upstream installer is fetched over `https`/TLS 1.2+ and its size + SHA-256 are printed before
  it runs.
- The WebUI password is **mandatory** (the box has public IPv6 on all ports); if you leave it blank
  the installer generates a strong one and prints it once.
- The agent API (`8642`) and dashboard (`9119`) stay loopback-only.
- systemd units are hardened (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`,
  `ReadWritePaths` scoped to `~/.hermes`).
- Browser tools default off — less memory, smaller attack surface.
- **Runs as a dedicated non-root user.** When launched as root, the installer creates a `hermes`
  service account and runs the agent, WebUI and gateway as it (systemd `User=hermes`). Hermes is an
  autonomous agent *with a shell tool*, so a compromise (or prompt injection) is contained to that
  account instead of root. Override with `--as-root`, or pick a name with `--service-user NAME`.

## Versioning

At the start the installer asks **which version** to install:

1. **Latest release tag** (recommended) — resolves the newest release tag of both
   `hermes-agent` and `hermes-webui` from GitHub and pins to them.
2. **Bleeding edge** — agent `main` / WebUI `master`.
3. **Custom** — enter a tag or commit for each.

Pinning to tags gives reproducible installs; upstream advises upgrading the agent and WebUI
together, which the "latest tag" option does in one shot.

## Updating / uninstalling

```bash
bash install-hermes-mikrus.sh --update      # upgrade agent + WebUI together (to latest), backs up config first
bash install-hermes-mikrus.sh --auto-update  # (at install time) schedule a weekly --update
bash uninstall-hermes-mikrus.sh             # remove services + proxy + timer, keep data
bash uninstall-hermes-mikrus.sh --purge     # also delete ~/.hermes (irreversible)
```

`--update` backs up `config.yaml`+`.env`, re-runs the upstream installer and `git pull`s the WebUI,
restarts services and probes `/health`. `--auto-update` (opt-in, install time) installs a weekly
systemd timer (`hermes-update.timer`; cron fallback) that runs `--update` for you.

## Testing locally (before buying a Mikrus)

A memory-capped container mimics Mikrus 3.0 (2 GB RAM, no swap, 1 CPU):

```bash
bash test/unit-test.sh        # host-side unit tests (fast, no Docker)
bash test/local-test.sh       # capability + dry-run wizard in a 2 GB container
bash test/local-test.sh --full  # real end-to-end install + /health probe (slow)
```

## Multiple profiles (separate identities / messengers)

Hermes has **profiles** — multiple fully isolated instances, each with its own config, memory,
model and messaging gateway. Use them to run separate "accounts", e.g. one profile on a Telegram
bot and another on Slack.

> On the default non-root install, run the `hermes` CLI **as the service user**. Either open a shell
> as it — `sudo -u hermes -i` (then run the commands below plainly) — or prefix each command with
> `runuser -u hermes --`.

```bash
hermes profile create work     # create a new isolated profile ("account")
hermes profile use work        # make it the active/sticky profile
hermes model                   # set THIS profile's AI provider + model (+ key)
hermes gateway setup           # configure THIS profile's messenger(s): Telegram / Slack / Discord / ...
hermes gateway install         # run this profile's gateway as a background (systemd) service
hermes profile list            # all profiles + their model + gateway status
hermes gateway list            # gateway status per profile
```

Each profile keeps its **own `.env`** (its own bot tokens / API keys) and its **own memory**, so a
Telegram bot on profile `work` and a Slack app on profile `home` never share credentials or context.
Within a single profile you can still enable several messengers at once — each with its own
`*_ALLOWED_USERS` allow-list. Switch the active profile any time with `hermes profile use <name>`
(the WebUI also has a profile switcher).

To set a messenger without the interactive wizard, switch to the profile and set its keys via
`hermes config set` / `hermes secrets` (they write that profile's `.env`), then `hermes gateway restart`.

**On Mikrus:** every profile with a *running* gateway is a separate process → more RAM. One or two
extra profiles are fine on 3.0 (2 GB); for several, prefer 3.5 (4 GB). The installer provisions the
`default` profile; add more with the commands above.

## Known limitations

- **Discord and Signal are not offered** — the current hermes-agent does not expose them via config
  (despite some marketing lists). Only the six bridges above are configurable.
- Public exposure can't be fully validated off-Mikrus (no `wykr.es`/panel without an account); the
  local test verifies the installer, footprint, and that the stack serves `/health`.
- Autostart needs real systemd (present on Mikrus). Without it, start the WebUI with
  `~/.hermes/hermes-webui/ctl.sh start`.
- **Switching provider from the WebUI Settings may not persist** to `config.yaml` for cross-provider
  model IDs (upstream bug [nesquena/hermes-webui#6131](https://github.com/nesquena/hermes-webui/issues/6131)).
  Workaround: switch providers with `hermes model` (or edit `~/.hermes/config.yaml` directly).

## License

[MIT](LICENSE). The upstream projects it installs — [hermes-agent](https://github.com/NousResearch/hermes-agent)
and [hermes-webui](https://github.com/nesquena/hermes-webui) — are MIT-licensed too.
