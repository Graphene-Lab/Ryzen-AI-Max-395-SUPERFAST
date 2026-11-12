#!/usr/bin/env bash
# bench-guard — run a benchmark only if the endpoint serves the model it asks for.
#
# llama.cpp serves whichever profile is loaded and ignores the "model" field of
# the request, so a forgotten `superfast-switch use` turns a run into a
# measurement of another model under the intended name, with no error anywhere.
# This wrapper asks /v1/models first and refuses to start on a mismatch.
#
#   bench-guard.sh ornith-1.5-122b -- ps-bench run --provider local \
#       --endpoint http://127.0.0.1:8731 --model ornith-1.5-122b
#
#   bench-guard.sh ornith-1.5-122b --base http://127.0.0.1:8731 -- python3 run.py ...
#
# Exit: 0 when the command ran, 1 when the served model was not the expected
# one (nothing is started), 2 on bad usage.
set -euo pipefail

BASE="${SUPERFAST_BASE:-http://127.0.0.1:8741/v1}"
KEY="${SUPERFAST_API_KEY:-$(cat "$HOME/.config/superfast/api.key" 2>/dev/null || true)}"

usage() { echo "usage: $0 <expected-model> [--base URL] -- <command...>" >&2; exit 2; }

[ $# -ge 3 ] || usage
want="$1"; shift
if [ "${1:-}" = "--base" ]; then
    BASE="${2%/}/v1"; shift 2
fi
[ "${1:-}" = "--" ] || usage
shift

served="$(curl -sS --max-time 10 -H "Authorization: Bearer $KEY" "$BASE/models" 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

if [ "$served" != "$want" ]; then
    echo "bench-guard: the endpoint serves '${served:-nothing}', not '$want'." >&2
    echo "bench-guard: switch the profile first (superfast-switch use <profile>), then rerun." >&2
    exit 1
fi

echo "bench-guard: '$served' is served, starting: $*" >&2
exec "$@"
