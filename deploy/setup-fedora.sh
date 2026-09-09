#!/usr/bin/env bash
# deploy/setup-fedora.sh — bring a fresh Fedora Workstation 44 host
# (AMD Strix Halo, gfx1151 — Ryzen AI Max+ 395) to the state validated for
# running the SUPERFAST engine container.
#
# STATUS (2026-09-09):
#   Phases 1-9  VALIDATED on the reference host — every command below was run
#               and verified there; see docs/fedora-44-setup.md for the log.
#               Phase 8 installs superfast.service (dense, systemd user unit)
#               and waits for /health. Phase 9 installs the model switch and
#               the optional Flash-Next profile unit.
#
# Run as the admin user (sudo is used internally where needed):
#   bash deploy/setup-fedora.sh
#
# Env overrides:
#   SUPERFAST_IMAGE   ghcr.io/peonist-ai/superfast:0.1.3 once published
#                     (default: halogen tag, the currently published image)
#   MODELS_DIR        where the checkpoint lives (default: ~/superfast-models)
#   SKIP_UPDATE=1     skip `dnf upgrade`
#   SMOKE=1           also run the small container device test
#
# The reference host uses LUKS disk encryption: headless reboots stop at the
# passphrase prompt (console unlock required; TPM2/clevis unlock is a future
# option, not part of this script).
#
# Memory layout: the reference host BIOS has the UMA frame buffer set to its
# minimum (1 GB), so the full unified memory is one pool. This is required for
# large checkpoints (e.g. the ~115 GB Flash-Next MoE); it is harmless for the
# dense 27B checkpoint. Phase 5 also raises the TTM/GTT shared-memory limit.
set -euo pipefail

IMAGE="${SUPERFAST_IMAGE:-ghcr.io/peonist-ai/halogen:0.1.3}"
MODELS_DIR="${MODELS_DIR:-$HOME/superfast-models}"
CKPT="$MODELS_DIR/qwen3.8-27b-p1w4d-d2.hgn"
PART="$CKPT.part"
DONE_MARKER="$MODELS_DIR/.download-complete"
URL="${CHECKPOINT_URL:-https://huggingface.co/peonist-ai/halogen-qwen3.8-27b/resolve/main/qwen3.8-27b-p1w4d-d2.hgn}"
DEFAULT_EXPECTED_SIZE=35865565184

TARGET_USER="${SUDO_USER:-$USER}"

log() { echo "[$(date '+%F %T')] $*"; }

phase_os_check() {
    log "== phase 1/9: OS check =="
    [ -f /etc/os-release ] || { echo "not a Fedora system (no /etc/os-release)"; exit 1; }
    . /etc/os-release
    [ "$ID" = "fedora" ] || { echo "not Fedora (ID=$ID); this script targets Fedora Workstation 44"; exit 1; }
    log "Fedora $VERSION_ID ($VARIANT) on $(uname -m)"
    # gfx1151 enablement lives in the kernel: refuse anything older than 44.
    if [ "${VERSION_ID%%.*}" -lt 44 ]; then
        echo "Fedora >= 44 required (found $VERSION_ID) for gfx1151 support"; exit 1
    fi
    if [ "$(id -u)" -eq 0 ]; then
        echo "Run as the admin user, not root (rootless podman is used later)."; exit 1
    fi
}

phase_update() {
    log "== phase 2/9: system update =="
    if [ "${SKIP_UPDATE:-0}" = "1" ]; then log "SKIP_UPDATE set — skipping"; return; fi
    sudo dnf upgrade --refresh -y
    log "system updated; a reboot is recommended before continuing"
}

phase_sshd() {
    log "== phase 3/9: SSH server =="
    sudo dnf install -y openssh-server
    sudo systemctl enable --now sshd
    sudo firewall-cmd --add-service=ssh --permanent
    sudo firewall-cmd --reload
    log "sshd enabled; port 22 open"
}

phase_groups() {
    log "== phase 4/9: GPU groups =="
    sudo usermod -aG video,render "$TARGET_USER"
    log "added $TARGET_USER to video,render (effective on next login)"
}

phase_suspend_mask() {
    log "== phase 5/9: disable auto-suspend + raise shared-memory limit =="
    # Required for unattended big downloads: GNOME suspended the reference
    # host mid-download once (see runbook).
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    # TTM/GTT shared-memory limit, raised to ~120 GiB and persisted across
    # reboots. Runtime write also works:
    #   echo 31457280 | sudo tee /sys/module/ttm/parameters/pages_limit
    echo 'options ttm pages_limit=31457280' | sudo tee /etc/modprobe.d/ttm.conf
    log "sleep/suspend/hibernate masked; ttm.conf written (applies on next boot)"
}

phase_weights() {
    log "== phase 6/9: checkpoint download (curl -C -, exact-offset resume) =="
    mkdir -p "$MODELS_DIR"

    # Expected size from the server; fall back to the validated value.
    EXPECTED=$(curl -sIL --max-time 60 "$URL" \
        | awk 'tolower($1)=="content-length:"{v=$2} END{gsub("\r","",v); print v}')
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" -lt 35000000000 ] 2>/dev/null; then
        EXPECTED=$DEFAULT_EXPECTED_SIZE
    fi
    log "expected checkpoint size: $EXPECTED"

    if [ -f "$CKPT" ] && [ "$(stat -c %s "$CKPT")" -ge "$EXPECTED" ]; then
        log "checkpoint already complete"
        touch "$DONE_MARKER"
        return
    fi

    # NOTE: do NOT switch this to `hf download` for the big file. Xet stalls
    # on constrained links and hf's resume silently breaks (HF rotates etags
    # between runs, each restart starts a new .incomplete). curl -C - resumes
    # at the exact byte offset and loses nothing. See docs/fedora-44-setup.md.
    while true; do
        sz=$(stat -c %s "$PART" 2>/dev/null || echo 0)
        timeout 300 curl -sL -C - --max-time 290 -o "$PART" "$URL" || true
        sz2=$(stat -c %s "$PART" 2>/dev/null || echo 0)
        log "curl attempt: size=$sz2 delta=$((sz2 - sz))"
        if [ "$sz2" -ge "$EXPECTED" ]; then
            mv -f "$PART" "$CKPT"
            touch "$DONE_MARKER"
            log "checkpoint complete: $(stat -c %s "$CKPT") bytes"
            return
        fi
        sleep 20
    done
}

