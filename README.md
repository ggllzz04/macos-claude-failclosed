# Claude Fail-Closed (macOS)

让 Claude（Anthropic 官方）的流量**强制走本地代理**，并在**代理不可用时断网/杀进程**（fail-closed），
同时**防止直连**，让 Anthropic 侧只看得到代理节点 IP。

面向 macOS + 本地 HTTP 代理（示例为 Clash Verge / mihomo 的混合端口）。

> 只处理 **官方 Anthropic 端点**；不涉及第三方中转域名（可自行加 Clash 规则）。

---

## 组成（4 层）

| 层 | 文件 | 作用 |
|---|---|---|
| L1 Clash 规则 | （需你在 Clash 里加，见下） | 让官方域名真的走节点，而不是 `DIRECT` |
| L2 应用代理 | `claude-desktop-egress-proxy.mobileconfig` + Claude Code 的 `env` | 把 Claude 自己的代理钉死，不依赖系统代理 |
| L3 pf 防火墙 | `claude-lock.pf` + `com.claude.pflock.plist` | 内核层封掉**直连**官方 IP（v4+v6），与代理状态无关 |
| L4 进程守护 | `claude-guard.sh` + `com.claude.guard.plist` | 代理一消失，~0.5s 内强杀所有 Claude 进程并弹通知 |

设计要点：
- **L3 是真正的"阻断"**：即使代理挂了、系统代理被关，直连官方 IP 也会被丢包。
- **L4 是"兜底"**：Clash 崩溃/退出时，直接把 Claude 进程杀掉，避免任何直连尝试。
- L1/L2 负责"让流量真的走代理"；L3 负责"没走成就断"。

---

## 前提

- macOS 13+。
- 一个本地 HTTP(S) 代理（默认约定 `127.0.0.1:7897`）。Clash Verge 的"混合端口"即是。
- 需要 `sudo`（写 `/etc/pf.conf`、装 LaunchDaemon）。
- Claude Code 走后端时不支持 SOCKS，代理地址要用 `http://`。

---

## 快速开始

```bash
# 1) 安装 L3 + L4（pf 封锁 + 进程守护 + pf 开机自启）
cd ClaudeFailClosed
sudo ./install.sh

# 2) 校验（默认静态检查；--online 会发真实请求）
sudo ./verify.sh
sudo ./verify.sh --online
```

`install.sh` 会：
- 装 `/usr/local/bin/claude-guard.sh` + `com.claude.guard.plist`（LaunchDaemon，开机自启）
- 写 `/etc/pf.anchors/claude-lock` 并在 `/etc/pf.conf` 追加 anchor；`pfctl -E -f` 启用
- 装 `com.claude.pflock.plist`（开机 `pfctl -E -f`，补系统 `com.apple.pfctl` 只加载不启用的缺口）

卸载：
```bash
sudo ./uninstall.sh
```

---

## L1：Clash 规则（手动，在 Clash Verge 里加）

在订阅规则的**最前面**加（`<节点组>` 换成你的代理组名）：
```
DOMAIN-SUFFIX,anthropic.com,<节点组>
DOMAIN-SUFFIX,claude.ai,<节点组>
DOMAIN-SUFFIX,claude.com,<节点组>
DOMAIN-SUFFIX,claudeusercontent.com,<节点组>
DOMAIN-SUFFIX,claudemcpcontent.com,<节点组>
```
> 若不强制这些域名走节点，L3 会把你"本该走代理"的请求也一起挡掉（因为 Clash 判 DIRECT 时的出口 IP 也在封锁段内）。

## L2：把 Claude 自己的代理钉死

**Claude Code**（`~/.claude/settings.json` 的 `env`）：
```json
"HTTPS_PROXY": "http://127.0.0.1:7897",
"HTTP_PROXY":  "http://127.0.0.1:7897",
"NO_PROXY":    "localhost,127.0.0.1,::1"
```
> 若你用第三方中转（`ANTHROPIC_BASE_URL`），把中转域名加进 `NO_PROXY` 可让它保持直连。

**Claude Desktop**（托管配置，需 1.44121.1+）：
```bash
open ./claude-desktop-egress-proxy.mobileconfig
# 再到「系统设置 → 通用 → 设备管理」确认安装
```
> 该键为 `egressProxyUrl=http://127.0.0.1:7897`。**如果你的代理端口不是 7897，先用编辑器改这个文件里的端口。**
> 钉死后 Desktop"连不上代理就失败、不回退直连"（原生 fail-closed）。

---

## 自定义

- **代理端口**：`claude-guard.sh`、`claude-desktop-egress-proxy.mobileconfig` 里都写着 `7897`，按需改。
  （也可给守护设 `CLAUDE_GUARD_PORT` 环境变量。）
- **守护参数**（环境变量）：`CLAUDE_GUARD_PORT`、`CLAUDE_GUARD_SAMPLE`、`CLAUDE_GUARD_DEBOUNCE`、
  `CLAUDE_GUARD_GRACE`（启动宽限）、`CLAUDE_GUARD_KILL_NOTIFY_MIN`（通知限流）。
  干跑：`CLAUDE_GUARD_DRYRUN=1 claude-guard.sh`（列出会杀的进程，不真杀）。
- **封锁 IP 段**：见 `claude-lock.pf`，用的是 Anthropic **官方公布的固定段**（`160.79.104.0/21`、`2607:6bc0::/48`）。
  官方地址若变更，请同步更新：https://platform.claude.com/docs/en/api/ip-addresses

---

## 注意事项 / 限制

- macOS 的 pf **不能按进程匹配**，所以按目标 IP 拦；官方段是 Anthropic 专用，已确认不在 Cloudflare。
- 守护会**强杀 Claude 进程**（可能丢失未保存内容），且检测有 ~0.5s 竞态窗口。
- 只覆盖列出的官方域名/IP；第三方中转、Bedrock/Vertex 等其它端点需另行配置。
- `verify.sh --online` 会真实发起对官方真实 IP 的连接（预期被丢包）+ 一次经代理的请求（预期可达）。
- 需要 `sudo`；**改 pf 有把自己网络弄断的风险**，请按 `install.sh` 分步并保留 `uninstall.sh`。

## 文件

```
claude-guard.sh                         进程守护（L4，含系统通知）
com.claude.guard.plist                  守护 LaunchDaemon
claude-lock.pf                          pf 封锁规则（L3）
com.claude.pflock.plist                 pf 开机自启
install.sh / uninstall.sh               安装 / 回滚
verify.sh                               校验（--online 发真实请求）
claude-desktop-egress-proxy.mobileconfig Desktop 代理托管配置（L2）
```

## License

MIT，见 `LICENSE`。按现状提供，无任何担保；请自行审阅后再在你自己的机器上运行。
