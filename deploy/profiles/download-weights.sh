#!/bin/bash
# download-weights.sh <dense|flash|gemma|ornith|ornith122|deepseek|small>
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
    flash)    DIR="__FLASH_DIR__";    TOKENIZER=0 ;;
    gemma)    DIR="__GEMMA_DIR__";    TOKENIZER=0 ;;
    deepseek) DIR="__DEEPSEEK_DIR__"; TOKENIZER=0 ;;
    ornith)   DIR="__ORNITH_DIR__";   TOKENIZER=0 ;;
    ornith122) DIR="__ORNITH122_DIR__"; TOKENIZER=0 ;;
    small)    DIR="__SMALL_DIR__";    TOKENIZER=0 ;;
    *) echo "usage: $0 dense|flash|gemma|ornith|ornith122|small" >&2; exit 2 ;;
esac

LOG="$DIR/.download.log"

# This file is a TEMPLATE: the directories arrive as __..._DIR__ placeholders
# that deploy/setup-fedora.sh substitutes while installing it. Running the
# template itself would create a directory literally named __DENSE_DIR__ in the
# current working directory, so refuse instead of leaving that behind.
case "$DIR" in
    *__*DIR__*)
        echo "this is the template copy of the downloader, not the installed one." >&2
        echo "Install it first (bash deploy/setup-fedora.sh), then run" >&2
        echo "~/.local/bin/superfast-downloads/download-weights.sh <profile>." >&2
        exit 2 ;;
esac

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
            # llama.cpp Vulkan engine with --ple-disk: three shards of the
            # STRIX_LEAN quant plus the MTP draft head. The GGUF carries its
            # own tokenizer, so TOKENIZER is 0 for this profile.
            echo "Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-00001-of-00003.gguf|44944112832|7d5fc36da007b45fabe58537e96486df5a5d7629558fbe94888d5e0dd2086a7f|https://huggingface.co/pugant/Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-GGUF/resolve/main/ROCmFP4-STRIX_LEAN/Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-00001-of-00003.gguf"
            echo "Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-00002-of-00003.gguf|44688348576|05ce892c44b38f7cbdb3d5a48ebcce9cc4a956786c3a96f02f24c45bd9232954|https://huggingface.co/pugant/Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-GGUF/resolve/main/ROCmFP4-STRIX_LEAN/Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-00002-of-00003.gguf"
            echo "Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-00003-of-00003.gguf|16121070688|7551add986ac6a46bc69cab644b8fc64313d79ad06423e1f7e0544f87ced74aa|https://huggingface.co/pugant/Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-GGUF/resolve/main/ROCmFP4-STRIX_LEAN/Qwen3.8-Flash-Next-Q4_0_ROCMFP4_STRIX_LEAN-00003-of-00003.gguf"
            echo "Qwen3.8-Flash-Next-MTP-Q8_0-HEAD-ROCMFP4.gguf|3818043776|fa30a89fa06cd1bcc40810dcf1fed73d69c5ff33afb2a08b76333c6f9629ea34|https://huggingface.co/pugant/Qwen3.8-Flash-Next-MTP-DRAFT-HEAD-ROCMFP4-GGUF/resolve/main/Qwen3.8-Flash-Next-MTP-Q8_0-HEAD-ROCMFP4.gguf"
            # Vision projector: the STRIX_LEAN quant ships none, so without this
            # file the vision drop-in would point at nothing. Downloaded always,
            # loaded only when that drop-in is active.
            echo "mmproj-Flash-Next-F16.gguf|904004000||https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/mmproj-F16.gguf"
            ;;
        gemma)
            echo "gemma-4-26B-A4B-it-Q4_0_ROCMFP4_COHERENT.gguf|14439364064|76559759aee76a4a29f233f3279c4470ce2c47c206fac3ec60f33d00e3daecdb|https://huggingface.co/kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF/resolve/main/gemma-4-26B-A4B-it-Q4_0_ROCMFP4_COHERENT.gguf"
            echo "mtp-gemma-4-26B-A4B-it-Q8_0.gguf|461766816|6326fb9f5e487aa8dcdd313a091e3c67724cb2a666ec3b7d2895b5b26d93ed1b|https://huggingface.co/kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it-Q8_0.gguf"
            # Vision projector (mmproj): downloaded always so the toggle can
            # use it without a second wait, but NOT loaded unless the vision
            # drop-in is active (superfast-switch vision on). ~1.1 GiB.
            echo "mmproj-BF16.gguf|1194828256|41926ed5f1403cf5add23b0684992805ea6f97253096132e769e65646b8cef9d|https://huggingface.co/kingjones777/Gemma-4-26B-A4B-it-ROCmFP4-GGUF/resolve/main/mmproj-BF16.gguf"
            ;;
        deepseek)
            echo "DeepSeek-V4-Flash-0731-Abliterated-ROCMFPx-Strix-Lean-2.58bpw.gguf|91547243200|a936e0a514385c8ae964c0f42263a4314a34fbc6efea9d9aced5320f320a3d54|https://huggingface.co/otheru/DeepSeek-V4-Flash-Strix-Halo-GGUF/resolve/main/DeepSeek-V4-Flash-0731-Abliterated-ROCMFPx-Strix-Lean-2.58bpw.gguf"
            ;;
        ornith)
            # 19.05 GB, Apache-2.0, 4.29 bits per weight, 262144 native context.
            # The MTP head is inside the same file (a nextn block), so there is
            # no second draft file to fetch. The mmproj is downloaded always so
            # the vision toggle can use it without a second wait, but it is not
            # loaded unless the vision drop-in is active.
            echo "Ornith-1.5-35B-A3B-ROCmFP4.gguf|19052438944|0f907917a1bfe4e0ca0d281e5709dcf34b6277063e94fab29491bb5c80fda696|https://huggingface.co/julianmb/Ornith-1.5-35B-A3B-ROCmFP4-GGUF/resolve/main/Ornith-1.5-35B-A3B-ROCmFP4.gguf"
            echo "mmproj-Ornith-1.5-35B-BF16.gguf|902822016|d9ce31026d1cb1f3f8d5152e2e2a014d9d2b302b6c93a7dc07bb0a0487f52837|https://huggingface.co/julianmb/Ornith-1.5-35B-A3B-ROCmFP4-GGUF/resolve/main/mmproj-Ornith-1.5-35B-BF16.gguf"
            ;;
        ornith122)
            # 69.7 GB, MIT, ~4.45 bits per weight, 262144 native context, MTP
            # head inside the same file (mtp_num_hidden_layers = 1). No mmproj
            # here: the quant repo ships none, so the profile is text-only
            # until the projector is added from the base model's repo.
            echo "Ornith-1.5-122B.MXFP4_MOE.gguf|69666316288|38c3a1dfc6c21fd8ff5f060312474aef2c3f9cd549282ddd5225ceca712461da|https://huggingface.co/prithivMLmods/Ornith-1.5-122B-MXFP4_MOE-MTP/resolve/main/Ornith-1.5-122B.MXFP4_MOE.gguf"
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
