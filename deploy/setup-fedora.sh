#!/usr/bin/env bash
# deploy/setup-fedora.sh — bring a fresh Fedora Workstation 44 host
# (AMD Strix Halo, gfx1151 — Ryzen AI Max+ 395) to the state validated for
# running the SUPERFAST engine container.
#
# STATUS (2026-09-10):
#   Phases 1-10 VALIDATED on the reference host. Every command below was run
#   and verified there; see docs/fedora-44-setup.md for the log. Phase 9
#   installs one unit and one downloader per requested profile, so a single
#   run can prepare the machine for all four models plus the orchestrator.
#
# Run as the admin user (sudo is used internally where needed):
#   bash deploy/setup-fedora.sh
#
# When a phase fails the script prints where it stopped and the URL of the
# issue form, because the first runs on fresh hardware ARE the test for this
# script — we cannot try it on your machine. Two lines of the log are usually
# enough: the last "== phase N/10" line and the error under it. For the half
# that runs after the reboot, that log is the journal:
#   journalctl -u superfast-setup-resume --no-pager | tail -40
#
# Fully unattended, including the reboot the kernel parameters need:
#   curl -fsSL https://raw.githubusercontent.com/Graphene-Lab/Ryzen-AI-Max-395-SUPERFAST/main/deploy/setup-fedora.sh -o setup-fedora.sh
#   PROFILES="dense flash gemma deepseek small" UNATTENDED=1 bash setup-fedora.sh
# With UNATTENDED=1 the script refuses to wait for anything: sudo must be
# passwordless (it says how), the script must be a file on disk (it re-runs
# itself after the reboot), and when the kernel parameters are set it installs
# a one-shot system unit, reboots after 15 s, and continues by itself. Follow
# the second half with `journalctl -u superfast-setup-resume -f`. Expect the
# whole thing to take hours: the dense checkpoint alone is 35.9 GB, and the
# other profiles start their own downloads in the background.
#
# Env overrides:
#   SUPERFAST_IMAGE   image to run (default: the published halogen tag).
#                     A `superfast` tag does not exist yet; when it is
#                     published it will be the same content.
#   MODELS_DIR        where the dense checkpoint lives (default: ~/superfast-models)
#   PROFILES          which profiles to prepare, space separated. Default
#                     "dense". Also accepted: flash, gemma, deepseek, small
#                     (the small orchestrator). Example:
#                       PROFILES="dense flash gemma deepseek small" bash deploy/setup-fedora.sh
#                     Weights for the extra profiles are fetched by a systemd
#                     unit per profile, so this script returns without waiting
#                     for tens of gigabytes to arrive.
#   ONLY              run only these phases (suffixes of the phase function
#                     names, space separated), e.g. ONLY="profiles" to install
#                     the profile units and downloaders again.
#   SKIP_UPDATE=1     skip `dnf upgrade`
#   SKIP_WEIGHTS=1    install the downloaders but fetch no checkpoint. For a
#                     dry-ish run on a machine that has no room for 275 GB of
#                     weights, or to set the machine up before the link is
#                     quiet: `systemctl --user start superfast-download@<p>`
#                     fetches them later.
#   SKIP_IMAGE=1      do not pull the engine image (it is still checked first)
#   SMOKE=1           also run the small container device test
#   UNATTENDED=1      never wait for a human: passwordless sudo required, the
#                     script must be on disk, and it reboots by itself once the
#                     kernel parameters are in place (needs the profile units;
#                     see above). The run continues after the reboot through
#                     superfast-setup-resume.service.
#   AUTO_REBOOT=1     same reboot-and-continue behaviour without the rest of
#                     unattended mode (useful when sudo already asks no
#                     password and you just want the reboot handled).
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
# `-E` matters: without it bash does not inherit the ERR trap into shell
# functions, and every phase here is a function — the report prompt below would
# never fire. Verified the hard way: a phase failed and nothing was printed.
set -eEuo pipefail

