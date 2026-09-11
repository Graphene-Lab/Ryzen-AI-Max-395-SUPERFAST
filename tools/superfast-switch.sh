#!/usr/bin/env bash
# superfast-switch — activate one model profile on the SUPERFAST machine.
#
# Only one profile runs at a time and serves an OpenAI-compatible API on
# port 8731, so clients (and AgentBridge) never change their configuration
# when you switch model. Switching stops the previous profile first, which
# releases its memory before the next model loads. The profile you activate is
# also the one that starts at boot: `use` enables it and disables the other
# profile units, which the setup script installs disabled.
#
# Profiles can run on any runtime (halogen engine containers or llama.cpp
# servers); readiness is detected by HTTP 200 on /health.
#
# Usage:
#   superfast-switch status
#   superfast-switch list
#   superfast-switch use dense|flash|gemma|deepseek
#   superfast-switch stop
#   superfast-switch api-key status|on|off|show|set [key]|clear
#
# The API key is enforced by the gateway (superfast-gateway.service) on :8741.
# Every profile binds :8731 to loopback, so the gateway is the ONLY way in from
# the network: `api-key on` means "reachable from the LAN, key required" and
# `api-key off` means "no remote access at all" (loopback on the host still
# works, no key needed there).
set -euo pipefail

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
PORT="${SUPERFAST_PORT:-8731}"
HEALTH="http://127.0.0.1:${PORT}/health"
FLASH_DIR="${SUPERFAST_FLASH_DIR:-$HOME/superfast-flash}"
GEMMA_DIR="${SUPERFAST_GEMMA_DIR:-$HOME/gemma-models}"
DEEPSEEK_DIR="${SUPERFAST_DEEPSEEK_DIR:-$HOME/deepseek-models}"
API_KEY_FILE="${SUPERFAST_KEY_FILE:-$HOME/.config/superfast/api.key}"
GATEWAY_UNIT="${SUPERFAST_GATEWAY_UNIT:-superfast-gateway.service}"
GATEWAY_PORT="${SUPERFAST_GATEWAY_PORT:-8741}"

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
    # A reply is not enough: a llama.cpp profile binds its port immediately and
    # answers 503 "Loading model" until the weights are in memory, so require
    # HTTP 200. Without this the switch announces a profile that is not ready
    # yet (measured: gemma reported "serving" after 10 s and answered 503).
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH" 2>/dev/null)" = "200" ]
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

# The DeepSeek profile needs both shared-memory kernel parameters. Without
# them llama.cpp cannot allocate the model and stops with "cudaMalloc failed:
# out of memory" (see the README). The marker file is an escape hatch for a
# machine where those limits are raised some other way.
deepseek_memory_ok() {
    if grep -q 'amdgpu.gttsize=' /proc/cmdline 2>/dev/null \
       && grep -q 'ttm.pages_limit=' /proc/cmdline 2>/dev/null; then
        return 0
    fi
    [ -f "$DEEPSEEK_DIR/.deepseek-enabled" ]
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
            [ -f "$DEEPSEEK_DIR/.download-complete" ] && deepseek_memory_ok ;;
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
    if [ -s "$API_KEY_FILE" ]; then k="set"; else k="not set"; fi
    echo "api key: $k, gateway $(unit_state "$GATEWAY_UNIT") (port ${GATEWAY_PORT}, the only LAN path)"
}

