#!/bin/bash
# 安装 Claude fail-closed：进程守护 + pf 静态封锁 + pf 开机自启。
# 用法： sudo ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=/usr/local/bin/claude-guard.sh
PLIST=/Library/LaunchDaemons/com.claude.guard.plist
PLIST2=/Library/LaunchDaemons/com.claude.pflock.plist
ANCHOR=/etc/pf.anchors/claude-lock
PF_CONF=/etc/pf.conf

if [ "$(id -u)" != "0" ]; then echo "请用 sudo 运行"; exit 1; fi

echo "[1/4] 安装守护脚本 -> $BIN"
install -m 0755 "$HERE/claude-guard.sh" "$BIN"

echo "[2/4] 安装并加载守护 LaunchDaemon（开机自启）"
install -m 0644 -o root -g wheel "$HERE/com.claude.guard.plist" "$PLIST"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "[3/4] 安装 pf 规则"
install -m 0644 "$HERE/claude-lock.pf" "$ANCHOR"
if ! grep -q 'load anchor "claude-lock"' "$PF_CONF"; then
  printf '\nanchor "claude-lock"\nload anchor "claude-lock" from "%s"\n' "$ANCHOR" >> "$PF_CONF"
fi
pfctl -E -f "$PF_CONF"

echo "[4/4] 安装并加载 pf 自启 LaunchDaemon（补 com.apple.pfctl 的 -e）"
install -m 0644 -o root -g wheel "$HERE/com.claude.pflock.plist" "$PLIST2"
launchctl bootout system "$PLIST2" 2>/dev/null || true
launchctl bootstrap system "$PLIST2"

echo
echo "完成。当前 pf 规则："
pfctl -a claude-lock -s rules 2>/dev/null || true
echo
echo "自检： sudo /usr/local/bin/claude-guard.sh  (dry-run 用 CLAUDE_GUARD_DRYRUN=1)"