IMAGE="${SUPERFAST_IMAGE:-ghcr.io/peonist-ai/halogen:0.1.3}"
RUNTIME_IMAGE="${SUPERFAST_RUNTIME_IMAGE:-llama-rocmfpx:7.2.4}"
# Published candidates, in order. The first is built and published by this
# repository's workflow and is public, so no login is needed. If you mirror the
# image somewhere else, list those references in RUNTIME_PUBLISHED_EXTRA
# (space separated) and they are tried after it. When no candidate can be
# pulled, the image is built from runtime/ instead.
RUNTIME_PUBLISHED="${SUPERFAST_RUNTIME_PUBLISHED:-ghcr.io/graphene-lab/superfast-runtime:llama-rocmfpx-1}"
RUNTIME_PUBLISHED_EXTRA="${SUPERFAST_RUNTIME_PUBLISHED_EXTRA:-}"
FLASH_IMAGE="${SUPERFAST_FLASH_IMAGE:-ghcr.io/peonist-ai/halogen-flash-server:0.5.6}"
REBOOT_NEEDED=0
PROFILES="${PROFILES:-dense}"
MODELS_DIR="${MODELS_DIR:-$HOME/superfast-models}"
MODELS_DIR_FLASH="${MODELS_DIR_FLASH:-$HOME/superfast-flash}"
MODELS_DIR_GEMMA="${MODELS_DIR_GEMMA:-$HOME/gemma-models}"
MODELS_DIR_DEEPSEEK="${MODELS_DIR_DEEPSEEK:-$HOME/deepseek-models}"
MODELS_DIR_SMALL="${MODELS_DIR_SMALL:-$HOME/small-models}"

TARGET_USER="${SUDO_USER:-$USER}"
UID_NUM="$(id -u)"

log() { echo "[$(date '+%F %T')] $*"; }

# A stopped install is worth a report: this script cannot know what a different
# machine does with it, so the first runs on fresh hardware are the test. The
# trap prints the one URL that makes reporting easy, while the log is still on
# screen, and says which lines of it matter.
ISSUE_URL="https://github.com/Graphene-Lab/Ryzen-AI-Max-395-SUPERFAST/issues/new?template=installer-failure.yml"
on_error() {
    # stderr, not stdout: with `set -E` this trap also runs inside command
    # substitutions, and anything it writes to stdout would be captured into
    # whatever that substitution is building — a unit file, for instance.
    log "STOPPED at line $2 (exit $1). Whatever finished before this is done; re-running is safe." >&2
    log "If the cause is not obvious, the form asks for the log and two lines of it:" >&2
    log "  $ISSUE_URL" >&2
    log "  the last '== phase N/10' line, and the error under it." >&2
}
trap 'on_error $? $LINENO' ERR

# Is a word in a space-separated list?
is_in() { # "list" word
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

# firewalld is what Fedora Workstation ships, and the rules matter: 8741 open
# for the API-key gateway, 8731 closed. A container image or a WSL image may
# not have it at all, and that is no reason to stop halfway through an install,
# so the rules are skipped with a clear warning instead. Users get the same
# treatment on any Fedora that is missing it.
firewall_rule() { # args passed to firewall-cmd
    if command -v firewall-cmd >/dev/null 2>&1; then
        sudo firewall-cmd "$@"
    else
        log "firewalld is not installed here: skipping 'firewall-cmd $*'."
        log "  Fedora Workstation always has it. On this machine, open 8741/tcp"
        log "  yourself for the LAN gateway, and keep 8731 closed."
        return 0
    fi
}

# Is a profile in the PROFILES list?
in_profiles() {
    is_in "$PROFILES" "$1"
}

# Weights directory of a profile.
profile_dir() {
    case "$1" in
        dense)    echo "$MODELS_DIR" ;;
        flash)    echo "$MODELS_DIR_FLASH" ;;
        gemma)    echo "$MODELS_DIR_GEMMA" ;;
        deepseek) echo "$MODELS_DIR_DEEPSEEK" ;;
        small)    echo "$MODELS_DIR_SMALL" ;;
    esac
}

