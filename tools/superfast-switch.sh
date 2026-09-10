#!/usr/bin/env bash
# superfast-switch — activate one model profile on the SUPERFAST machine.
#
# Only one profile runs at a time and serves an OpenAI-compatible API on
# port 8731, so clients (and AgentBridge) never change their configuration
# when you switch model. Switching stops the previous profile first, which
# releases its memory before the next model loads.
#
# Profiles can run on any runtime (halogen engine containers or llama.cpp
# servers); readiness is detected by HTTP 200 on /health.
#
# Usage:
#   superfast-switch status
#   superfast-switch list
#   superfast-switch use dense|flash|gemma|deepseek
#   superfast-switch stop
set -euo pipefail

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
PORT="${SUPERFAST_PORT:-8731}"
HEALTH="http://127.0.0.1:${PORT}/health"
FLASH_DIR="${SUPERFAST_FLASH_DIR:-$HOME/superfast-flash}"
GEMMA_DIR="${SUPERFAST_GEMMA_DIR:-$HOME/gemma-models}"
DEEPSEEK_DIR="${SUPERFAST_DEEPSEEK_DIR:-$HOME/deepseek-models}"

declare -A UNIT=(
    [dense]="${SUPERFAST_DENSE_UNIT:-superfast.service}"
    [flash]="${SUPERFAST_FLASH_UNIT:-superfast-flash.service}"
    [gemma]="${SUPERFAST_GEMMA_UNIT:-gemma.service}"
    [deepseek]="${SUPERFAST_DEEPSEEK_UNIT:-deepseek.service}"
)
declare -A LABEL=(
    [dense]="Qwen3.8-27B dense (halogen)"
    [flash]="Qwen3.8-Flash-Next MoE (halogen-flash)"
    [gemma]="Gemma-4-26B-A4B ROCmFP4 (llama-rocmfpx)"
    [deepseek]="DeepSeek-V4-Flash ROCmFPX (llama-rocmfpx)"
)
PROFILES=(dense flash gemma deepseek)

# The orchestrator is a small, fast model that runs ALONGSIDE a profile (it is
# not a profile itself): clients may ask it to decide what to do, and it wakes
# the big model only when needed. Toggle it with `orchestrator on|off`.
ORCH_UNIT="${SUPERFAST_ORCH_UNIT:-orchestrator.service}"
ORCH_DIR="${SUPERFAST_ORCH_DIR:-$HOME/small-models}"
ORCH_PORT="${SUPERFAST_ORCH_PORT:-8732}"
ORCH_HEALTH="http://127.0.0.1:${ORCH_PORT}/health"

http_ok() {
    curl -s -o /dev/null --max-time 5 "$HEALTH" 2>/dev/null
}

model_name() {
    # Best effort: halogen /health has "model"; llama.cpp exposes /v1/models.
    local m
    m="$(curl -s --max-time 5 "$HEALTH" 2>/dev/null \
        | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$m" ] && { echo "$m"; return; }
    m="$(curl -s --max-time 5 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    echo "$m"
}

unit_state() {
    local s
    s="$(systemctl --user is-active "$1" 2>/dev/null | head -n 1)"
    echo "${s:-inactive}"
}

unit_active() {
    [ "$(unit_state "$1")" = "active" ]
}

weights_ready() {
    case "$1" in
        dense) return 0 ;;
        flash)
            [ -f "$FLASH_DIR/qwen38-flash-next-w4b.hgn" ] \
                && [ -f "$FLASH_DIR/.download-complete" ] ;;
        gemma)
            [ -f "$GEMMA_DIR/.download-complete" ] ;;
        deepseek)
            [ -f "$DEEPSEEK_DIR/.download-complete" ] \
                && [ -f "$DEEPSEEK_DIR/.deepseek-enabled" ] ;;
    esac
}