phase_image() {
    log "== phase 7/9: engine image =="
    if podman image exists "$IMAGE"; then
        log "image already present: $IMAGE"
    else
        until podman pull "$IMAGE"; do
            log "image pull failed; retrying in 60s"
            sleep 60
        done
        log "image pulled: $IMAGE"
    fi
}

phase_smoke() {
    log "== phase 7b/9: container device test (SMOKE=1) =="
    podman run --rm --device /dev/kfd --device /dev/dri docker.io/library/fedora:44 \
        ls -l /dev/kfd /dev/dri
}

phase_engine() {
    log "== phase 8/9: engine service (systemd user unit) =="
    # OpenAI-compatible API port, reachable from the LAN. The engine's token
    # protocol stays unpublished inside the container.
    sudo firewall-cmd --add-port=8731/tcp --permanent
    sudo firewall-cmd --reload

    # A classic user unit (not a podman quadlet): quadlet units were not
    # regenerated by `daemon-reload` on the reference host, while a classic
    # unit works everywhere. Linger must be on for the unit to start at boot:
    sudo loginctl enable-linger "$TARGET_USER"

    UID_NUM="$(id -u)"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/superfast.service" <<EOF
[Unit]
Description=SUPERFAST engine (Qwen3.8-27B on Strix Halo)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/$UID_NUM
ExecStartPre=-/usr/bin/podman rm -f superfast
ExecStart=/usr/bin/podman run --name superfast --rm -p 8731:8731 \\
  --device /dev/kfd --device /dev/dri --group-add keep-groups \\
  --security-opt seccomp=unconfined --ipc=host \\
  -v $MODELS_DIR:/models:ro \\
  -v $MODELS_DIR/tokenizer:/tokenizer:ro \\
  $IMAGE
ExecStop=/usr/bin/podman stop -t 20 superfast
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user daemon-reload
    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user enable --now superfast.service
    log "superfast.service enabled; waiting for /health on :8731"
    for i in $(seq 1 40); do
        if curl -s -o /dev/null --max-time 5 http://127.0.0.1:8731/health; then
            log "engine healthy after ~$((i * 10))s"
            return 0
        fi
        sleep 10
    done
    log "engine not healthy in time; inspect: journalctl --user -u superfast.service"
    return 1
}

phase_flash_profile() {
    log "== phase 9: Flash-Next profile (optional) + model switch =="
    # Install the model switch CLI from this repo, so `superfast-switch` is
    # available even when the repo clone is not on PATH.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SWITCH_SRC="$SCRIPT_DIR/../tools/superfast-switch.sh"
    if [ -f "$SWITCH_SRC" ]; then
        mkdir -p "$HOME/.local/bin"
        cp "$SWITCH_SRC" "$HOME/.local/bin/superfast-switch"
        chmod +x "$HOME/.local/bin/superfast-switch"
        log "installed superfast-switch to ~/.local/bin"
    else
        log "tools/superfast-switch.sh not found next to the script; skipping"
    fi

    # The Flash-Next MoE profile. The unit is created but stays disabled: the
    # switch starts it once the checkpoint is present (see superfast-switch).
    MODELS_DIR_FLASH="${MODELS_DIR_FLASH:-$HOME/superfast-flash}"
    FLASH_IMAGE="${SUPERFAST_FLASH_IMAGE:-ghcr.io/peonist-ai/halogen-flash-server:0.5.2}"
    UID_NUM="$(id -u)"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/superfast-flash.service" <<EOF
[Unit]
Description=SUPERFAST flash engine (Qwen3.8-Flash-Next MoE, Strix Halo)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/$UID_NUM
ExecStartPre=-/usr/bin/podman rm -f superfast-flash
ExecStart=/usr/bin/podman run --name superfast-flash --rm -p 8731:8731 \\
  --device /dev/kfd --device /dev/dri --group-add keep-groups \\
  --security-opt seccomp=unconfined --ipc=host \\
  -v $MODELS_DIR_FLASH:/models:ro \\
  -v $MODELS_DIR_FLASH/tokenizer:/tokenizer:ro \\
  $FLASH_IMAGE
ExecStop=/usr/bin/podman stop -t 30 superfast-flash
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF

    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user daemon-reload
    log "superfast-flash.service ready (disabled until 'superfast-switch use flash')"
}

main() {
    phase_os_check
    phase_update
    phase_sshd
    phase_groups
    phase_suspend_mask
    phase_weights
    phase_image
    [ "${SMOKE:-0}" = "1" ] && phase_smoke
    phase_engine
    phase_flash_profile
    log "setup complete — dense profile serving on http://<host>:8731;"
    log "use 'superfast-switch use flash' for the Flash-Next MoE profile"
}

main