# Unit name of a profile (the orchestrator is named after its role).
unit_for() {
    case "$1" in
        flash) echo "superfast-flash" ;;
        small) echo "orchestrator" ;;
        *)     echo "$1" ;;
    esac
}

# Have this profile's weights already been downloaded (and verified)?
weights_complete() {
    [ -f "$(profile_dir "$1")/.download-complete" ]
}

# Copy a template from deploy/profiles/, filling in the placeholders. The
# profile directories are substituted too, so MODELS_DIR_* overrides reach the
# installed units.
install_template() { # src dst
    sed -e "s#__HOME__#$HOME#g" \
        -e "s#__XDG__#/run/user/$UID_NUM#g" \
        -e "s#__DENSE_DIR__#$MODELS_DIR#g" \
        -e "s#__FLASH_DIR__#$MODELS_DIR_FLASH#g" \
        -e "s#__GEMMA_DIR__#$MODELS_DIR_GEMMA#g" \
        -e "s#__DEEPSEEK_DIR__#$MODELS_DIR_DEEPSEEK#g" \
        -e "s#__SMALL_DIR__#$MODELS_DIR_SMALL#g" \
        -e "s#__FLASH_IMAGE__#$FLASH_IMAGE#g" "$1" > "$2"
}

# Install the shared weights downloader (one script, one unit template).
install_downloader() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ ! -f "$script_dir/profiles/download-weights.sh" ]; then
        log "deploy/profiles/download-weights.sh not found; cannot install the downloader"
        return 1
    fi
    mkdir -p "$HOME/.local/bin/superfast-downloads" "$HOME/.config/systemd/user"
    # install_template, not cp: the script carries the same __*_DIR__
    # placeholders as the units, so MODELS_DIR_* overrides reach it too.
    install_template "$script_dir/profiles/download-weights.sh" \
        "$HOME/.local/bin/superfast-downloads/download-weights.sh"
    chmod 755 "$HOME/.local/bin/superfast-downloads/download-weights.sh"
    install_template "$script_dir/profiles/superfast-download@.service" \
        "$HOME/.config/systemd/user/superfast-download@.service"
    return 0
}

phase_os_check() {
    log "== phase 1/10: OS check =="
    [ -f /etc/os-release ] || { echo "not a Fedora system (no /etc/os-release)"; exit 1; }
    . /etc/os-release
    [ "$ID" = "fedora" ] || { echo "not Fedora (ID=$ID); this script targets Fedora Workstation 44"; exit 1; }
    log "Fedora $VERSION_ID (${VARIANT:-unknown variant}) on $(uname -m)"
    # gfx1151 enablement lives in the kernel: refuse anything older than 44.
    if [ "${VERSION_ID%%.*}" -lt 44 ]; then
        echo "Fedora >= 44 required (found $VERSION_ID) for gfx1151 support"; exit 1
    fi
    if [ "$(id -u)" -eq 0 ]; then
        echo "Refusing to run as root: rootless podman and the user units are the point."; exit 1
    fi
    # Tools the script needs beyond a base install. curl and flock do the
    # downloads, grubby edits the kernel command line, podman runs the
    # profiles. Missing ones are installed here, and a failure is not fatal:
    # the phase that needs the tool reports the error.
    for t in curl flock sha256sum grubby podman; do
        if ! command -v "$t" >/dev/null 2>&1; then
            log "installing missing tool: $t"
            sudo dnf install -y "$t" || log "could not install $t; a later phase may fail"
        fi
    done
    # Several phases use sudo, so this needs either a terminal to type the
    # password or a NOPASSWD rule. Say so now instead of failing in phase 5.
    if sudo -n true 2>/dev/null; then
        log "sudo: ready without a password"
    else
        log "sudo: will ask for your password during this run (or configure NOPASSWD for $TARGET_USER)"
    fi
    # Unattended runs must never wait for a human: no terminal to answer sudo,
    # and no way to continue after the reboot unless the script is a file.
    if [ "${UNATTENDED:-0}" = "1" ]; then
        if ! sudo -n true 2>/dev/null; then
            echo "UNATTENDED=1 needs sudo without a password. Run this once, then try again:" >&2
            echo "  echo '$TARGET_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/superfast-unattended" >&2
            exit 1
        fi
        if [ ! -f "$0" ]; then
            echo "UNATTENDED=1 needs the script on disk (it re-runs itself after the reboot)." >&2
            echo "Download it first: curl -fsSL <raw url> -o setup-fedora.sh && bash setup-fedora.sh" >&2
            exit 1
        fi
        log "unattended mode: sudo is non-interactive and the script may reboot the machine"
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
    firewall_rule --add-service=ssh --permanent
    firewall_rule --reload
    log "sshd enabled; port 22 open"
}

