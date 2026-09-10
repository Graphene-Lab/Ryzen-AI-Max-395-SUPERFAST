#!/bin/bash
# download-weights.sh <dense|flash|gemma|deepseek|small>
#
# Downloads one profile's weights into its own directory. Installed by
# deploy/setup-fedora.sh as ~/.local/bin/superfast-downloads/download-weights.sh
# and started by superfast-download@<profile>.service, so the transfer keeps
# running after the setup script returns, and resumes after a reboot.
#
# Four rules, all of them learned the hard way on the reference host:
#   1. resume with `curl -C -`, which continues at the exact byte offset. Do
#      not use `hf download` for the large files: its transport stalls on slow
#      links, and its resume starts the file over because the server rotates
#      the file tag between runs.
#   2. one writer per file. Two downloaders on the same file produced a
#      corrupted checkpoint once, so this script takes a lock in the target
#      directory and exits if another copy is running.
#   3. the mirror sometimes ignores the Range header and appends the whole
#      file again, which makes the file longer than expected. The script cuts
#      those extra bytes off and continues, instead of starting over.
#   4. the SHA-256 published by Hugging Face is checked before the final
#      rename. A mismatch deletes the file and downloads it again, so a
#      damaged transfer is never installed.
set -u

PROFILE="${1:-}"
case "$PROFILE" in
    dense)    DIR="__DENSE_DIR__";    TOKENIZER=1 ;;
    flash)    DIR="__FLASH_DIR__";    TOKENIZER=1 ;;
    gemma)    DIR="__GEMMA_DIR__";    TOKENIZER=0 ;;
    deepseek) DIR="__DEEPSEEK_DIR__"; TOKENIZER=0 ;;
    small)    DIR="__SMALL_DIR__";    TOKENIZER=0 ;;
    *) echo "usage: $0 dense|flash|gemma|deepseek|small" >&2; exit 2 ;;
esac

LOG="$DIR/.download.log"
mkdir -p "$DIR"
exec 9>"$DIR/.download.lock"
flock -n 9 || { echo "$PROFILE: another downloader is already running"; exit 0; }
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# name|expected size in bytes|sha256|url
#
# Not listed on purpose: the DeepSeek DSpark drafter. It is built for the
# Ember runtime and llama.cpp refuses it ("unknown model architecture:
# 'deepseek4-dflash-draft'"), so downloading it would waste 10.9 GB.
files() {
    case "$PROFILE" in
        dense)
            echo "qwen3.8-27b-p1w4d-d2.hgn|35865565184|274c3fc767fb57faf025dd03c76376b1fc1b32448aef45aaf02d1898fa962089|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b/resolve/main/qwen3.8-27b-p1w4d-d2.hgn"
            ;;
        flash)
            echo "qwen38-flash-next-w4b.hgn|124068083904|9c116bbc01f77b7a15464c1a124eb3325b286089b8a2a6f2856c9b246a235bd6|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-w4b.hgn"
            echo "qwen38-flash-next-w4b.overlay.hgn|2477677120|737d6bdaef274d3cc22de5bc265b390b89db5fb1e709f58db75287fdc35bb276|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-w4b.overlay.hgn"
            echo "qwen38-flash-next-w4b.overlay-speed.hgn|2383306048|113d77358107549fa22e06643ae3a524908aa7ea011afaebec69fc5f1991c370|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-w4b.overlay-speed.hgn"
            ;;
        gemma)
            echo "gemma-4-26B-A4B-it-Q4_0_ROCMFP4_COHERENT.gguf|14439364064|76559759aee76a4a29f233f3279c4470ce2c47c206fac3ec60f33d00e3daecdb|https://huggingface.co/kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF/resolve/main/gemma-4-26B-A4B-it-Q4_0_ROCMFP4_COHERENT.gguf"
            echo "mtp-gemma-4-26B-A4B-it-Q8_0.gguf|461766816|6326fb9f5e487aa8dcdd313a091e3c67724cb2a666ec3b7d2895b5b26d93ed1b|https://huggingface.co/kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it-Q8_0.gguf"
            ;;
        deepseek)
            echo "DeepSeek-V4-Flash-0731-Abliterated-ROCMFPx-Strix-Lean-2.58bpw.gguf|91547243200|a936e0a514385c8ae964c0f42263a4314a34fbc6efea9d9aced5320f320a3d54|https://huggingface.co/otheru/DeepSeek-V4-Flash-Strix-Halo-GGUF/resolve/main/DeepSeek-V4-Flash-0731-Abliterated-ROCMFPx-Strix-Lean-2.58bpw.gguf"
            ;;
        small)
            echo "LFM2.5-350M-Q4_K_M.gguf|229312224|7e6f72643caafc9a68256686638c4d7916f2cec76d1df478d4c3ddcd95a6aed4|https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/resolve/main/LFM2.5-350M-Q4_K_M.gguf"
            echo "LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf|730898432|6f071c4f5893ca93a265613a0009f4db745bc79b50808ab1ce9a8821caf511d0|https://huggingface.co/Nichonauta/LFM2.5-1.2B-Thinking-ToMoE-GGUF/resolve/main/LFM2.5-1.2B-Thinking-ToMoE-Q4_K_M.gguf"
            ;;
    esac
}

