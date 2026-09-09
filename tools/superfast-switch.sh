#!/usr/bin/env bash
# superfast-switch — activate one model profile on the SUPERFAST machine.
#
# Only one profile runs at a time and serves the OpenAI-compatible API on
# port 8731, so clients (and AgentBridge) never change their configuration
# when you switch model. Switching stops the previous profile first, which
# releases its memory before the next model loads.
#
# Usage:
#   superfast-switch status
#   superfast-switch list
#   superfast-switch use dense|flash
#   superfast-switch stop
set -euo pipefail

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
PORT="${SUPERFAST_PORT:-8731}"
HEALTH="http://127.0.0.1:${PORT}/health"
FLASH_DIR="${SUPERFAST_FLASH_DIR:-$HOME/superfast-flash}"
FLASH_CKPT="$FLASH_DIR/qwen38-flash-next-w4b.hgn"
FLASH_MARKER="$FLASH_DIR/.download-complete"

declare -A UNIT=(
    [dense]="${SUPERFAST_DENSE_UNIT:-superfast.service}"
    [flash]="${SUPERFAST_FLASH_UNIT:-superfast-flash.service}"
)
declare -A LABEL=(
    [dense]="Qwen3.8-27B dense (halogen)"
    [flash]="Qwen3.8-Flash-Next MoE (halogen-flash)"
)

health_model() {
    curl -s --max-time 5 "$HEALTH" 2>/dev/null \
        | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

unit_active() {
    [ "$(systemctl --user is-active "$1" 2>/dev/null)" = "active" ]
}

cmd_status() {
    echo "profiles (API on 127.0.0.1:8731, one at a time):"
    for p in dense flash; do
        st="$(systemctl --user is-active "${UNIT[$p]}" 2>/dev/null || echo inactive)"
        mark=""; [ "$st" = "active" ] && mark="   <== ACTIVE"
        printf '  %-6s %-28s %s%s\n' "$p" "${UNIT[$p]}" "$st" "$mark"
    done
    m="$(health_model)"
    if [ -n "$m" ]; then
        echo "serving now: $m"
    else
        echo "no model responding on :8731"
    fi
}

cmd_use() {
    local p="$1"
    [ -n "${UNIT[$p]:-}" ] || { echo "unknown profile '$p' (use: dense|flash)" >&2; exit 2; }
    if [ "$p" = "flash" ] && { [ ! -f "$FLASH_CKPT" ] || [ ! -f "$FLASH_MARKER" ]; }; then
        echo "flash profile: weights not complete yet ($FLASH_DIR). Aborting." >&2
        exit 3
    fi
    for q in dense flash; do
        if [ "$q" != "$p" ] && unit_active "${UNIT[$q]}"; then
            echo "stopping ${UNIT[$q]} (${LABEL[$q]})"
            systemctl --user stop "${UNIT[$q]}"
        fi
    done
    if ! unit_active "${UNIT[$p]}"; then
        echo "starting ${UNIT[$p]} (${LABEL[$p]})"
        systemctl --user start "${UNIT[$p]}"
    fi
    # Cold load of the flash checkpoint can take minutes.
    local tries=60
    [ "$p" = "flash" ] && tries=90
    for i in $(seq 1 "$tries"); do
        m="$(health_model)"
        [ -n "$m" ] && { echo "profile '$p' serving: $m (after ~$((i * 5))s)"; return 0; }
        sleep 5
    done
    echo "profile '$p' did not become healthy in time" >&2
    return 1
}

cmd_stop() {
    for q in dense flash; do
        if unit_active "${UNIT[$q]}"; then
            systemctl --user stop "${UNIT[$q]}"
            echo "stopped ${UNIT[$q]}"
        fi
    done
    echo "no model running"
}

case "${1:-}" in
    status) cmd_status ;;
    list)   echo "profiles: dense flash" ;;
    use)    [ $# -ge 2 ] && cmd_use "$2" || { echo "usage: $0 use <dense|flash>" >&2; exit 2; } ;;
    stop)   cmd_stop ;;
    *) echo "usage: $0 {status|list|use <dense|flash>|stop}" >&2; exit 2 ;;
esac
