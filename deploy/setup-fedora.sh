#!/usr/bin/env bash
# deploy/setup-fedora.sh — bring a fresh Fedora Workstation 44 host
# (AMD Strix Halo, gfx1151 — Ryzen AI Max+ 395) to the state validated for
# running the SUPERFAST engine container.
#
# STATUS (2026-09-10):
#   Phases 1-10 VALIDATED on the reference host (phase 10 added 2026-09-10:
#   control panel + API-key gateway). Every command below was run and verified
#   there; see docs/fedora-44-setup.md for the log.
#
# Run as the admin user (sudo is used internally where needed):
#   bash deploy/setup-fedora.sh
#
# Env overrides:
#   SUPERFAST_IMAGE   image to run (default: the published halogen tag).
#                     A `superfast` tag does not exist yet; when it is
#                     published it will be the same content.
#   MODELS_DIR        where the checkpoint lives (default: ~/superfast-models)
#   SKIP_UPDATE=1     skip `dnf upgrade`
#   SMOKE=1           also run the small container device test
#
# Disk encryption: the reference host does NOT use it, so reboots are fully
# headless (verified 2026-09-10). If you enable encryption in the installer,
# every reboot then stops at the passphrase prompt and needs a console;
# TPM2/clevis auto-unlock would be required for headless operation.
#
# Memory layout: the reference host BIOS has the UMA frame buffer set to its
# minimum (1 GB), so the full unified memory is one pool. This is required for
# large checkpoints (e.g. the ~115 GB Flash-Next MoE); it is harmless for the
# dense 27B checkpoint. Phase 5 also raises the shared-memory limits the GPU
# may allocate from (amdgpu.gttsize + ttm.pages_limit, both on the kernel
# command line), which the largest checkpoints need.
set -euo pipefail

IMAGE="${SUPERFAST_IMAGE:-ghcr.io/peonist-ai/halogen:0.1.3}"
REBOOT_NEEDED=0
MODELS_DIR="${MODELS_DIR:-$HOME/superfast-models}"
CKPT="$MODELS_DIR/qwen3.8-27b-p1w4d-d2.hgn"
PART="$CKPT.part"
DONE_MARKER="$MODELS_DIR/.download-complete"
URL="${CHECKPOINT_URL:-https://huggingface.co/peonist-ai/halogen-qwen3.8-27b/resolve/main/qwen3.8-27b-p1w4d-d2.hgn}"
DEFAULT_EXPECTED_SIZE=35865565184

TARGET_USER="${SUDO_USER:-$USER}"

log() { echo "[$(date '+%F %T')] $*"; }

phase_os_check() {
    log "== phase 1/10: OS check =="
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
    log "== phase 2/10: system update =="
    if [ "${SKIP_UPDATE:-0}" = "1" ]; then log "SKIP_UPDATE set — skipping"; return; fi
    sudo dnf upgrade --refresh -y
    log "system updated; a reboot is recommended before continuing"
}

phase_sshd() {
    log "== phase 3/10: SSH server =="
    sudo dnf install -y openssh-server
    sudo systemctl enable --now sshd
    sudo firewall-cmd --add-service=ssh --permanent
    sudo firewall-cmd --reload
    log "sshd enabled; port 22 open"
}

phase_groups() {
    log "== phase 4/10: GPU groups =="
    sudo usermod -aG video,render "$TARGET_USER"
    log "added $TARGET_USER to video,render (effective on next login)"
}

phase_suspend_mask() {
    log "== phase 5/10: disable auto-suspend + raise shared-memory limit =="
    # Required for unattended big downloads: GNOME suspended the reference
    # host mid-download once (see runbook).
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    # The shared memory the GPU may allocate is the SMALLER of these two
    # limits, and both sit at their defaults until raised:
    #   amdgpu.gttsize    -> GTT aperture, in MiB
    #   ttm.pages_limit   -> TTM limit, in 4 KiB pages
    # Measured on the reference host: 16309919 pages * 4096 B = 63710 MiB, and
    # the GPU runtime reported exactly 63710 MiB of device memory. Raising
    # only one of the two changes nothing, and a runtime sysfs write is too
    # late because amdgpu fixes the pool size when it loads. Both therefore go
    # on the kernel command line, which needs a reboot. Without this the large
    # checkpoints fail with "cudaMalloc failed: out of memory".
    cmdline_args="amdgpu.gttsize=118784 ttm.pages_limit=31457280"
    if grep -q -- "amdgpu.gttsize=" /etc/kernel/cmdline 2>/dev/null; then
        log "shared-memory parameters already present in /etc/kernel/cmdline"
    else
        sudo grubby --update-kernel=ALL --args="$cmdline_args"
        log "added to the kernel command line: $cmdline_args (REBOOT REQUIRED)"
        REBOOT_NEEDED=1
    fi
    # Kept as well for module loads that happen outside the kernel command
    # line; on Fedora it is NOT enough on its own (not in the initramfs).
    echo 'options ttm pages_limit=31457280' | sudo tee /etc/modprobe.d/ttm.conf >/dev/null
    log "sleep/suspend/hibernate masked; shared-memory limit set"
}