phase_groups() {
    log "== phase 4/10: GPU groups =="
    # Fedora Workstation has both; a minimal image (a container rootfs, the WSL
    # image) may not, and `usermod -aG` fails outright on a group that does not
    # exist. Create what is missing rather than stopping the install.
    for g in video render; do
        if ! getent group "$g" >/dev/null 2>&1; then
            log "creating missing group: $g"
            sudo groupadd -r "$g"
        fi
    done
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
    log "== phase 6/10: dense checkpoint download (resumable, sha256-verified) =="
    if ! in_profiles dense; then
        log "dense is not in PROFILES ($PROFILES); skipping its checkpoint"
        return 0
    fi
    install_downloader || return 0
    if [ "${SKIP_WEIGHTS:-0}" = "1" ]; then
        log "SKIP_WEIGHTS set — the downloader is installed, nothing is fetched"
        return 0
    fi
    # Run in the foreground: the unit installed later in this script expects
    # the checkpoint to be there. The downloader resumes at the exact byte
    # offset if it is interrupted, keeps one writer per file, and checks the
    # SHA-256 published by Hugging Face before the final rename.
    log "dense: downloading into $MODELS_DIR (log: $MODELS_DIR/.download.log)"
    log "dense: the checkpoint is 35.9 GB, so on a slow link this phase takes hours."
    log "dense: stopping it is safe - the transfer resumes at the byte it reached,"
    log "dense: and re-running this script continues from there."
    bash "$HOME/.local/bin/superfast-downloads/download-weights.sh" dense
    log "dense: checkpoint ready"
}

phase_image() {
    log "== phase 7/10: engine image =="
    if ! in_profiles dense; then
        log "dense is not in PROFILES ($PROFILES); skipping the engine image"
        return 0
    fi
    if podman image exists "$IMAGE"; then
        log "image already present: $IMAGE"
        return 0
    fi
    if [ "${SKIP_IMAGE:-0}" = "1" ]; then
        log "SKIP_IMAGE set — not pulling $IMAGE"
        return 0
    fi
    # Bounded retries: an unbounded loop would spin forever on a tag that no
    # longer exists (upstream renamed it, or a typo in SUPERFAST_IMAGE).
    pulled=""
    for attempt in 1 2 3 4 5; do
        if podman pull "$IMAGE"; then
            pulled=1
            break
        fi
        log "image pull failed (attempt $attempt/5); retrying in 60s"
        sleep 60
    done
    if [ -z "$pulled" ]; then
        log "could not pull $IMAGE after 5 attempts."
        log "Check that the tag still exists, or point SUPERFAST_IMAGE at another reference."
        return 1
    fi
    log "image pulled: $IMAGE"
}

phase_smoke() {
    log "== phase 7b/10: container device test (SMOKE=1) =="
    podman run --rm --device /dev/kfd --device /dev/dri docker.io/library/fedora:44 \
        ls -l /dev/kfd /dev/dri
}

