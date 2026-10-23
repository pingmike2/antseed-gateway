# Antseed Gateway v2

> 中文: [README.md](./README.md) · Install guide: [INSTALL.en.md](./INSTALL.en.md)

Wraps the Antseed P2P network into an OpenAI / Anthropic compatible HTTP proxy: health probing, fallback, blacklisting, streaming passthrough and free-model filtering all live in this layer.

```
client (Hermes / OpenAI SDK / curl)
        │  http://<host>:8377/v1
        ▼
  antseed-gateway (this repo, Python stdlib)
        │  http://127.0.0.1:8378/v1
        ▼
  antseed buyer (P2P client, official CLI)
```

## Install

```bash
# with a terminal you land in the menu: install/upgrade/uninstall/update CLI/status/logs/config
bash install.sh

# one-shot, no questions; generates a key when you do not pass one (use this for CI)
apikey='your-key' bash install.sh install

# see what it would do first
bash install.sh --dry-run

# install straight from the URL
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)
```

Requirements: Linux + systemd (root). Debian/Ubuntu, RHEL/Alma/Rocky/Fedora and Arch are supported; Alpine is refused explicitly (official Node 24 needs glibc).

Output is Chinese by default; add `--lang=en` (or `LANG_CODE=en`) for English.

When it finishes it prints `base_url` / `api_key` and runs a self-check (`/health` + `/v1/models`).

## Client setup

OpenAI compatible (Hermes, openai-python, LobeChat, OneAPI…):

```yaml
base_url: http://<host>:8377/v1
api_key:  «redacted:sk-…»
model:    auto              # auto / antseed / a concrete model id
```

Anthropic compatible (Claude Code style clients):

```
ANTHROPIC_BASE_URL=http://<host>:8377
ANTHROPIC_API_KEY=«redacted:sk-…»
ANTHROPIC_MODEL=auto
```

`auto` (or an empty model) lets the gateway pick the best model; the `X-Antseed-Model` response header tells you which one was used.

## API

| Path | Description |
| --- | --- |
| `POST /v1/chat/completions` | OpenAI chat, supports `stream: true` |
| `POST /v1/messages` | Anthropic messages, streaming supported |
| `GET /v1/models` | Currently routable models (free filter applied, `auto`/`antseed` first) |
| `GET /health` | Unauthenticated liveness probe: ok/healthy/counters only, leaks neither models nor identity |
| `GET /v1/health/detail` | Authenticated: per-model latency, failure counts, blacklist, request stats |

Response headers: `X-Antseed-Model` (model actually used), `X-Antseed-Attempt` (attempt number), `X-Antseed-Fallback` (whether a fallback happened).

Every entry in `/v1/models` carries `x_*` annotations (harmless to OpenAI clients):

| Field | Meaning |
| --- | --- |
| `x_healthy` | last probe passed and not cooling down |
| `x_latency_s` | EWMA latency |
| `x_routes_to` | where `auto` currently lands |
| `x_cooldown_for_s` | remaining seconds while cooling down |
| `x_last_error` | last failure reason (distinguishes quota from deposit 402s) |
| `x_free_peers` | **`$0 peers / all peers`**, e.g. `1/22` = only 1 of 22 peers is free |
| `x_needs_deposit` | a real request hit `insufficient_deposits`; this model probably needs a deposit |

`x_free_peers` is the only reliable signal for "nominally free ≠ free this time": the filter counts a model as free when *any* `$0` peer exists, but buyer picks among all peers, so a `1/22` model is easily routed to a paid one.

## Configuration

Everything lives in `/etc/antseed/gateway.env` (0600); `systemctl restart antseed-gateway` after edits.

**Reinstalling is idempotent**: running `bash install.sh` again only updates the values you pass explicitly (`apikey=`/`--key=`, `FREE_ONLY=`, `--port=`, `GATEWAY_BIND=`); every other line (including timeouts and blacklist durations you tuned) is kept, and the node identity is reused. Use `--force-rotate` to change identity.

### Routing