cmd_status() {
    echo "profiles (API on 127.0.0.1:${PORT}, one at a time):"
    for p in "${PROFILES[@]}"; do
        st="$(unit_state "${UNIT[$p]}")"
        mark=""; [ "$st" = "active" ] && mark="   <== ACTIVE"
        printf '  %-9s %-28s %s%s\n' "$p" "${UNIT[$p]}" "$st" "$mark"
    done
    ost="$(unit_state "$ORCH_UNIT")"
    printf '  %-9s %-28s %s (port %s)\n' "orchestr." "$ORCH_UNIT" "$ost" "$ORCH_PORT"
    m="$(model_name)"
    if [ -n "$m" ]; then
        echo "serving now: $m"
    else
        echo "no model responding on :${PORT}"
    fi
}

orch_ready() {
    [ -f "$ORCH_DIR/.download-complete" ] || [ -f "$ORCH_DIR"/*.gguf ]
}

cmd_orchestrator() {
    local action="${1:-status}"
    case "$action" in
        on)
            if systemctl --user list-unit-files "$ORCH_UNIT" >/dev/null 2>&1 && \
               ! systemctl --user cat "$ORCH_UNIT" >/dev/null 2>&1; then
                echo "orchestrator unit '$ORCH_UNIT' not installed yet" >&2
                return 1
            fi
            if ! orch_ready; then
                echo "orchestrator weights not present in $ORCH_DIR yet" >&2
                return 3
            fi
            systemctl --user start "$ORCH_UNIT"
            for i in $(seq 1 60); do
                if curl -s -o /dev/null --max-time 3 "$ORCH_HEALTH"; then
                    echo "orchestrator active on :${ORCH_PORT} (after ~$((i * 5))s)"
                    return 0
                fi
                sleep 5
            done
            echo "orchestrator started but /health not answering on :${ORCH_PORT}" >&2
            return 1
            ;;
        off)
            systemctl --user stop "$ORCH_UNIT" 2>/dev/null || true
            echo "orchestrator off"
            ;;
        status)
            echo "orchestrator: $(unit_state "$ORCH_UNIT") (unit $ORCH_UNIT, port $ORCH_PORT, weights $ORCH_DIR)"
            ;;
        *)
            echo "usage: $0 orchestrator on|off|status" >&2
            exit 2
            ;;
    esac
}

cmd_use() {
    local p="$1"
    [ -n "${UNIT[$p]:-}" ] || { echo "unknown profile '$p'" >&2; exit 2; }
    if ! weights_ready "$p"; then
        echo "profile '$p': not ready on this machine yet (weights missing or the profile is disabled)." >&2
        exit 3
    fi
    for q in "${PROFILES[@]}"; do
        if [ "$q" != "$p" ] && unit_active "${UNIT[$q]}"; then
            echo "stopping ${UNIT[$q]} (${LABEL[$q]})"
            systemctl --user stop "${UNIT[$q]}"
        fi
    done
    if ! unit_active "${UNIT[$p]}"; then
        echo "starting ${UNIT[$p]} (${LABEL[$p]})"
        systemctl --user start "${UNIT[$p]}"
    fi
    # Cold loads can take minutes for the big checkpoints.
    for i in $(seq 1 120); do
        if http_ok; then
            m="$(model_name)"
            [ -n "$m" ] && m=" ($m)"
            echo "profile '$p' serving on :${PORT}${m} (after ~$((i * 5))s)"
            return 0
        fi
        sleep 5
    done
    echo "profile '$p' did not become healthy in time" >&2
    return 1
}

cmd_stop() {
    for q in "${PROFILES[@]}"; do
        if unit_active "${UNIT[$q]}"; then
            systemctl --user stop "${UNIT[$q]}"
            echo "stopped ${UNIT[$q]}"
        fi
    done
    echo "no model running"
}

case "${1:-}" in
    status) cmd_status ;;
    list)   echo "profiles: ${PROFILES[*]}"; echo "auxiliary: orchestrator (on|off|status)" ;;
    use)    [ $# -ge 2 ] && cmd_use "$2" || { echo "usage: $0 use <${PROFILES[*]}>" >&2; exit 2; } ;;
    orchestrator|orch) cmd_orchestrator "${2:-status}" ;;
    stop)   cmd_stop ;;
    *) echo "usage: $0 {status|list|use <${PROFILES[*]}>|orchestrator on|off|status|stop}" >&2; exit 2 ;;
esac