phase_engine() {
    log "== phase 8/10: engine service (systemd user unit) =="
    if ! in_profiles dense; then
        log "dense is not in PROFILES ($PROFILES); skipping its unit"
        return 0
    fi
    # The container reaches /dev/kfd and /dev/dri through the video and render
    # groups, and a user added to them in phase 4 only gets them in a NEW
    # session. Without this check the first run on a fresh machine would start
    # the engine, wait ten minutes for a health check that cannot succeed, and
    # blame the engine. A clear instruction instead.
    if ! id -nG | grep -qw video || ! id -nG | grep -qw render; then
        if [ "${UNATTENDED:-0}" = "1" ] || [ "${AUTO_REBOOT:-0}" = "1" ]; then
            # Unattended runs reboot anyway, and the reboot is exactly what the
            # groups need. The resumed run has them and starts the engine.
            log "this session does not have the video and render groups yet;"
            log "the reboot at the end of this run applies them, and the resumed"
            log "run starts the engine. Skipping the engine in this pass."
            REBOOT_NEEDED=1
            return 0
        fi
        log "this session does not have the video and render groups yet."
        log "They are added in phase 4 and take effect on a new login."
        log "Log out, log back in, then run this script again (it is resumable:"
        log "phases 1-7 are skipped or quick the second time):"
        log "  PROFILES=\"$PROFILES\" bash deploy/setup-fedora.sh"
        return 1
    fi
    # The profile API binds loopback on the host (see -p 127.0.0.1:8731 below),
    # so 8731 must NOT be open on the LAN. The only way in from the network is
    # the API-key gateway on 8741, opened here; a request without the key is
    # refused with 401. Remove any 8731 rule an earlier version added.
    firewall_rule --remove-port=8731/tcp --permanent 2>/dev/null || true
    firewall_rule --add-port=8741/tcp --permanent
    firewall_rule --reload

    # A classic user unit (not a podman quadlet): quadlet units were not
    # regenerated by `daemon-reload` on the reference host, while a classic
    # unit works everywhere. Linger must be on for the unit to start at boot:
    sudo loginctl enable-linger "$TARGET_USER"

    # Only one profile can own port 8731. Stop the others first, exactly like
    # the switch does, so that re-running this script on a machine that is
    # already serving does not fail to bind the port.
    for q in superfast-flash gemma deepseek; do
        XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user stop "$q.service" 2>/dev/null || true
    done

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
ExecStart=/usr/bin/podman run --name superfast --rm -p 127.0.0.1:8731:8731 \\
  --device /dev/kfd --device /dev/dri --group-add keep-groups \\
  --security-opt seccomp=unconfined --ipc=host \\
  -e HALOGEN_QUEUE_TIMEOUT=6000 \\
  -e HALOGEN_MAX_TOKENS_CAP=65536 \\
  -v $MODELS_DIR:/models:ro \\
  -v $MODELS_DIR/tokenizer:/tokenizer:ro \\
  $IMAGE
# Request policy, set here rather than left to the image (the names are the
# engine's: a SUPERFAST_ prefix is read by nobody). QUEUE_TIMEOUT 6000 s is the
# time a request waits before the engine answers 503; with one slot the worst
# wait four concurrent requests can produce is 4,980 s, so a shorter value
# would throw away the work already queued. MAX_TOKENS_CAP 65536 is the largest
# answer budget a request may ask for; above it the engine answers 400 rather
# than truncating. The arithmetic, and the client-side values that go with it,
# are in the README under "Timeouts, and why they are what they are".
ExecStop=/usr/bin/podman stop -t 30 superfast
# podman run in the foreground exits 143 (SIGTERM) or 137 (SIGKILL) when the
# container is stopped. Without this line a profile switch leaves the unit in
# the "failed" state, which \`superfast-switch status\` then reports.
# The backticks above are escaped on purpose: this heredoc is unquoted, so an
# unescaped command substitution here would RUN at install time and paste its
# output into this unit — which is how the dense unit on the reference machine
# ended up carrying a status listing instead of that sentence.
SuccessExitStatus=137 143
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user daemon-reload
    # enable, then restart: `enable --now` does nothing to a unit that is
    # already running, so re-running this script after changing anything in
    # this phase would keep the old unit file loaded. restart also starts a
    # unit that is not running.
    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user enable superfast.service
    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user restart superfast.service
    log "superfast.service enabled and started; waiting for /health on :8731"
    for i in $(seq 1 40); do
        # Require 200: the port can be open while the engine is still loading.
        if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8731/health)" = "200" ]; then
            log "engine healthy after ~$((i * 10))s"
            return 0
        fi
        sleep 10
    done
    log "engine not healthy in time; inspect: journalctl --user -u superfast.service"
    return 1
}

