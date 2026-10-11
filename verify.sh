#!/bin/bash
# verify.sh — 校验 Claude fail-closed 各层是否生效。
# 用法：
#   sudo ./verify.sh            # 只做本地/只读检查（不发网络请求）
#   sudo ./verify.sh --online   # 额外发真实请求：直连应被阻断、经代理应可通
set -u
ONLINE=0
[ "${1:-}" = "--online" ] && ONLINE=1
PASS=0; FAIL=0
ok(){   printf "  OK   %s\n" "$*"; PASS=$((PASS+1)); }
no(){   printf "  FAIL %s\n" "$*"; FAIL=$((FAIL+1)); }
warn(){ printf "  WARN %s\n" "$*"; }
hdr(){  printf "\n== %s ==\n" "$*"; }

[ "$(id -u)" = "0" ] || { echo "建议用 sudo 运行（pf/launchd 检查需要）"; }

hdr "L3 pf 防火墙"
if pfctl -s info 2>/dev/null | grep -qi "Status: Enabled"; then ok "pf 已启用"; else no "pf 未启用（sudo pfctl -e）"; fi
if pfctl -a claude-lock -s rules 2>/dev/null | grep -q "anthropic_net"; then ok "claude-lock 规则已加载"; else no "claude-lock 规则未加载"; fi
T=$(pfctl -a claude-lock -t anthropic_net -T show 2>/dev/null | tr -d ' ' | paste -sd, -)
[ -n "$T" ] && ok "封锁表: $T" || no "封锁表为空"

hdr "L4 进程守护"
if launchctl print system/com.claude.guard >/dev/null 2>&1; then ok "LaunchDaemon 已加载"; else no "LaunchDaemon 未加载"; fi
[ -x /usr/local/bin/claude-guard.sh ] && ok "守护脚本存在" || no "守护脚本缺失"
echo "  最近日志:"; tail -n 3 /var/log/claude-guard.log 2>/dev/null | sed 's/^/    /' || echo "    (无)"
echo "  干跑匹配到的 Claude 进程（应只列 Claude，不能误伤）:"
CLAUDE_GUARD_DRYRUN=1 /usr/local/bin/claude-guard.sh 2>/dev/null | sed 's/^/    /'

hdr "本地代理"
if nc -z 127.0.0.1 7897 2>/dev/null; then ok "7897 在监听"; else no "7897 未监听（Clash 没开？）"; fi

hdr "L2 应用配置"
if grep -q "127.0.0.1:7897" "$HOME/.claude/settings.json" 2>/dev/null; then
  ok "Claude Code settings 含代理"
else
  warn "Claude Code settings 未见代理（可能放在 cc-switch 公共配置）"
fi

if [ "$ONLINE" = "1" ]; then
  hdr "在线连通性（直连应断 / 代理应通）"
  if curl --noproxy '*' -k --connect-timeout 3 -sS -o /dev/null https://160.79.104.10/ -H 'Host: api.anthropic.com' 2>/dev/null; then
    no "直连 v4 真实 IP 竟然通了（pf 没生效？）"
  else
    ok "直连 v4 真实 IP 被阻断"
  fi
  if curl -6 --noproxy '*' -k --connect-timeout 3 -sS -o /dev/null "https://[2607:6bc0::10]/" -H 'Host: api.anthropic.com' 2>/dev/null; then
    no "直连 v6 真实 IP 竟然通了"
  else
    ok "直连 v6 真实 IP 被阻断"
  fi
  code=$(curl -x http://127.0.0.1:7897 --connect-timeout 6 -sS -o /dev/null -w '%{http_code}' https://api.anthropic.com 2>/dev/null)
  if [ -n "$code" ] && [ "$code" != "000" ]; then ok "经代理可达（HTTP $code）"; else no "经代理不可达"; fi
else
  echo
  echo "（未加 --online，跳过真实请求测试）"
fi

hdr "L1 Clash 规则"
echo "  在 Clash Verge 的“连接”面板发一次 Claude 请求，确认命中 DOMAIN-SUFFIX,anthropic.com 且走节点。"
echo "  或者：curl \"http://127.0.0.1:9097/rules?secret=<secret>\" | grep -i anthropic"

echo
echo "结果: $PASS 通过, $FAIL 失败"
