# Installation Guide

> 中文版: [安装说明.md](./安装说明.md) · Project home: [README.md](./README.md)

Three parts: **first install**, **upgrading an existing install**, **the menu**. Troubleshooting at the end.

---

## 1. First install

### Requirements

| Item | Requirement |
| --- | --- |
| OS | Linux + systemd (root). Debian/Ubuntu, RHEL/Alma/Rocky/Fedora, Arch |
| Arch | x86_64 / arm64 |
| RAM | 768MB or more recommended. 512MB runs, but adding sing-box on top will OOM |
| Ports | `8377` public (gateway), `8378` localhost only (buyer) |
| Network | reachable npm registry and the P2P network |

Explicitly unsupported: Alpine (official Node 24 needs glibc), macOS, native Windows. On Windows use WSL2 with systemd enabled.

### One command

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)
```

With a terminal attached you land in the menu. To skip the menu:

```bash
apikey='sk-antseed-your-key' bash install.sh install
```

Omit the key and one is generated for you, printed at the end.

### What the installer does

1. Platform gate — Windows/macOS/WSL without systemd gets clear instructions instead of a half-finished install
2. Checks Python >= 3.7 and system dependencies
3. Prepares Node 24: reuses the system one when new enough, otherwise downloads a bundled build (SHA256 verified)
4. Installs the official `@antseed/cli`, generates or reuses the node identity
5. Writes the gateway program to `/usr/local/bin/antseed-gateway.py`
6. Writes three systemd units: `antseed-gateway`, `antseed-buyer`, `antseed-rotate`
7. Starts the services and waits for buyer to become ready
8. Self-checks: `/health` + `/v1/models` + one real completion

### How long the first install takes

**On first start the buyer installs a P2P plugin with npm**, which takes 3–5 minutes on a small VPS. The installer waits up to 5 minutes and reports progress every 60 seconds:

```
[antseed-gateway] still waiting for buyer (60s): the first start installs a P2P plugin, which can take minutes on slow hosts
```

That line is not a hang — do not Ctrl-C. Later starts take about ten seconds.

### Using it

```yaml
base_url: http://<your-ip>:8377/v1
api_key:  <the key printed at the end of the install>
model:    auto
```

Anthropic-compatible clients:

```
ANTHROPIC_BASE_URL=http://<your-ip>:8377
ANTHROPIC_API_KEY=<your key>
ANTHROPIC_MODEL=auto
```

### Common install flags

```bash
bash install.sh --dry-run          # print what would happen, change nothing
bash install.sh --lang=en          # English output (Chinese by default)
FREE_ONLY=0 bash install.sh        # allow paid models (default 1 = free only)
GATEWAY_BIND=:: bash install.sh    # listen address (dual-stack by default)
--port=9000                        # change the public port
```

---

## 2. Upgrading an existing install

### What is kept

- `/etc/antseed/gateway.env` (API key, port, and every timeout/blacklist value you tuned by hand)
- The node identity in `/root/.antseed`
- The official CLI and the Node runtime

### What is replaced

- `/usr/local/bin/antseed-gateway.py` (the gateway program)
- The three systemd units (program paths, `PATH`, restart policy)

### How to upgrade

Pick `2` in the menu, or run:

```bash
bash install.sh upgrade
```

The upgrade rewrites the units → `daemon-reload` → restarts the gateway → **restarts buyer and waits for it to be ready** → checks `/health`.

### Is it seamless?

Yes. **No uninstall is needed first.** Upgrades are idempotent; running it repeatedly gives the same result.

Bugs found on the upgrade path, all fixed:

- Old buyer units had no `PATH`, so npm could not be found and buyer restarted forever — the upgrade rewrites the unit
- With a bundled Node, `npm prefix -g` can return empty, pointing the unit at a path that does not exist — the installer now derives the prefix from Node itself
- `wait_upstream` was defined after the upgrade dispatch, producing `command not found` — fixed

**Units are managed by the installer**: manual edits to them are overwritten. Edits to `gateway.env` survive.

### Starting over

```bash
bash install.sh uninstall --purge   # removes config and node identity too
bash install.sh                     # install again
```

---

## 3. The menu

After installing, a shortcut exists on disk — `antseed-gw` (created by the installer). **No need to paste the long command again:**

```bash
antseed-gw                # open the menu
antseed-gw status         # status + self-check
antseed-gw upgrade        # upgrade
antseed-gw logs -f        # follow logs
```

Each run fetches the latest installer first (so upgrades always use the current one); if the network is down it falls back to the local copy at `/usr/local/share/antseed-gateway/install.sh`. Uninstalling removes it too.

You can also run `bash install.sh` directly. **Single keypress selects — no Enter needed.**

```
==================================================
   Antseed Gateway console        installer v2.0.10
