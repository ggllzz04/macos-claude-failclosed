#!/bin/bash
# claude-guard.sh — 代理"不可用"时强制关闭所有 Claude 进程，并发 macOS 通知。
# 以 root 通过 LaunchDaemon 运行。轮询检测，带去抖，检测延迟约 0.5s。
#
# "不可用"的判定（可组合，用环境变量开关）：
#   1) 核心进程 / 端口不在（Clash 进程或守护崩了）—— 总是检查
#   2) TUN 模式关闭（Clash 还活着，但 TUN 被关）
#   3) 系统代理关闭 / 不指向本代理（Clash 还活着，但系统代理被关）
#
# 环境变量：
#   CLAUDE_GUARD_PORT              代理端口，默认 7897
#   CLAUDE_GUARD_PROXY_HOST        代理主机，默认 127.0.0.1
#   CLAUDE_GUARD_REQUIRE_TUN       1=要求 TUN 必须在，否则视为不可用（默认 0）
#   CLAUDE_GUARD_TUN_GW            TUN/fake-ip 网关地址，默认 198.18.0.1
#   CLAUDE_GUARD_REQUIRE_SYSPROXY  1=要求系统代理必须指向本代理（默认 0）
#   CLAUDE_GUARD_SAMPLE            轮询间隔(秒)，默认 0.25
#   CLAUDE_GUARD_DEBOUNCE          连续多少次"不可用"才动手，默认 2
#   CLAUDE_GUARD_GRACE             启动宽限(秒)，默认 0
#   CLAUDE_GUARD_KILL_NOTIFY_MIN   杀进程通知最小间隔(秒)，默认 20
#   CLAUDE_GUARD_DRYRUN=1          只打印状态，不真的杀

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROXY_PORT="${CLAUDE_GUARD_PORT:-7897}"
PROXY_HOST="${CLAUDE_GUARD_PROXY_HOST:-127.0.0.1}"
VERGE_GUI="${CLAUDE_GUARD_VERGE_GUI:-Clash Verge.app/Contents/MacOS/clash-verge}"
VERGE_CORE="${CLAUDE_GUARD_VERGE_CORE:-verge-mihomo}"
TUN_GW="${CLAUDE_GUARD_TUN_GW:-198.18.0.1}"
REQUIRE_TUN="${CLAUDE_GUARD_REQUIRE_TUN:-0}"
REQUIRE_SYSPROXY="${CLAUDE_GUARD_REQUIRE_SYSPROXY:-0}"
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

# 1) 核心进程 / 端口是否在
core_up() {
  pgrep -f "$VERGE_GUI"  >/dev/null 2>&1 && return 0
  pgrep -f "$VERGE_CORE" >/dev/null 2>&1 && return 0
  lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  return 1
}

# 2) 系统代理是否指向本代理
sysproxy_ok() {
  local p
  p="$(scutil --proxy 2>/dev/null)" || return 1
  printf '%s' "$p" | grep -q "HTTPSEnable : 1" || return 1
  printf '%s' "$p" | grep -q "HTTPSProxy : $PROXY_HOST" || return 1
  printf '%s' "$p" | grep -q "HTTPSPort : $PROXY_PORT" || return 1
}

# 3) TUN 是否在（存在带 fake-ip 网关地址的接口）
tun_ok() {
  ifconfig 2>/dev/null | grep -Eq "[[:space:]]inet[[:space:]]+${TUN_GW}([[:space:]]|-->)"
}

# 健康则 return 0；不健康则把原因打到 stdout 并 return 1
health_reason() {
  core_up || { echo "核心/端口不在"; return 1; }
  if [ "$REQUIRE_TUN" = "1" ] && ! tun_ok; then echo "TUN 已关闭"; return 1; fi
  if [ "$REQUIRE_SYSPROXY" = "1" ] && ! sysproxy_ok; then echo "系统代理已关闭"; return 1; fi
  return 0
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
  echo "会匹配到的 Claude 进程："; list_targets
  echo "--- 状态 ---"
  core_up && echo "core_up: yes" || echo "core_up: no"
  tun_ok && echo "tun_ok: yes" || echo "tun_ok: no"
  sysproxy_ok && echo "sysproxy_ok: yes" || echo "sysproxy_ok: no"
  echo "require_tun=$REQUIRE_TUN require_sysproxy=$REQUIRE_SYSPROXY"
  if r="$(health_reason)"; then echo "健康: YES"; else echo "健康: NO ($r)"; fi
  exit 0
fi

if [ "$GRACE" -gt 0 ]; then sleep "$GRACE"; fi

log "start (port=$PROXY_PORT req_tun=$REQUIRE_TUN req_sysproxy=$REQUIRE_SYSPROXY sample=${SAMPLE}s debounce=$DEBOUNCE grace=${GRACE}s)"
notify "Claude 守护" "守护已启动，代理状态监控中"

down=0
was_down=0
last_kill_notify=0
while :; do
  if reason="$(health_reason)"; then
    if [ "$was_down" = "1" ]; then
      log "proxy healthy again"
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
        log "proxy unhealthy ($reason) -> kill Claude PIDs: $(echo $targets | tr '\n' ' ')"
        kill_targets
        now="$(date +%s)"
        if [ $((now - last_kill_notify)) -ge "$KILL_NOTIFY_MIN" ]; then
          notify "Claude 守护 ⚠️" "代理不可用（$reason），已强制关闭 ${n} 个 Claude 进程" "Basso"
          last_kill_notify="$now"
        fi
      fi
      down=0
    fi
  fi
  sleep "$SAMPLE"
done
