# superfast flags

There is no config file. Two kinds of setting exist, and they belong to
different owners.

## The engines: command-line flags, not environment

Every profile runs a llama.cpp server, and its settings are flags written into
its unit file in `deploy/profiles/`: `-c` (context window), `--parallel`
(slots), `-ub` (ubatch), `-ctk`/`-ctv` (KV cache type), `--mmproj` (the vision
projector), `--chat-template-kwargs` (reasoning on/off) and, for the models
that carry one, the MTP speculative-decoding set (`-md`, `--spec-type
draft-mtp`, `--spec-draft-n-max`, `--spec-draft-ngl`). Per-profile values and
the reasons behind them are in
[`deploy/profiles/README.md`](../deploy/profiles/README.md); the measured
numbers are in the main README.

### Measured: what the flags do at 60k

Five runs of the 35B on a separate port, one flag changed at a time, the same
60,016-token prompt and a cold cache each time (2026-11-12):

| run | prefill |
|---|---|
| shipped flags (f16 KV, `-ub 512`, Flash Attention `auto`) | **831 t/s** |
| `--flash-attn on` | 820 t/s (−1%, noise: `auto` already resolves to on) |
| `-ub 1024` | 785 t/s (−5%) |
| `-ub 256` | 728 t/s (−12%) |
| `-ctk q8_0 -ctv q8_0 --flash-attn on` | 619 t/s (−25%) |

Only the last line changed a decision. The same comparison on the 122B gives
220 t/s with q8_0 against 268 with f16, so that profile moved to the f16 cache
and pays about 3 GiB for it. The batch size and an explicit Flash Attention buy
nothing: the defaults are already the best of the three, and FA is on.

The `HALOGEN_*` family — the environment variables of the dense engine — went
away on 2026-11-07 with that profile and its image. A `HALOGEN_*` name now
reaches nothing, and `docker-compose.yml` no longer exists.

## This project's own variables

`SUPERFAST_*` names are read by our scripts, never by the engines.

| flag | default | meaning |
|---|---|---|
| `SUPERFAST_API` | `http://127.0.0.1:8731` | Endpoint the bundled benchmarks target. |
| `SUPERFAST_API_LOG` | *(unset)* | Path to a teed front-end log, so the serving benchmark can read throughput counters from inside a container. |
| `SUPERFAST_ROOT`, `SUPERFAST_PROMPTS`, `SUPERFAST_API_CTR` | *(derived)* | Benchmark inputs: the image's tool directory, the prompt fixture, the container whose log the counters are read from. |
| `SUPERFAST_PORT`, `SUPERFAST_ORCH_PORT` | `8731`, `8732` | Ports the switch and the TUI probe. |
| `SUPERFAST_GEMMA_DIR`, `SUPERFAST_DEEPSEEK_DIR`, `SUPERFAST_ORNITH_DIR`, `SUPERFAST_ORNITH122_DIR`, `SUPERFAST_ORCH_DIR` | `~/gemma-models`, `~/deepseek-models`, `~/ornith-models`, `~/ornith122-models`, `~/small-models` | Where each profile's weights live. |
| `SUPERFAST_*_UNIT` | `gemma.service`, `ornith122.service`, … | Override the systemd unit a profile maps to. |
| `SUPERFAST_GATEWAY_PORT`, `SUPERFAST_KEY_FILE` | `8741`, `~/.config/superfast/api.key` | The API-key gateway. |
| `SUPERFAST_API_KEY` | *(client side)* | The key the client sends as `Authorization: Bearer …`. `envKey` in the client entry names this variable. |
| `SUPERFAST_NO_KEY` | `0` | `1` makes the installer skip creating an API key. |
| `SUPERFAST_RUNTIME_IMAGE`, `SUPERFAST_RUNTIME_PUBLISHED`, `SUPERFAST_RUNTIME_PUBLISHED_EXTRA` | the published tags | Installer overrides: which runtime image to pull, and where to look for it before building from `runtime/`. |
| `SUPERFAST_PEAK_GB`, `SUPERFAST_2K_GB`, `SUPERFAST_SYSTEM_RESERVE_GB` | `24`, `32`, `10` | The image generator's memory gate. |
| `PROFILES`, `ONLY`, `MODELS_DIR_*` | `gemma ornith ornith122 small` | Installer phase selection and weight locations. |