get() { # url name wanted_bytes sha256
    local url="$1" name="$2" want="$3" sha="$4"
    local final="$DIR/$name" part="$DIR/$name.part"
    local stalls=0
    if [ -f "$final" ] && [ "$(stat -c %s "$final")" -eq "$want" ]; then
        log "$name: already complete"
        return 0
    fi
    while true; do
        local before s got
        before=$(stat -c %s "$part" 2>/dev/null || echo 0)
        timeout 300 curl -sL -C - --max-time 290 -o "$part" "$url" || true
        s=$(stat -c %s "$part" 2>/dev/null || echo 0)
        if [ "$s" -gt "$want" ]; then
            log "$name: overshoot $s > $want, cutting back to $before"
            truncate -s "$before" "$part" 2>/dev/null || rm -f "$part"
            stalls=$((stalls + 1))
            if [ "$stalls" -ge 3 ]; then
                # The mirror keeps ignoring the Range header, so resuming cannot
                # make progress. Start the file over: a request without a Range
                # header is always honoured, so the transfer moves forward.
                log "$name: resume ignored three times, starting the file over"
                rm -f "$part"
                stalls=0
            fi
            sleep 5
            continue
        fi
        if [ "$s" -eq "$want" ]; then
            if [ -n "$sha" ]; then
                got=$(sha256sum "$part" | cut -d' ' -f1)
                if [ "$got" != "$sha" ]; then
                    log "$name: SHA-256 mismatch (got $got), starting the file over"
                    rm -f "$part"
                    continue
                fi
                log "$name: SHA-256 verified"
            fi
            mv -f "$part" "$final"
            log "$name: complete ($s bytes)"
            return 0
        fi
        log "$name: $s / $want"
        sleep 20
    done
}

tokenizer() { # repo base url (flat tokenizer/, five small files)
    local base="$1"
    mkdir -p "$DIR/tokenizer"
    for f in chat_template.jinja merges.txt tokenizer_config.json tokenizer.json vocab.json; do
        [ -s "$DIR/tokenizer/$f" ] && continue
        until curl -sfL --max-time 120 -o "$DIR/tokenizer/$f" "$base/tokenizer/$f"; do
            log "tokenizer/$f: retry"
            sleep 30
        done
        log "tokenizer/$f: ok"
    done
}

log "=== $PROFILE: started ==="

if [ "$TOKENIZER" = "1" ]; then
    case "$PROFILE" in
        dense) tokenizer "https://huggingface.co/peonist-ai/halogen-qwen3.8-27b/resolve/main" ;;
        flash) tokenizer "https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main" ;;
    esac
fi

files | while IFS='|' read -r name size sha url; do
    [ -n "${name:-}" ] || continue
    get "$url" "$name" "$size" "$sha"
done

touch "$DIR/.download-complete"
log "=== $PROFILE: all files complete ==="
