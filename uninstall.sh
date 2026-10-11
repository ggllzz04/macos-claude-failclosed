#!/bin/bash
# 卸载 Claude fail-closed：移除守护、pf 自启、pf 规则。
# 用法： sudo ./uninstall.sh
set -uo pipefail

PLIST=/Library/LaunchDaemons/com.claude.guard.plist
PLIST2=/Library/LaunchDaemons/com.claude.pflock.plist
PF_CONF=/etc/pf.conf

if [ "$(id -u)" != "0" ]; then echo "请用 sudo 运行"; exit 1; fi

echo "[1/4] 停止并删除守护 LaunchDaemon"
launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST" /usr/local/bin/claude-guard.sh

echo "[2/4] 删除 pf 自启 LaunchDaemon"
launchctl bootout system "$PLIST2" 2>/dev/null || true
rm -f "$PLIST2"

echo "[3/4] 清空并删除 pf anchor"
pfctl -a claude-lock -F rules 2>/dev/null || true
rm -f /etc/pf.anchors/claude-lock

echo "[4/4] 从 /etc/pf.conf 删除 claude-lock 行"
if grep -q 'claude-lock' "$PF_CONF"; then
  sed -i '' '/claude-lock/d' "$PF_CONF"
  pfctl -f "$PF_CONF" 2>/dev/null || true
fi

echo "已卸载。"