phase_profiles() {
    log "== phase 9/10: model switch, profile units, weights (PROFILES=$PROFILES) =="
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROF_DIR="$SCRIPT_DIR/profiles"
    if [ ! -d "$PROF_DIR" ]; then
        log "$PROF_DIR not found (the repository must sit next to this script); skipping the profile units"
        return 0
    fi
    XDG_RUNTIME_DIR="/run/user/$UID_NUM"
    export XDG_RUNTIME_DIR
    mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

    # 1. The model switch itself, so `superfast-switch` is on PATH even when
    # the repository is not.
    SWITCH_SRC="$SCRIPT_DIR/../tools/superfast-switch.sh"
    if [ -f "$SWITCH_SRC" ]; then
        cp "$SWITCH_SRC" "$HOME/.local/bin/superfast-switch"
        chmod +x "$HOME/.local/bin/superfast-switch"
        log "installed superfast-switch to ~/.local/bin"
    else
        log "tools/superfast-switch.sh not found next to the script; skipping"
    fi

    # 2. The GGUF runtime, needed by gemma, deepseek and the orchestrator.
    #    Prefer a published image; if none can be pulled (still private, or the
    #    machine is offline), build it from runtime/ instead.
    if in_profiles gemma || in_profiles deepseek || in_profiles small; then
        if podman image exists "$RUNTIME_IMAGE"; then
            log "GGUF runtime already present: $RUNTIME_IMAGE"
        elif [ "${SKIP_IMAGE:-0}" = "1" ]; then
            # The runtime is a 3.7 GB pull (or a build). Skipping it is what
            # makes a run on a machine that will not serve these profiles
            # cheap, but their units cannot start without it, so say that.
            log "SKIP_IMAGE set — not pulling or building $RUNTIME_IMAGE."
            log "  gemma, deepseek and the orchestrator need it before they can start."
        else
            pulled=""
            # $RUNTIME_PUBLISHED_EXTRA is deliberately unquoted: it is a list.
            for cand in "$RUNTIME_PUBLISHED" $RUNTIME_PUBLISHED_EXTRA; do
                [ -n "$cand" ] || continue
                if podman pull "$cand" && podman tag "$cand" "$RUNTIME_IMAGE"; then
                    log "runtime pulled from $cand and tagged as $RUNTIME_IMAGE"
                    pulled="$cand"
                    break
                fi
                log "pull failed: $cand"
            done
            if [ -z "$pulled" ]; then
                log "no published runtime available; building $RUNTIME_IMAGE from runtime/ -- this takes a while"
                if (cd "$SCRIPT_DIR/../runtime" && podman build -t "$RUNTIME_IMAGE" .); then
                    log "runtime built: $RUNTIME_IMAGE"
                else
                    log "runtime build FAILED: gemma/deepseek/orchestrator cannot start until it succeeds"
                fi
            fi
        fi
    fi

    # 3. One downloader script (all profiles) and one downloader unit template.
    install_downloader || true

    # 4. Per profile: install the unit, and start the download only if the
    # weights are still missing. The download runs as its own service, so this
    # script returns instead of waiting for tens of gigabytes.
    local requested="$PROFILES"
    case " $requested " in *" small "*) ;; *)
        # Keep the orchestrator available when its weights are already there.
        [ -f "$MODELS_DIR_SMALL/LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf" ] && requested="$requested small"
    ;; esac

    for p in flash gemma deepseek small; do
        case " $requested " in *" $p "*) ;; *) continue ;; esac
        u="$(unit_for "$p")"
        if [ -f "$PROF_DIR/$u.service" ]; then
            install_template "$PROF_DIR/$u.service" "$HOME/.config/systemd/user/$u.service"
            if [ "$p" = "small" ]; then
                log "$u.service installed (stopped; toggle with 'superfast-switch orchestrator on')"
            else
                log "$u.service installed (disabled until 'superfast-switch use $p')"
            fi
        else
            log "$PROF_DIR/$u.service missing; skipping the $p unit"
        fi
        if weights_complete "$p"; then
            log "$p: weights already complete"
        elif [ "${SKIP_WEIGHTS:-0}" = "1" ]; then
            log "$p: weights missing; SKIP_WEIGHTS set, so the downloader is only enabled"
            systemctl --user enable "superfast-download@$p.service" \
                || log "$p: could not enable the downloader; enable it later with: systemctl --user enable superfast-download@$p.service"
        else
            log "$p: weights missing; starting superfast-download@$p.service (keeps running after this script)"
            systemctl --user enable --now "superfast-download@$p.service" \
                || log "$p: could not start the downloader now; start it later with: systemctl --user start superfast-download@$p.service"
        fi
    done

    systemctl --user daemon-reload
    log "profiles prepared: $requested"
    log "switch between them with: superfast-switch use dense|flash|gemma|deepseek"
    log "the small router runs beside the active profile: superfast-switch orchestrator on|off"
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
    # Console tools, installed with the names the documentation uses:
    # `superfast-tui` (not superfast-tui.sh) and `superfast-gateway.py`, which
    # is the name the gateway unit above refers to.
    install_tool() { # src name
        if [ -f "$SCRIPT_DIR/../tools/$1" ]; then
            cp "$SCRIPT_DIR/../tools/$1" "$HOME/.local/bin/$2"
            chmod +x "$HOME/.local/bin/$2"
            log "installed ~/.local/bin/$2"
        else
            log "tools/$1 not found; skipping ~/.local/bin/$2"
        fi
    }
    install_tool superfast-tui.sh superfast-tui
    install_tool superfast-gateway.py superfast-gateway.py
    # Remove the older name, in case this machine was set up before.
    rm -f "$HOME/.local/bin/superfast-tui.sh"

    # The orchestrator unit is installed by phase 9 (deploy/profiles), so there
    # is only one copy of it. Install it here too if the small model is present
    # and phase 9 was skipped.
    if [ -f "$HOME/small-models/LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf" ] \
       && [ ! -f "$HOME/.config/systemd/user/orchestrator.service" ]; then
        install_template "$SCRIPT_DIR/profiles/orchestrator.service" \
            "$HOME/.config/systemd/user/orchestrator.service"
        log "orchestrator.service installed (stopped; toggle with superfast-switch orchestrator on)"
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
    # With every profile on loopback, the gateway is the only way in from the
    # network, so a machine with no key would be unreachable from the LAN. A
    # fresh setup therefore creates a key and enables the gateway. The key is
    # printed once here and can be read any time with
    # `superfast-switch api-key show`. Set SUPERFAST_NO_KEY=1 to skip this and
    # leave the machine loopback-only.
    if [ ! -s "$CONF_DIR/api.key" ] && [ "${SUPERFAST_NO_KEY:-0}" != "1" ]; then
        mkdir -p "$CONF_DIR"
        head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "$CONF_DIR/api.key"
        chmod 600 "$CONF_DIR/api.key"
        log "generated an API key; clients send: Authorization: Bearer <key>"
    fi
    if [ -s "$CONF_DIR/api.key" ]; then
        XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user enable --now superfast-gateway.service
        log "gateway enabled on :8741 (the only LAN path; key in $CONF_DIR/api.key)"
        log "API KEY: $(cat "$CONF_DIR/api.key")"
    else
        log "no API key: the machine is loopback-only. Create one with 'superfast-switch api-key set'."
    fi

    # GNOME Shell extension (control panel), if a GNOME session is present and
    # the extension is part of this checkout.
    if command -v gnome-extensions >/dev/null 2>&1 \
       && [ -d "$SCRIPT_DIR/../gnome-shell-extension" ]; then
        EXT_DIR="$HOME/.local/share/gnome-shell/extensions/superfast@graphene-lab"
        mkdir -p "$EXT_DIR"
        cp -r "$SCRIPT_DIR/../gnome-shell-extension/." "$EXT_DIR/"
        # Enable it when there is a session to talk to; over SSH or on a
        # headless run there is none, and the command would just fail.
        if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
           && gnome-extensions enable superfast@graphene-lab 2>/dev/null; then
            log "GNOME extension installed and enabled"
        else
            log "GNOME extension installed; enable it once with:"
            log "  gnome-extensions enable superfast@graphene-lab   (then log out and in once)"
        fi
    else
        log "gnome-extensions or gnome-shell-extension/ not found; skipping the desktop control panel"
    fi

    XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user daemon-reload
    log "console tools: superfast-tui (menu), superfast-switch (CLI)"
}

