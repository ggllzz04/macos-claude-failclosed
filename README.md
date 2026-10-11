# macos-claude-failclosed

[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](#requirements)
[![Shell: bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](#)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![No TLS interception](https://img.shields.io/badge/TLS-no%20interception-informational)](#)

Force **Anthropic (official) traffic through a local HTTP proxy**, and **fail closed** when that
proxy is unavailable or bypassed — so **direct connections to Anthropic are impossible** and
Anthropic only ever sees your proxy exit IP, not your real one.

Built for macOS with a local HTTP(S) proxy such as **Clash Verge / mihomo** (mixed port, e.g. `127.0.0.1:7897`).

---

## Why

A proxy *setting* is routing, not enforcement. If the proxy crashes, is turned off, or an app
ignores proxy variables, traffic silently falls back to a **direct connection**. This toolkit
closes that gap for Claude:

- **Nothing reaches Anthropic except through your proxy** (network-level, process-independent).
- **If the proxy dies, Anthropic access is cut** — no silent fallback.

## How it works

```
Claude / Claude Code ──▶ 127.0.0.1:7897 ──▶ proxy node ──▶ api.anthropic.com   ✅
        │
        └── direct attempt ──▶ pf: block drop  (160.79.104.0/21, 2607:6bc0::/48)  ⛔

proxy process gone / port down ──▶ claude-guard: kill Claude processes + notify  ⛔
```

Four independent layers:

| Layer | Component | Role |
|---|---|---|
| **L1** | Clash rules *(you add)* | Route Anthropic domains to a real proxy node (not `DIRECT`) |
| **L2** | `claude-desktop-egress-proxy.mobileconfig` + Claude Code `env` | Pin Claude's own traffic to the proxy, independent of the OS system proxy |
| **L3** | `claude-lock.pf` + `com.claude.pflock.plist` | Kernel-level **block** of direct connections to Anthropic IPs (v4 **and** v6), enforced regardless of proxy state |
| **L4** | `claude-guard.sh` + `com.claude.guard.plist` | If the proxy disappears, **kill all Claude processes** within ~0.5 s and post a macOS notification |

- **L3 is the guarantee.** Even if the proxy is down or the system proxy is disabled, any direct
  connection to the published Anthropic ranges is dropped by `pf`.
- **L4 is the backstop.** When Clash exits or crashes, Claude is terminated instead of retrying direct.

## Requirements

- macOS 13 or newer.
- A local HTTP(S) proxy (default convention `127.0.0.1:7897`). SOCKS-only is **not** supported by Claude Code.
- `sudo` (to write `/etc/pf.conf` and install LaunchDaemons).

## Quick start

```bash
git clone https://github.com/ggllzz04/macos-claude-failclosed.git
cd macos-claude-failclosed

# Install L3 + L4 (pf block + process guard + pf boot autostart)
sudo ./install.sh

# Verify — static checks first, then real requests
sudo ./verify.sh
sudo ./verify.sh --online
```

Installed by `install.sh`:

- `/usr/local/bin/claude-guard.sh` + `com.claude.guard.plist` — the process guard (LaunchDaemon, starts at boot).
- `/etc/pf.anchors/claude-lock` (anchored from `/etc/pf.conf`) — the pf block, enabled with `pfctl -E -f`.
- `com.claude.pflock.plist` — runs `pfctl -E -f /etc/pf.conf` at boot to complement Apple's
  `com.apple.pfctl`, which loads but does not necessarily *enable* pf.

Uninstall:

```bash
sudo ./uninstall.sh
```

## Configuration

### L1 — Clash rules (manual)

Prepend these to your rules (`<GROUP>` = your proxy selector group name):

```
DOMAIN-SUFFIX,anthropic.com,<GROUP>
DOMAIN-SUFFIX,claude.ai,<GROUP>
DOMAIN-SUFFIX,claude.com,<GROUP>
DOMAIN-SUFFIX,claudeusercontent.com,<GROUP>
DOMAIN-SUFFIX,claudemcpcontent.com,<GROUP>
```

> If these domains are not forced through a node, L3 will also drop your *legitimate* requests
> (when Clash routes them `DIRECT`, the egress IP is inside the blocked range).

### L2 — Pin Claude's own proxy

**Claude Code** — in the `env` block of `~/.claude/settings.json`:

```json
"HTTPS_PROXY": "http://127.0.0.1:7897",
"HTTP_PROXY":  "http://127.0.0.1:7897",
"NO_PROXY":    "localhost,127.0.0.1,::1"
```

> Using a third-party relay via `ANTHROPIC_BASE_URL`? Add the relay domain to `NO_PROXY` to keep it direct.

**Claude Desktop** — managed configuration (requires Desktop 1.44121.1+):

```bash
open ./claude-desktop-egress-proxy.mobileconfig
# then confirm it in System Settings → General → Device Management
```

> The key is `egressProxyUrl=http://127.0.0.1:7897`. **If your proxy port isn't 7897, edit the
> port inside this file first.** Once pinned, Desktop fails instead of falling back to a direct
> connection — native fail-closed.

### Guard tuning (environment variables)

Set them in `com.claude.guard.plist` (or the shell when testing):

Beyond the process/port check, the guard can also require that **TUN mode** and/or the **macOS
system proxy** are actually active — so it fires *even while Clash is still running* but its
proxy path was turned off.

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_GUARD_PORT` | `7897` | Local proxy port to watch |
| `CLAUDE_GUARD_PROXY_HOST` | `127.0.0.1` | Proxy host the system proxy must point at |
| `CLAUDE_GUARD_REQUIRE_TUN` | `0` | `1` = require TUN up, else treat as unavailable |
| `CLAUDE_GUARD_TUN_GW` | `198.18.0.1` | TUN / fake-ip gateway address to look for |
| `CLAUDE_GUARD_REQUIRE_SYSPROXY` | `0` | `1` = require the macOS system proxy to point at the proxy |
| `CLAUDE_GUARD_SAMPLE` | `0.25` | Poll interval (seconds) |
| `CLAUDE_GUARD_DEBOUNCE` | `2` | Consecutive "down" samples before acting |
| `CLAUDE_GUARD_GRACE` | `0` | Startup grace period (seconds) |
| `CLAUDE_GUARD_KILL_NOTIFY_MIN` | `20` | Min seconds between kill notifications |

The bundled `com.claude.guard.plist` ships with `REQUIRE_TUN=1` **and** `REQUIRE_SYSPROXY=1`.
Remove either line to relax — e.g. drop `REQUIRE_SYSPROXY` if you intentionally toggle the system
proxy off (TUN still carries the traffic).

Dry-run (prints what would be killed, kills nothing):

```bash
CLAUDE_GUARD_DRYRUN=1 ./claude-guard.sh
```

### Blocked ranges

`claude-lock.pf` uses Anthropic's **published, fixed** ranges:

- IPv4: `160.79.104.0/21`
- IPv6: `2607:6bc0::/48`

If Anthropic changes them, update the table — see <https://platform.claude.com/docs/en/api/ip-addresses>.

## Verification

`verify.sh` checks each layer:

- **Static (no traffic):** pf enabled, anchor loaded, table contents, LaunchDaemon loaded,
  guard script present, `7897` listening, Claude Code settings contain the proxy, guard dry-run.
- **`--online` (real requests):** direct connection to the real Anthropic IPs (v4 and v6) must
  **time out**, and a request **through the proxy** must succeed.

Expected online output:

```
OK   直连 v4 真实 IP 被阻断
OK   直连 v6 真实 IP 被阻断
OK   经代理可达（HTTP 401/403/404）
```

## Limitations

- macOS `pf` cannot match by process, so enforcement is **by destination IP**; the ranges above are
  Anthropic-owned (not shared Cloudflare), so collateral blocking is minimal.
- The guard **force-kills Claude** (unsaved work may be lost) and has a ~0.5 s detection window.
- Only the listed official hosts are covered; third-party relays, Bedrock/Vertex, and other
  provider endpoints need separate rules.
- Changing `pf` can interrupt your own network. Run `install.sh` step by step and keep `uninstall.sh` handy.

## Files

```
claude-guard.sh                           Process guard (L4) with macOS notifications
com.claude.guard.plist                    Guard LaunchDaemon
claude-lock.pf                            pf block rules (L3)
com.claude.pflock.plist                   pf boot autostart
install.sh / uninstall.sh                 Install / roll back
verify.sh                                 Verification (--online sends real requests)
claude-desktop-egress-proxy.mobileconfig  Claude Desktop proxy managed config (L2)
```

## 中文说明

让 Claude（Anthropic 官方）的流量**强制走本地代理**，代理不可用时**断网并杀掉 Claude 进程**，
从而**杜绝直连**——Anthropic 只会看到代理节点 IP，看不到你的真实 IP。

- **L3（pf 封锁）是真正的保证**：即使代理挂了/系统代理被关，直连官方 IP 也会被内核丢包。
- **L4（进程守护）是兜底**：Clash 崩溃/退出时 ~0.5 秒内强杀所有 Claude 进程并弹 macOS 通知。
- L1/L2 负责"让流量真的走代理"。

前提：macOS 13+、一个本地 HTTP 代理（默认 `127.0.0.1:7897`）、会用 `sudo`。
安装 `sudo ./install.sh`，校验 `sudo ./verify.sh --online`，回滚 `sudo ./uninstall.sh`。
L1/L2 需手动配置（见上文）。细节与限制见上。

## License

[MIT](LICENSE). Provided as-is, without warranty; review before running on your own machine.