phase_weights() {
    log "== phase 6/10: checkpoint download (curl -C -, exact-offset resume) =="
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
    log "== phase 7/10: engine image =="
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
    log "== phase 7b/10: container device test (SMOKE=1) =="
    podman run --rm --device /dev/kfd --device /dev/dri docker.io/library/fedora:44 \
        ls -l /dev/kfd /dev/dri
}

phase_engine() {
    log "== phase 8/10: engine service (systemd user unit) =="
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
    log "== phase 9/10: Flash-Next profile (optional) + model switch =="
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

phase_ui_auth() {
    log "== phase 10/10: control panel (TUI + GNOME extension) and API-key gateway =="
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    UID_NUM="$(id -u)"
    CONF_DIR="$HOME/.config/superfast"
    mkdir -p "$CONF_DIR" "$HOME/.local/bin"
    if [ ! -f "$CONF_DIR/superfast.conf" ]; then
        cat > "$CONF_DIR/superfast.conf" <<'EOF'
# SUPERFAST settings
# THINKING_EFFORT=low     # low | medium | high (Qwen default 'xhigh' over-thinks)
# GATEWAY_PORT=8741
EOF
    fi
    for f in superfast-tui.sh superfast-gateway.py; do
        if [ -f "$SCRIPT_DIR/../tools/$f" ]; then
            cp "$SCRIPT_DIR/../tools/$f" "$HOME/.local/bin/"
            chmod +x "$HOME/.local/bin/$f"
        fi
    done

    # Orchestrator unit, only if its small model is already present.
    if [ -f "$HOME/small-models/LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf" ]; then
        cat > "$HOME/.config/systemd/user/orchestrator.service" <<EOF
[Unit]
Description=LFM2.5-1.2B orchestrator (small fast router, port 8732)
After=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/$UID_NUM
ExecStartPre=-/usr/bin/podman rm -f orchestrator
ExecStart=/usr/bin/podman run --name orchestrator --rm -p 8732:8731 \\
  --device /dev/kfd --device /dev/dri --group-add keep-groups \\
  --security-opt seccomp=unconfined --ipc=host \\
  -v $HOME/small-models:/models:ro \\
  llama-rocmfpx:7.2.4 \\
  -m /models/LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf \\
  --host 0.0.0.0 --port 8731 -c 8192 --alias lfm25-1.2b
ExecStop=/usr/bin/podman stop -t 20 orchestrator
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
        log "orchestrator.service created (stopped; toggle with superfast-switch orchestrator on)"
    else
        log "orchestrator model not present in ~/small-models; skipping its unit"
    fi

    # API-key gateway in front of the main endpoint (needs a key file).
    cat > "$HOME/.config/systemd/user/superfast-gateway.service" <<EOF
[Unit]
Description=SUPERFAST API-key gateway (LAN -> loopback LLM)
After=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/$UID_NUM
ExecStart=/usr/bin/python3 $HOME/.local/bin/superfast-gateway.py \\
  --listen 0.0.0.0:8741 --upstream 127.0.0.1:8731 \\
  --key-file $CONF_DIR/api.key
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    if [ -s "$CONF_DIR/api.key" ]; then
        XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user enable --now superfast-gateway.service
        log "gateway enabled on :8741 (key from $CONF_DIR/api.key)"
    else
        log "gateway installed but disabled: create a key with 'superfast-tui api-key set' first"
    fi

    # GNOME Shell extension (control panel), if a GNOME session is present.
    if command -v gnome-extensions >/dev/null 2>&1; then
        EXT_DIR="$HOME/.local/share/gnome-shell/extensions/superfast@graphene-lab"
        mkdir -p "$EXT_DIR"
        cp -r "$SCRIPT_DIR/../gnome-shell-extension/." "$EXT_DIR/"
        log "GNOME extension installed; run: gnome-extensions enable superfast@graphene-lab (then log out/in once)"
    else
        log "gnome-extensions not found; skipping the desktop control panel"
    fi

    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user daemon-reload
    log "console tools: superfast-tui (menu), superfast-switch (CLI)"
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
    phase_ui_auth
    log "setup complete — dense profile serving on http://<host>:8731"
    log "control: superfast-tui (terminal) or the GNOME extension; switch with superfast-switch"
    if [ "$REBOOT_NEEDED" = "1" ]; then
        log "REBOOT REQUIRED: the shared-memory kernel parameters take effect only after a reboot."
        log "After rebooting, the large profiles (flash, deepseek) can load; check with:"
        log "  cat /proc/cmdline   # must show amdgpu.gttsize=118784 ttm.pages_limit=31457280"
    fi
}

main