# Run one phase, unless ONLY names a different set of phases.
run_phase() {
    local name="$1"
    if [ -n "${ONLY:-}" ] && ! is_in "$ONLY" "$name"; then
        log "-- phase $name: skipped (ONLY=$ONLY)"
        return 0
    fi
    "phase_$name"
}

# The kernel parameters only take effect after a reboot, and an unattended run
# has nobody to type it. This installs a one-shot system unit that re-runs the
# remaining phases at boot and then removes itself. The phases it runs need no
# sudo: the firewall rules and lingering were already done before the reboot,
# the weights go to $HOME, the image is pulled by the user's rootless podman
# and the units are user units.
install_resume_unit() {
    local script; script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    local unit=/etc/systemd/system/superfast-setup-resume.service
    log "installing $unit: the setup continues by itself after the reboot"
    sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=SUPERFAST setup, resumed after the kernel-parameter reboot
After=network-online.target user@$UID_NUM.service
Wants=network-online.target user@$UID_NUM.service
ConditionPathExists=$script

[Service]
Type=oneshot
User=$TARGET_USER
WorkingDirectory=$(cd "$(dirname "$0")" && pwd)
Environment=UNATTENDED=1
Environment=SKIP_UPDATE=1
Environment="PROFILES=$PROFILES"
Environment="ONLY=weights image engine profiles ui_auth"
Environment=HOME=$HOME
Environment=XDG_RUNTIME_DIR=/run/user/$UID_NUM
TimeoutStartSec=infinity
ExecStart=/bin/bash $script
ExecStartPost=-/bin/systemctl disable superfast-setup-resume.service
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable superfast-setup-resume.service
    log "after the reboot, follow it with: journalctl -u superfast-setup-resume -f"
}