| Variable | Default | Description |
| --- | --- | --- |
| `UPSTREAM` | `http://127.0.0.1:8378` | buyer address |
| `FREE_ONLY` | `1` | route only `$0`-priced text models; naming a paid model returns 400 |
| `FALLBACK_ORDER` | `deepseek-v4-flash,glm-5.3-flash,openai-gpt-oss-120b` | priority within the same latency tier |
| `AUTO_FALLBACK` | `1` | try the next candidate on failure |
| `FALLBACK_NAMED` | `0` | whether to switch models after a named model fails (0 = report the error as-is, same as v1) |
| `SOFT_COOLDOWN` | `180` | cooldown for 402/429 where another peer might just work |
| `DEPOSIT_COOLDOWN` | `60` | cooldown for `insufficient_deposits`; shorter, since topping up or switching to a `$0` peer fixes it immediately |
| `MAX_ATTEMPTS` | `3` | candidates tried per request |

### Probing and blacklisting

| Variable | Default | Description |
| --- | --- | --- |
| `PROBE_INTERVAL` | `300` | background probe interval in seconds, `0` disables |
| `PROBE_TIMEOUT` | `45` | per-probe timeout |
| `PROBE_WORKERS` | `4` | concurrent probes |
| `FAIL_THRESHOLD` | `2` | consecutive failures before blacklisting |
| `BLACKLIST_SECONDS` | `900` | blacklist duration; excluded from candidates meanwhile |
| `HEALTHY_TTL` | `PROBE_INTERVAL*3` | health state expiry |

Candidate ordering: healthy → latency (EWMA) → `FALLBACK_ORDER` → name.

### Timeouts and limits

| Variable | Default | Description |
| --- | --- | --- |
| `STREAM_IDLE_TIMEOUT` | `90` | max idle between stream chunks; exceeding it drops the stream and counts |
| `NONSTREAM_TIMEOUT` | `300` | whole-request timeout for non-streaming |
| `CLIENT_TIMEOUT` | `300` | max total time per connection |
| `MAX_CONCURRENCY` | `64` | concurrent requests; beyond it returns 503 |
| `MAX_BODY_MB` | `64` | request body limit; beyond it returns 413 |

### 402 identity rotation

```ini
AUTO_ROTATE=0        # off by default
```

There are two kinds of `402` and they are handled differently:

| 402 kind | Detection | Handling |
| --- | --- | --- |
| Node's free quota exhausted | body has no `insufficient_deposits` | drop the candidate and fall back; `503 + Retry-After` when everything is 402 |
| **Deposit required** (`insufficient_deposits` / `out of AntSeed credits`) | peer is paid and `antseed buyer status` shows a zero deposit | short `DEPOSIT_COOLDOWN` (60s) + `x_needs_deposit` in `/v1/models` + **402 with an actionable message** (not `503 no healthy model`) |

A deposit shortfall actually returns **`400` + `invalid_request_error` + `code: model_requires_deposit`**, not 402: clients like DSH map `status === 402` to QUOTA and display "quota exhausted for this request", and they re-check with `insufficient[_-](quota|balance|credits)` — so status code, `type` and `code` must all avoid quota semantics. Setting `DEPOSIT_STATUS=402` restores the old behaviour, which means accepting that misleading client message.

The second kind is **not** a broken model and **not** today's usage running out. There are only two ways to make such a model usable: `antseed buyer deposit <amount>`, or use a free model with more `$0` peers (`auto` already lands on those).

`AUTO_ROTATE=1` additionally triggers `antseed-rotate.service` (oneshot): rotate identity → restart buyer → wait for readiness → retry the same model once.

**Why it is off by default**: rotating identity to refresh free quota runs into platform rate limits and risk controls — at best buyer gets long 429s, at worst the identity is blacklisted. That is a product-policy call, not a technical one. Enable it if you want, but know the cost.

## Operations

```bash
systemctl status antseed-gateway antseed-buyer
journalctl -u antseed-gateway -f
journalctl -u antseed-buyer -f

curl -s http://127.0.0.1:8377/health | python3 -m json.tool
curl -s -H "Authorization: Bearer ***" http://127.0.0.1:8377/v1/health/detail | python3 -m json.tool
curl -s -H "Authorization: Bearer ***" http://127.0.0.1:8377/v1/models | python3 -m json.tool
```

Changing the key, port or timeouts: edit `/etc/antseed/gateway.env`, then `systemctl restart antseed-gateway`. No reinstall needed.

Changing the API key (reminds you to update clients):

```bash
bash install.sh --key=sk-antseed-new-key
```

