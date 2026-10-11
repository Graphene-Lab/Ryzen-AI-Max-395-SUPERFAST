#!/bin/bash
# superfast-recover — give the host its contiguous memory back, without a reboot.
#
# WHY THIS EXISTS
# ---------------
# The flash profile holds most of the machine: on the reference host the engine
# reports 68.0 GiB of weights locked in RAM, plus the KV pool, plus its working
# memory — 98.2 GiB of 124 GiB with the pool at 655360. The rest of the system
# shares what is left, and the engine's 47.7 GiB lookup table is read from disk
# through the page cache, which never fits in that remainder.
#
# That is fine while there is room. It stops being fine when the host's memory
# has accumulated: the page cache and the zram swap fill up, and the contiguous
# 2 MiB blocks the engine allocates from run out. The engine then stalls (it
# says so itself: "this server now holds most of the machine … BOTH they and
# this server can stall for minutes at a time … which is not a crash and needs
# no restart"), the container's 180 s watchdog kills it, systemd restarts it,
# and the restart begins with less room than the one before, so the state gets
# worse instead of better.
#
# A host reboot fixes that state, and it is the only thing that definitely
# does. This tool is the next best thing: it hands the engine back the resource
# it is short of, without rebooting. Measured on the reference host:
#
#   free 2 MiB blocks (order-9, /proc/buddyinfo), engine running    16
#   after stopping the profile                                      86
#   after drop_caches + compact_memory                             537
#   engine headroom reported on the next start (pool 655360)   16.5 GiB
#
# WHAT IT DOES, IN ORDER
#   1. stops the active profile (this drops its prompt cache: a later turn
#      re-prefills, so run it between conversations, not during one)
#   2. waits for the engine's memory to be returned to the kernel
#   3. sync, then drop the page cache and compact memory (needs root)
#   4. starts the profile again and waits until it answers
#   5. prints the headroom the engine reports, and checks one request
#
# If the profile still does not come up, the honest answer is a host reboot;
# this tool says so instead of pretending otherwise.
#
# Usage:  superfast-recover
#         superfast-recover --help

set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

usage() {
    sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}
[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && usage

# Free 2 MiB (order-9) blocks across all zones, from /proc/buddyinfo. This is
# the resource of the engine's own log lines ("N contiguous 2 MiB blocks").
numfmt_blocks() {
    awk '{ for (i = 5; i <= NF; i++) if (i - 5 == 9) s += $i } END { print s + 0 }' /proc/buddyinfo
}

command -v systemctl >/dev/null 2>&1 || { say "systemctl not found; this tool is for the Fedora host"; exit 1; }

# Which profile is serving? The directory of units is the source of truth.
active=""
for p in dense flash gemma deepseek; do
    u="superfast${p#dense}"; [ "$p" = "dense" ] && u="superfast"
    [ "$p" = "flash" ]   && u="superfast-flash"
    [ "$p" = "gemma" ]   && u="superfast-gemma"
    [ "$p" = "deepseek" ] && u="superfast-deepseek"
    if [ "$(systemctl --user is-active "$u.service" 2>/dev/null)" = "active" ]; then
        active="$p"; unit="$u.service"; break
    fi
done
if [ -z "$active" ]; then
    say "no SUPERFAST profile is running, so there is nothing to recover."
    say "If the engine keeps failing to start, the state to clear is the same:"
    say "  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'"
    say "then start the profile with: superfast-switch use <profile>"
    exit 0
fi

say "profile: $active ($unit)"
say ""
say "before:"
note "free 2 MiB blocks (order-9): $(numfmt_blocks)"
note "memory: $(free -m | awk '/^Mem:/ {printf "%s MiB used, %s MiB free, %s MiB available", $3, $4, $7}')"
note "swap:   $(free -m | awk '/^Swap:/ {printf "%s of %s MiB used", $3, $2}')"

# 1. Stop the profile and let the kernel take the memory back.
say ""
say "stopping $active (its prompt cache is dropped; the next turn re-prefills)…"
systemctl --user stop "$unit" || { say "could not stop $unit"; exit 1; }
for _ in $(seq 1 30); do
    podman container exists "$unit" 2>/dev/null || break
    sleep 2
done
podman rm -f "${unit%.service}" >/dev/null 2>&1 || true
sleep 3
note "after the stop, free 2 MiB blocks: $(numfmt_blocks)"

# 2. Reclaim: the page cache is what the engine does not need, and compaction is
#    what turns scattered free pages back into the 2 MiB blocks it allocates.
say ""
STEPS="sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory"
HELPER=/usr/local/sbin/superfast-reclaim
reclaimed=0
if [ "$(id -u)" = "0" ]; then
    sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory
    reclaimed=1
    note "dropped the page cache and compacted memory (running as root)"
elif [ -x "$HELPER" ] && sudo -n "$HELPER" 2>/dev/null; then
    # The installer puts this root-owned script in place with a sudoers rule that
    # allows it, and only it, without a password. It takes no arguments.
    reclaimed=1
    note "dropped the page cache and compacted memory (via $HELPER, no password)"
elif sudo -n true 2>/dev/null; then
    sudo -n sh -c "$STEPS" && reclaimed=1
    [ "$reclaimed" = "1" ] && note "dropped the page cache and compacted memory (passwordless sudo)"
elif [ -t 0 ]; then
    echo "  sudo is about to ask for your password, to write /proc/sys/vm/*"
    sudo sh -c "$STEPS" && reclaimed=1
    [ "$reclaimed" = "1" ] && note "dropped the page cache and compacted memory"
fi
if [ "$reclaimed" != "1" ]; then
    say ""
    say "the reclaim step needs root for /proc/sys/vm/*, and this run cannot ask for"
    say "a password. The restart below still helps a little, but the reclaim is what"
    say "gives the memory back, so run one of these by hand:"
    say "  sudo sh -c '$STEPS'"
    say "  (or install the helper: sudo install -Dm0755 tools/superfast-reclaim.sh \\"
    say "     /usr/local/sbin/superfast-reclaim, plus a sudoers rule that allows it)"
fi
note "after the reclaim, free 2 MiB blocks: $(numfmt_blocks)"

# 3. Start again and wait for it to answer.
say ""
say "starting $active…"
systemctl --user start "$unit"
healthy=0
for i in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8731/health 2>/dev/null)" = "200" ]; then
        healthy=1; note "answered after about $((i * 5)) s"; break
    fi
    sleep 5
done

# 4. Report what the engine says about its headroom, and check one request.
say ""
say "the engine's own report:"
journalctl --user -u "$unit" --no-pager --since '5 min ago' 2>/dev/null | grep -v 'podman\[' |
    grep -E 'host memory left|KV pool reserved|memory:.*(locked|working)' |
    sed 's/^.*\]: /  /' | tail -3 || true

if [ "$healthy" = "1" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
        -H 'content-type: application/json' \
        -d '{"messages":[{"role":"user","content":"Say OK"}],"max_tokens":8}' \
        http://127.0.0.1:8731/v1/chat/completions 2>/dev/null)
    say ""
    case "$code" in
        200) say "recovered: $active is serving again." ;;
        *)   say "the engine answers /health but not a request (http ${code:-none})." ;;
    esac
else
    say ""
    say "$active did not become healthy."
    say "If this is the second attempt, the host's memory state is beyond what"
    say "this tool can clear: reboot the host, which is the reliable fix."
fi
