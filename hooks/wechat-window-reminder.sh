#!/usr/bin/env bash
# wechat-window-reminder: watch the WeChat ClawBot 24 h reply window.
# Stage A (remaining <= 240 min, window open): send ONE proactive nudge
#   into WeChat itself via ops/send-direct.py (deterministic, no agent).
# Stage B (remaining <= 60 min or closed): wake an agent to remind the
#   owner in the Muse App, at most once per 20 h for the same window.
# Any new inbound WeChat message starts a fresh window and re-arms both.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

BRIDGE_DIR="$HOME/workspace/wechat-bridge"
CREDS="$BRIDGE_DIR/state/credentials.json"

if [[ ! -f "$CREDS" ]]; then
  silent "no wechat credentials" '{}'
fi

status_json="$(cd "$BRIDGE_DIR" && python3 wb status 2>/dev/null)" || status_json=""
if [[ -z "$status_json" ]]; then
  silent "bridge status unavailable" '{}'
fi

read -r open remaining_min last_inbound < <(printf '%s' "$status_json" | jq -r '
  [(.reply_window.open // false), (.reply_window.remaining_min // 0), (.reply_window.last_inbound_at // 0)] | @tsv') || true

if [[ -z "${last_inbound:-}" || "$last_inbound" == "0" ]]; then
  silent "no inbound wechat message yet" '{}'
fi

now_ms="$(( $(date +%s) * 1000 ))"
state="$(hook_state_get)"
printf '%s' "$state" | jq -e 'type == "object"' >/dev/null 2>&1 || state='{}'
nudged_for="$(printf '%s' "$state" | jq -r '.nudged_for_inbound // 0')"
reminded_for="$(printf '%s' "$state" | jq -r '.reminded_for_inbound // 0')"
last_reminder_ms="$(printf '%s' "$state" | jq -r '.last_reminder_ms // 0')"

# Window comfortably open (> 4 h left): stay silent; once a NEW inbound has
# arrived, clear both markers so the next window starts fresh.
if [[ "$open" == "true" && "$remaining_min" -gt 240 ]]; then
  if [[ "$nudged_for" != "0" && "$nudged_for" != "$last_inbound" ]]; then
    if [[ "$HATCH_HOOK_DRY_RUN" != "1" ]]; then
      hook_state_set "$(printf '%s' "$state" | jq -c '.nudged_for_inbound = 0 | .reminded_for_inbound = 0 | .last_reminder_ms = 0')"
    fi
  fi
  silent "reply window open" "{\"remaining_min\": $remaining_min}"
fi

# Stage A: <= 4 h left and window still open -> one WeChat-side nudge.
if [[ "$open" == "true" && "$remaining_min" -le 240 && "$remaining_min" -gt 60 ]]; then
  if [[ "$nudged_for" == "$last_inbound" ]]; then
    silent "wechat nudge already sent for this window" '{}'
  fi
  hours_left="$(( (remaining_min + 59) / 60 ))"
  if [[ "$HATCH_HOOK_DRY_RUN" == "1" ]]; then
    silent "dry run: would send wechat nudge" "{\"remaining_min\": $remaining_min}"
  fi
  nudge_out="$(cd "$BRIDGE_DIR" && python3 ops/send-direct.py --message "提醒一句：咱这个微信窗口还剩大约 ${hours_left} 小时就满 24 小时了。你回我任意一条消息（比如「1」）就能重新续满；不然窗口一关，我就没法主动在微信里给你发消息了。" 2>/dev/null)" || nudge_out=""
  nudge_ok="$(printf '%s' "$nudge_out" | jq -r '.ok // false' 2>/dev/null)" || nudge_ok="false"
  if [[ "$nudge_ok" == "true" ]]; then
    hook_state_set "$(printf '%s' "$state" | jq -c --argjson li "$last_inbound" '.nudged_for_inbound = $li')"
    log "wechat window nudge sent" "{\"remaining_min\": $remaining_min}"
    silent "wechat nudge sent" "{\"remaining_min\": $remaining_min}"
  fi
  log "wechat window nudge failed" "{\"remaining_min\": $remaining_min}"
  silent "wechat nudge failed; app reminder still armed" "{\"remaining_min\": $remaining_min}"
fi

# Stage B: <= 60 min left or window closed -> App-side reminder via agent,
# at most once per 20 h for this same last-inbound message.
if [[ "$reminded_for" == "$last_inbound" ]] && (( now_ms - last_reminder_ms < 72000000 )); then
  silent "already reminded for this window" '{}'
fi

if [[ "$HATCH_HOOK_DRY_RUN" != "1" ]]; then
  hook_state_set "$(printf '%s' "$state" | jq -c --argjson li "$last_inbound" --argjson t "$now_ms" '.reminded_for_inbound = $li | .last_reminder_ms = $t')"
fi
age_hours="$(( (now_ms - last_inbound) / 3600000 ))"
log "wechat reply window reminder" "{\"remaining_min\": $remaining_min, \"open\": $open, \"age_hours\": $age_hours}"
wake "wechat_window_reminder" "{\"remaining_min\": $remaining_min, \"open\": $open, \"age_hours\": $age_hours}"