--------------------------------------------------
   gateway 2.0.10 active   CLI 0.1.202   port 8377
--------------------------------------------------
  1) install / reinstall    (keeps existing config and node identity)
  2) upgrade gateway        (program + units only, config untouched)
  3) uninstall gateway      (optionally delete config and identity)
  4) update official CLI    (installs @antseed/cli only when newer)
  5) status & self-check    (/health, models, ports)
  6) logs                   (last 60 lines / follow live)
  7) edit config            (API key, port, FREE_ONLY…)
  0) quit
==================================================
  select [0-7] (single key):
```

| Key | Action | Equivalent command |
| --- | --- | --- |
| `1` | install / reinstall (keeps config and identity) | `apikey=KEY bash install.sh install` |
| `2` | upgrade program and units | `bash install.sh upgrade` |
| `3` | uninstall (optionally with config and identity) | `bash install.sh uninstall [--purge]` |
| `4` | update the official CLI (only when newer) | `bash install.sh update-cli [--check]` |
| `5` | status and self-check | `bash install.sh status` |
| `6` | logs (last 60 lines / follow live) | `bash install.sh logs [--follow]` |
| `7` | edit config | `bash install.sh config` |
| `0` / `q` / Enter | quit | — |

Each action ends at `press Enter to return to the menu...`; Enter goes back, `Ctrl-C` exits.

**Non-interactive environments** (CI, no tty) skip the menu, install directly, and tell you: use `bash install.sh menu` for the menu.

### Interaction rules (consistent everywhere)

Only two kinds of input exist in the menu:

- **Choices and toggles**: a single key, applied immediately, no Enter
  - the main menu, `0-7` in edit config, `FREE_ONLY [0/1]`, `FALLBACK_NAMED [0/1]`, `AUTO_ROTATE [0/1]`, logs `1/2`, the uninstall `[y/N]`
  - these prompts say "single key"
- **Typed values**: confirmed with Enter
  - API key, bind address, port, probe interval, catalog cache
  - these prompts say "Enter to confirm"

Other conventions:

- Every action ends at `press any key to return to the menu...` — **any key** returns, no Enter
- In the main menu, `0` / `q` / bare Enter quits
- Live log following exits with `Ctrl-C`
- Fast typing never loses a key: an extra key read is pushed back for the next prompt

---

## 4. Troubleshooting

| Symptom | Check |
| --- | --- |
| `/v1/models` only shows `auto`/`antseed` | buyer is not ready: `curl 127.0.0.1:8378/v1/models`, `journalctl -u antseed-buyer -n 50` |
| Install sits at "still waiting for buyer" | Normal — the P2P plugin is being installed. Past 5 minutes, check `journalctl -u antseed-buyer -n 60` |
| Unreachable from outside | Is `GATEWAY_BIND` still `127.0.0.1`? Does the cloud security group allow 8377? |
| Always 401 | The key in `gateway.env` picked up quotes or spaces, or the client is not sending `Authorization: Bearer` |
| Port already in use | `ss -ltnp \| grep 8377`; the installer also checks before starting |
| A just-pushed version will not install | `raw.githubusercontent.com` caches for about 5 minutes — wait and retry |
| Change the API key | `bash install.sh --key=NEWKEY` (reminds you to update clients) |
| Rotate the node identity | `systemctl start antseed-rotate.service` or `bash install.sh --force-rotate` |

Configuration reference and API surface: [README.en.md](./README.en.md).
