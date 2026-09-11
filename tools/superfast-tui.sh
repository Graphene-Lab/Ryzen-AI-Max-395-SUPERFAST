#!/usr/bin/env bash
# superfast-tui — tiny terminal UI and simple commands to manage the local
# LLM profiles from the machine itself or over SSH.
#
# Usage (non-interactive):
#   superfast-tui status              show profiles + orchestrator state
#   superfast-tui use <profile>       activate a profile
#   superfast-tui orchestrator on|off turn the small router on/off
#   superfast-tui api-key on|off|show|set|clear
#   superfast-tui ports               show the ports in use
#   superfast-tui help                this help
#
# With no arguments it opens a minimal menu.
set -euo pipefail

# systemctl --user needs the session runtime directory; over SSH it is not
# always set, and the gateway commands below talk to the user manager.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SW="${SUPERFAST_SWITCH:-$HOME/.local/bin/superfast-switch}"
CONF_DIR="${SUPERFAST_CONF_DIR:-$HOME/.config/superfast}"
CONF="$CONF_DIR/superfast.conf"
PROFILES="dense flash gemma deepseek"

mkdir -p "$CONF_DIR"
[ -f "$CONF" ] || cat > "$CONF" <<'EOF'
# SUPERFAST settings
# API key required by the gateway that faces the network (leave empty = no auth)
# THINKING_EFFORT=low      # low | medium | high  (Qwen default 'xhigh' causes overthinking)
# GATEWAY_PORT=8741
EOF

show_status() {
    "$SW" status
    # grep exits 1 when the setting is absent, so guard the pipeline; the
    # value may carry a trailing comment, which is stripped here.
    local effort
    effort="$(grep -E '^THINKING_EFFORT=' "$CONF" | cut -d= -f2 | sed 's/#.*//' | tr -d '[:space:]' | head -n1 || true)"
    echo "thinking default: ${effort:-(unset: low is what we recommend for chat)}"
}

# One implementation, shared with the GNOME extension: the api-key commands live
# in superfast-switch, and the TUI forwards to them (on|off|show|set|clear).
api_key() { "$SW" api-key "$@"; }

ports() {
    echo "main profile endpoint : ${SUPERFAST_PORT:-8731}"
    echo "orchestrator endpoint : ${SUPERFAST_ORCH_PORT:-8732}"
    echo "auth gateway (if on)  : ${GATEWAY_PORT:-8741}"
}

help() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

menu() {
    while true; do
        echo
        echo "SUPERFAST — choose an action"
        echo "  1) status"
        echo "  2) activate a model"
        echo "  3) orchestrator on/off"
        echo "  4) api key"
        echo "  5) ports"
        echo "  h) help   q) quit"
        printf '> '
        read -r c
        case "$c" in
            1) show_status ;;
            2) printf 'profile (%s): ' "$PROFILES"; read -r p; "$SW" use "$p" ;;
            3) printf 'orchestrator on/off: '; read -r o; "$SW" orchestrator "$o" ;;
            4) printf 'api-key on/off/show/set/clear: '; read -r a b; api_key "$a" "$b" ;;
            5) ports ;;
            h|help) help ;;
            q|quit) break ;;
            *) echo "unknown choice" ;;
        esac
    done
}

case "${1:-menu}" in
    status) show_status ;;
    use)
        if [ $# -ge 2 ]; then
            "$SW" use "$2"
        else
            echo "usage: superfast-tui use <$PROFILES>"
        fi
        ;;
    orchestrator) "$SW" orchestrator "${2:-status}" ;;
    api-key|apikey) api_key "${@:2}" ;;
    ports) ports ;;
    help|-h|--help) help ;;
    menu) menu ;;
    *) echo "unknown command '$1'"; help; exit 2 ;;
esac