# Turn the LAN-facing API key on or off, and manage the key itself. `on` keeps
# an existing key and only starts the gateway, so a running client is not
# invalidated; `set` writes a given key (or a fresh one when none is given) and
# turns the gateway on; `clear` removes the key and stops the gateway.
cmd_apikey() {
    local action="${1:-status}"
    case "$action" in
        status)
            if [ -s "$API_KEY_FILE" ]; then
                echo "api key: set ($API_KEY_FILE)"
            else
                echo "api key: not set"
            fi
            echo "gateway: $(unit_state "$GATEWAY_UNIT") on :${GATEWAY_PORT} (the only LAN path)"
            ;;
        show)
            [ -s "$API_KEY_FILE" ] || { echo "no api key set (run: superfast-switch api-key set)" >&2; return 3; }
            cat "$API_KEY_FILE"; echo
            ;;
        on)
            if [ -s "$API_KEY_FILE" ]; then
                systemctl --user enable --now "$GATEWAY_UNIT" 2>/dev/null || {
                    echo "could not start $GATEWAY_UNIT; create it with deploy/setup-fedora.sh" >&2
                    return 1; }
                echo "api key on :${GATEWAY_PORT} (key unchanged: $(cat "$API_KEY_FILE"))"
            else
                cmd_apikey set ""
            fi
            ;;
        set)
            local k="${2:-}"
            if [ -z "$k" ]; then
                # 32 chars drawn from 48 random bytes: a longer source avoids
                # the short key that tr -dc '/+=' alone could leave behind.
                k="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
            fi
            mkdir -p "$(dirname "$API_KEY_FILE")"
            printf '%s' "$k" > "$API_KEY_FILE"
            chmod 600 "$API_KEY_FILE"
            systemctl --user enable --now "$GATEWAY_UNIT" 2>/dev/null || {
                echo "key saved to $API_KEY_FILE, but $GATEWAY_UNIT could not be started;" >&2
                echo "create it with deploy/setup-fedora.sh, then: superfast-switch api-key on" >&2
                return 1; }
            echo "$k"
            echo "api key on :${GATEWAY_PORT}; clients send: Authorization: Bearer <key>" >&2
            ;;
        off)
            systemctl --user stop "$GATEWAY_UNIT" 2>/dev/null || true
            echo "api key off: gateway stopped, no access from the LAN (loopback on the host still works)"
            ;;
        clear)
            rm -f "$API_KEY_FILE"
            systemctl --user disable --now "$GATEWAY_UNIT" 2>/dev/null || true
            echo "api key cleared: key removed and gateway stopped"
            ;;
        *)
            echo "usage: $0 api-key status|on|off|show|set [key]|clear" >&2
            exit 2
            ;;
    esac
}

orch_ready() {
    [ -f "$ORCH_DIR/.download-complete" ] && return 0
    # Do not write this as [ -f "$ORCH_DIR"/*.gguf ]: the glob expands into
    # more arguments when the directory holds two files, and the test then
    # fails with "binary operator expected". compgen -G is safe.
    compgen -G "$ORCH_DIR/*.gguf" >/dev/null 2>&1
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
                # Same as http_ok: the small model also serves llama.cpp, which
                # answers 503 while loading.
                if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ORCH_HEALTH" 2>/dev/null)" = "200" ]; then
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
        echo "profile '$p': not ready on this machine yet." >&2
        if [ "$p" = "deepseek" ] && [ -f "$DEEPSEEK_DIR/.download-complete" ]; then
            echo "  Its weights are complete, but the shared-memory kernel parameters are not set," >&2
            echo "  so llama.cpp cannot allocate the model. As root, then reboot:" >&2
            echo "    grubby --update-kernel=ALL --args=\"amdgpu.gttsize=118784 ttm.pages_limit=31457280\"" >&2
            echo "  (or create $DEEPSEEK_DIR/.deepseek-enabled to skip this check)" >&2
        else
            echo "  Its weights are missing or still downloading; see the log in its directory." >&2
        fi
        exit 3
    fi
    for q in "${PROFILES[@]}"; do
        if [ "$q" != "$p" ] && unit_active "${UNIT[$q]}"; then
            echo "stopping ${UNIT[$q]} (${LABEL[$q]})"
            systemctl --user stop "${UNIT[$q]}"
        fi
    done
    # The setup script enables the dense unit and installs every other profile
    # disabled, so the enabled unit is what starts at boot. Picking a profile
    # here is what has to decide that: enable it and disable its siblings, or a
    # reboot comes up on the previous model — or, with two enabled, on whichever
    # one wins the race for port 8731.
    for q in "${PROFILES[@]}"; do
        [ "$q" = "$p" ] && continue
        systemctl --user disable "${UNIT[$q]}" >/dev/null 2>&1 || true
    done
    systemctl --user enable "${UNIT[$p]}" >/dev/null 2>&1 || true
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
    use)
        if [ $# -ge 2 ]; then
            cmd_use "$2"
        else
            echo "usage: $0 use <${PROFILES[*]}>" >&2
            exit 2
        fi
        ;;
    orchestrator|orch) cmd_orchestrator "${2:-status}" ;;
    api-key|apikey) cmd_apikey "${2:-status}" "${3:-}" ;;
    stop)   cmd_stop ;;
    *) echo "usage: $0 {status|list|use <${PROFILES[*]}>|orchestrator on|off|status|api-key status|on|off|show|set|clear|stop}" >&2; exit 2 ;;
esac