main() {
    # Refuse to run as root here, not only in phase 1: with ONLY=... a user can
    # select phases, and running them as root uses root's podman storage and
    # root's systemd (no user bus), which is not what this script configures.
    if [ "$(id -u)" -eq 0 ]; then
        echo "Run as the admin user, not root (rootless podman is used)." >&2
        exit 1
    fi
    run_phase os_check
    run_phase update
    run_phase sshd
    run_phase groups
    run_phase suspend_mask
    run_phase weights
    run_phase image
    [ "${SMOKE:-0}" = "1" ] && phase_smoke
    run_phase engine
    run_phase profiles
    run_phase ui_auth
    log "setup complete — profiles prepared: $PROFILES"
    log "start one with: superfast-switch use dense|flash|gemma|deepseek"
    log "control: superfast-tui (terminal) or the GNOME extension"
    if [ "$REBOOT_NEEDED" = "1" ]; then
        log "REBOOT REQUIRED: the shared-memory kernel parameters take effect only after a reboot."
        if [ "${UNATTENDED:-0}" = "1" ] || [ "${AUTO_REBOOT:-0}" = "1" ]; then
            install_resume_unit
            log "rebooting in 15 s; this session ends here and the setup continues by itself"
            sleep 15
            sudo systemctl reboot
            exit 0
        fi
        log "After rebooting, the large profiles (flash, deepseek) can load; check with:"
        log "  cat /proc/cmdline   # must show amdgpu.gttsize=118784 ttm.pages_limit=31457280"
        log "If PROFILES named more than dense, the other checkpoints were started in the"
        log "background and may still be downloading:"
        log "  systemctl --user list-units 'superfast-download*'"
    fi
}

main
