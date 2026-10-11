#!/bin/bash
# claude-guard.sh — 当 Clash Verge / mihomo 代理消失时，强制关闭所有 Claude 系列进程，并发 macOS 通知。
# 以 root 通过 LaunchDaemon 运行。轮询检测，带去抖，检测延迟约 0.5s。
#
# 环境变量（可选）：
#   CLAUDE_GUARD_PORT            混合代理端口，默认 7897
#   CLAUDE_GUARD_SAMPLE          轮询间隔(秒)，默认 0.25
#   CLAUDE_GUARD_DEBOUNCE        连续多少次“代理不在”才动手，默认 2
#   CLAUDE_GUARD_GRACE           启动宽限(秒)，默认 0
#   CLAUDE_GUARD_KILL_NOTIFY_MIN 杀进程通知的最小间隔(秒)，默认 20
#   CLAUDE_GUARD_DRYRUN=1        只打印会被杀的目标，不真的杀

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROXY_PORT="${CLAUDE_GUARD_PORT:-7897}"
VERGE_GUI="${CLAUDE_GUARD_VERGE_GUI:-Clash Verge.app/Contents/MacOS/clash-verge}"
VERGE_CORE="${CLAUDE_GUARD_VERGE_CORE:-verge-mihomo}"
SAMPLE="${CLAUDE_GUARD_SAMPLE:-0.25}"
DEBOUNCE="${CLAUDE_GUARD_DEBOUNCE:-2}"
GRACE="${CLAUDE_GUARD_GRACE:-0}"
KILL_NOTIFY_MIN="${CLAUDE_GUARD_KILL_NOTIFY_MIN:-20}"
DRYRUN="${CLAUDE_GUARD_DRYRUN:-0}"
LOG="/var/log/claude-guard.log"

PATTERNS=(
  '/Applications/Claude.app/Contents/'     # Claude Desktop 主程序 + Helper
  '/\.local/bin/claude'                     # Claude Code CLI（native 安装）
  '/\.claude/local/claude'                  # Claude Code CLI（另一个安装位置）
  '/\.claude/versions/'                     # 版本目录里的二进制
)

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true; }

# 以“当前登录的 GUI 用户”身份发系统通知（root 直接发不会显示）
notify() {
  local title="$1" msg="$2" sound="${3:-}" user uid
  user="$(stat -f%Su /dev/console 2>/dev/null)"
  case "$user" in ""|root) return 0 ;; esac
  uid="$(id -u "$user" 2>/dev/null)" || return 0
  if [ -n "$sound" ]; then
    launchctl asuser "$uid" osascript -e "display notification \"$msg\" with title \"$title\" sound name \"$sound\"" >/dev/null 2>&1 || true
  else
    launchctl asuser "$uid" osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
  fi
}

proxy_up() {
  pgrep -f "$VERGE_GUI"  >/dev/null 2>&1 && return 0
  pgrep -f "$VERGE_CORE" >/dev/null 2>&1 && return 0
  lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  return 1
}

list_targets() {
  local p
  for p in "${PATTERNS[@]}"; do
    pgrep -f "$p" 2>/dev/null
  done | sort -u
}

kill_targets() {
  local p
  for p in "${PATTERNS[@]}"; do pkill -TERM -f "$p" 2>/dev/null; done
  sleep 1
  for p in "${PATTERNS[@]}"; do pkill -KILL -f "$p" 2>/dev/null; done
}

if [ "$DRYRUN" = "1" ]; then
  echo "会匹配到的 Claude 进程："
  list_targets
  echo "--- 代理现在是否在线 ---"
  proxy_up && echo "online" || echo "offline"
  exit 0
fi

if [ "$GRACE" -gt 0 ]; then sleep "$GRACE"; fi

log "start (port=$PROXY_PORT sample=${SAMPLE}s debounce=$DEBOUNCE grace=${GRACE}s)"
notify "Claude 守护" "守护已启动，代理状态监控中"

down=0
was_down=0
last_kill_notify=0
while :; do
  if proxy_up; then
    if [ "$was_down" = "1" ]; then
      log "proxy back up"
      notify "Claude 守护" "代理已恢复，Claude 可正常使用"
      was_down=0
    fi
    down=0
  else
    down=$((down + 1))
    if [ "$down" -ge "$DEBOUNCE" ]; then
      was_down=1
      targets="$(list_targets)"
      if [ -n "$targets" ]; then
        n="$(echo "$targets" | wc -l | tr -d ' ')"
        log "proxy gone -> kill Claude PIDs: $(echo $targets | tr '\n' ' ')"
        kill_targets
        now="$(date +%s)"
        if [ $((now - last_kill_notify)) -ge "$KILL_NOTIFY_MIN" ]; then
          notify "Claude 守护 ⚠️" "代理已断开，已强制关闭 ${n} 个 Claude 进程" "Basso"
          last_kill_notify="$now"
        fi
      fi
      down=0
    fi
  fi
  sleep "$SAMPLE"
done