Rotating the node identity:

```bash
systemctl start antseed-rotate.service      # manual rotation, log at /var/log/antseed-rotate.log
bash install.sh --force-rotate             # or force it during a reinstall (= FORCE_ROTATE=1)
```

## Upgrade / uninstall

```bash
bash install.sh upgrade          # replace the program and units, keep config and identity
bash install.sh uninstall        # stop and remove the program; keep /etc/antseed and the node identity
bash install.sh uninstall --purge  # also remove config and node identity
```

## Hacking on this project

```bash
vim gateway.py                   # change the gateway
python3 tests/test_gateway.py    # 59 behaviour tests: fake upstream + real gateway process, no buyer needed
bash tools/build-install.sh      # regenerate install.sh (verifies the embedded copy is byte-identical)
bash install.sh --dry-run        # inspect the install flow
```

`install.sh` is a build artifact — do not hand-edit it, the next build overwrites your changes. The `gateway.py` embedded in the installer must be **the same code**, otherwise "you tested A and shipped B", which is exactly where self-contained installers break.

### Repository layout

| Path | Description |
| --- | --- |
| `gateway.py` | the gateway program (pure stdlib Python 3.7+) |
| `install.sh.tpl` → `install.sh` | installer source and its build artifact (self-contained, embeds `gateway.py`) |
| `tools/build-install.sh` | generates `install.sh` and verifies it forwards and backwards, byte for byte |
| `tests/` | behaviour tests (fake upstream + real gateway process, never touches production) |

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `/v1/models` only has `auto`/`antseed` | buyer is not ready, or no free node exists: `curl 127.0.0.1:8378/v1/models`, `journalctl -u antseed-buyer -n 50` |
| Everything returns 503 | check `/v1/health/detail` — probably all blacklisted; wait `BLACKLIST_SECONDS` or `systemctl restart antseed-gateway` to clear in-memory state |
| Always 401 | the key in `gateway.env` picked up quotes/spaces, or the client sends `Authorization: *** / `x-api-key` |
| Streaming looks stuck | `STREAM_IDLE_TIMEOUT` too small, or the client/Nginx buffers: `proxy_buffering off;` |
| buyer restarts repeatedly | `journalctl -u antseed-buyer`; on OOM lower `MAX_CONCURRENCY` or move to a larger instance |
| Unreachable from outside | is `GATEWAY_BIND` still `127.0.0.1`; does the cloud security group allow the port |

## Acknowledgements

This project stands on the shoulders of these public projects:

| Project | Role |
| --- | --- |
| [Antseed](https://antseed.com) | the upstream itself — an open market for AI inference; all model capacity here comes from it |
| [@antseed/cli](https://www.npmjs.com/package/@antseed/cli) | the official P2P client (`antseed buyer`); the gateway forwards requests to its local port 8378 |
| [Node.js](https://nodejs.org/) | runtime for the official CLI; `install.sh` installs a bundled copy and leaves the system Node alone |

The gateway itself has zero third-party dependencies — Python standard library only.

## Disclaimer

This project is for learning, research and personal technical experimentation only. Do not use it in any way that may violate a third party's terms of service or applicable law.

- This project is **unofficial** and is not affiliated with or endorsed by Antseed or its operators. The repository contains and distributes none of the upstream code — `@antseed/cli` is an independently published npm package (proprietary), fetched from npm by the install script.
- Availability of free models and free quota depends entirely on upstream policy and can change or disappear at any time (delisting, gating, rate limiting, protocol changes, risk-control bans). This project makes no guarantee about continuity or stability. **The free channel can break at any moment — that is the nature of a free tier, not a bug.**
- If you need a stable channel, use the [official CLI](https://www.npmjs.com/package/@antseed/cli) with official account quota.
- The gateway collects and reports no user data and does not persist request contents; runtime logs go only to the local systemd journal. Your API key and node identity exist only on the local machine under `/etc/antseed/`.
- Any account bans, quota loss, costs, legal or financial risk arising from accessing upstream through this project are borne by the user. Using this project means you understand and accept that.
- The software is provided under the MIT license "AS IS", without warranty of any kind (see [LICENSE](./LICENSE)).

## License

[MIT](./LICENSE) © 2026 [pingmike2](https://github.com/pingmike2)
