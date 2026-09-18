# Changelog

## Unreleased

### Added

- **`docs/REMOTE-ACCESS.md`, a step-by-step guide to reaching the machine from
  outside the network.** The case it covers is the common one: the machine has
  no public IP, because it sits behind a phone hotspot or a router you cannot
  configure, so no port can be forwarded to it and a DNS name has nothing to
  point at. It is written as a general procedure, with placeholders instead of
  any real machine, tailnet or address, and the steps are in the order that
  works the first time: install Tailscale, join the tailnet with a hostname that
  gives a stable address, enable HTTPS certificates in the console, add the
  `funnel` attribute to the policy, expose **only** the key-protected gateway,
  and point a client at `https://<machine>.<tailnet>.ts.net/v1`. It also carries
  the verification that matters (the machine resolves its own name through
  MagicDNS, so the public path has to be tested with `--resolve`) and a short
  section for the three things that can still stop it: a Funnel command that
  prints its reason and then waits, a public DNS record that is not published
  yet, and a network that rewrites DNS answers. The README links to it from the
  client-configuration section, described as an accessory rather than part of
  the local setup.
- **An encrypted-DNS recipe in that guide, and SSH over the same Funnel.** A
  network that intercepts DNS can answer for the Funnel name with something
  wrong, so the guide gives the commands that put the connecting computer on
  DNS-over-HTTPS (Cloudflare for Families, with the `add encryption` lines
  Windows needs for those addresses, `udpfallback=no` so nothing falls back to a
  plain query), the captive-portal exception, how to check the result and how to
  undo it. The guide also documents SSH through the same tunnel: port 22 cannot
  be exposed and a plain SSH client cannot connect, so the machine maps it with
  `--tls-terminated-tcp` — not `--tcp`, which looks right and does not work —
  and the client wraps SSH in TLS with `openssl s_client`, which Git for Windows
  already ships. It closes with the security shape all of this creates: the
  address is public, the API key is the lock, and an SSH mapping should be
  key-only and removed when it is not needed.
- **The README's client section records how to reach a profile two ways.** One
  entry per network, and the remote one needs a distinct `id`: entries are
  identified by `id` and `baseUrl`, while `-m` selects by `id` alone and would
  always find the first, leaving the picker as the only way to the second. The
  engine does not check the model name it receives, which is what makes a
  distinct `id` safe.
- **`UNATTENDED=1` (and `AUTO_REBOOT=1`) for `deploy/setup-fedora.sh`.** The
  installer already had no prompts, but two steps needed a human: the sudo
  password, and the reboot that the kernel memory parameters require — the
  reboot is also what makes the GPU groups effective. Unattended mode refuses
  to wait for anything: it requires passwordless sudo and says how to grant it,
  requires the script to be a file on disk, and when the kernel parameters are
  in place it installs a one-shot system unit
  (`superfast-setup-resume.service`), reboots after 15 s and continues the
  remaining phases at boot (weights, image, engine, profile units, tools),
  disabling itself at the end. `AUTO_REBOOT=1` is the same reboot handling
  without the rest of unattended mode. The script also enables the GNOME
  extension itself when there is a session to talk to, and points at the
  command to re-run when there is not.
- **`SKIP_WEIGHTS=1` and `SKIP_IMAGE=1`**, so a run on a machine that will not
  serve every profile does not fetch 275 GB of checkpoints or pull images it
  cannot use. The downloaders are still installed and enabled, and a skipped
  image is reported rather than silently missing. Both were added to run the
  installer on a Fedora 44 machine with no GPU (inside WSL on the development
  PC), which is what produced the fixes below.
- A **Quick install** section and a badge row at the top of the README, so the
  installer is the first thing a visitor sees.
- **A report path for a stopped installer.** `.github/ISSUE_TEMPLATE/` gains a
  form that asks for the three things that make a report fixable — the phase it
  stopped in, the error under it, and whether it was the half before or after
  the reboot — plus the `installer` label so those reports group together, and
  a `config.yml` that points everything else at the README. The script prints
  the prefilled URL itself from an `ERR` trap when a phase fails, while the log
  is still on screen. The README says plainly what is and is not validated: the
  guided path was run on the reference machine, the unattended path has not had
  its first fresh-host run, and installer breakage is treated as the top
  priority.
- **`superfast-monitor.py`, and the timer that runs it every 30 seconds.** The
  setup script installs it from `tools/`, with the two units in
  `deploy/profiles/`. It reads the engine's loopback `/health` and `/cache`,
  the GPU counters and the memory, and appends one line per sample to
  `~/.local/share/superfast-monitor/samples.jsonl`; `--report 24` prints what
  it collected. It exists because the engine's log says how long each request
  took but not how many were waiting, which is the difference between a slow
  answer and a queued one: `/health`'s `queued` is the field that separates the
  two, and reading its depth over time is what says whether the queue is the
  pool or the profile's slots. Read-only, no API key, and it exits 0
  with a message when no profile is serving, so an idle machine collects no
  failed units.
- **`tools/bench-concurrent.py`, and the measurements behind the shipped pool
  size.** `bench-serving.py` answers which drafter is faster and runs one
  request at a time; it cannot see what happens when several agents share the
  machine, which is the question this box gets asked. The new instrument fires
  N clients at once in two shapes — one whose reservations all fit any pool (so
  only slots can make a client wait) and one that asks for more positions than
  the image-default pool holds — and reports each request's wall clock next to
  the engine's own numbers for it. Making its own requests identifiable in a
  live engine's log took three attempts: counting log-tail lines attributes
  live agents' requests to the benchmark, and tagging with the non-speculative
  `serial` drafter hides the ledger lines entirely, so it fingerprints on a
  distinctive `max_tokens` plus the prompt length each client reports. The
  tables it produced, and the startup measurements they led to, are in the
  README under "Many agents at once".

### Changed

- **The recommended flash answer budget is 16,384, not 32,768.** This is the
  one client value that has to follow the server, and it follows from the pool:
  each request reserves `prompt + max_tokens` positions, so the answer budget
  decides how many long conversations stay resident. Four agents carrying
  150,000 tokens each reserve 665,536 positions with this budget and 731,072
  with 32,768, against a pool of 786,432. The client table, the JSON example
  and the derivation of the two timeout values were all built on the larger
  figure, so all three are updated. The timeouts themselves do not change: a
  smaller budget only makes their worst case smaller, and they are deliberately
  generous.
- **The pool's size is measured now, not argued.** The eight-client runs could
  not settle it: with eight clients against four slots both pools are exceeded
  at once and the slots decide. The shape that separates them is four clients at
  163,199 tokens each — 656K positions of reservations, above the fitted pool
  (524288) and below the shipped one (786432), with four clients against four
  slots so only the pool can matter. Measured 2026-09-13: 57.7 t/s aggregate
  with a warm cache on 786432 against 15.5 t/s on 524288, and the smaller pool
  had to re-prefill two of the four conversations from zero (the requests that
  lost their state paid 130 s of history again, and the four clients' wall
  clocks spread by 155 s instead of being identical). The pool does not show up
  as requests waiting for admission — `queued` never rose above zero in either
  arm — it shows up as conversations that lose their prompt cache, which is
  worth knowing before reading a `queued` of zero as spare capacity.
- **A start that does not complete now says why, in the installer and in the
  switch.** Both wait for `/health`, and both used to give up with one line that
  named a different failure ("engine not healthy in time") and left the cause to
  be worked out from the journal. The cause that matters here is not a slow load:
  after `model ready` the engine can livelock while it reserves its serving
  slots and spin at 80-90% of a core forever without ever listening, and no error
  is ever printed. When the wait expires, both tools now look for exactly that
  signature — `model ready` with no `prompt cache ON` after it — and print it
  with the engine's CPU, the pool the unit asks for, and the two remedies
  (lower `HALOGEN_KV_POOL_POSITIONS`, or reboot for unfragmented memory).

  There is a second way to hang, measured the same night after many profile
  restarts: the engine loads completely — `model ready`, `prompt cache ON`,
  uvicorn's `Started server process` — and then answers nothing while serving.
  The container's own watchdog catches that one (`this is a wedged engine and
  not a slow one`), kills it at 180 s and systemd restarts it, so it recovers —
  possibly into a loop. Both tools now recognise that case too and say what it
  is, because the remedies differ: the livelock never recovers by itself, and a
  reboot is what clears the host state the two have in common. The installer
  also verifies the opposite silent case after a successful start: it
  reads `/health` and compares the pool the engine armed with the pool the unit
  asks for, because `HALOGEN_KV_POOL_FIT=1` may fit it smaller — a request for
  1048576 came up as 524288 — and a machine quietly holding half the
  conversations its unit promises is a slow machine with no explanation.
- **The flash profile ships a 786,432-position KV pool instead of
  1,048,576.** With 1,048,576 and `HALOGEN_KV_POOL_FIT=0` — what this project
  shipped until tonight — the engine **stops starting** on a host that has been
  running for a while: it reaches `model ready`, prints `reserving 3 more
  serving slot(s)`, and then spins at 80-90% of a core forever without ever
  listening, with no error for anyone to report. Three attempts, three hangs;
  the startup log shows only 140-312 MiB of the engine's contiguous 2 MiB
  blocks left for three slots that want ~333 MiB, and the engine livelocks in
  the allocator instead of failing, so `Restart=on-failure` never fires and the
  machine simply stops serving. 786,432 started on all three attempts with the
  same arena and cache that ship beside it, and it holds four 150K-token
  conversations with a 16K answer budget — the shape an agent actually has.
- **Four slots stay four, and the pool is no longer described as a speed knob.**
  Measured with eight concurrent clients: halving the pool (786432 → 524288)
  changed nothing (33.8 against 35.5 t/s aggregate), because with more clients
  than slots it is the slots that decide. Eight slots raise aggregate
  throughput 20% (72.2 → 86.5 t/s) and lower every individual client's rate by
  20% (13.53 → 10.84 t/s), so the profile keeps four: an agent feels its own
  latency, not the fleet's aggregate.

### Fixed

- **The sampler cancelled `/cache` on a busy engine.** Its 15-second timeout
  was shorter than the time the endpoint can take while the engine is decoding
  — the handler waits behind the decoders — so every sample missed during a busy
  period made the engine log a `CancelledError` traceback for a request the
  client had already given up on. `/health` gets 60 s and `/cache` 120 s now,
  and a sample that still fails is recorded as missing rather than as an error.
- **The dense unit was the one unit `ONLY=profiles` did not refresh.** It was
  written by a heredoc in the engine phase, so the documented upgrade path —
  re-run the profiles phase to pick up changed engine settings — rewrote the
  flash, gemma, deepseek and orchestrator units and left `superfast.service`
  alone. A machine that followed that documentation kept a dense unit with no
  `HALOGEN_QUEUE_TIMEOUT` and no `HALOGEN_MAX_TOKENS_CAP` in it, while the
  text of the same documentation said those two are shipped explicitly; the
  reference host was in exactly that state. The dense unit now lives in
  `deploy/profiles/dense.service` and both phases install it from there, which
  also means a unit file is never generated by the shell that installs it —
  the same class of accident that once pasted a `superfast-switch status`
  listing into this unit's comments.
- **A machine could look installed and then fail with `cudaMalloc failed: out of
  memory`.** Phase 5 writes the shared-memory kernel parameters and cannot know
  whether they are in the running kernel; nothing checked afterwards, and the
  failure that follows looks like a GPU problem rather than a missing boot
  parameter. Every run now ends with the state in one line: ACTIVE, "written,
  not active yet (the next boot applies them)", or MISSING with the command to
  fix it. Verified on both machines: ACTIVE on the reference host, and
  "written, not active yet" on a kernel that never had them applied.
- **The dense unit the installer wrote was corrupted by the installer itself.**
  The heredoc that writes `superfast.service` is unquoted, and one of its
  comment lines contained `` `superfast-switch status` `` — a command
  substitution, which ran at install time and pasted its output into the file.
  On the reference machine that is how the dense unit came to carry a
  `superfast-switch status` listing in the middle of its comments, with two
  comment lines destroyed; systemd ignores the unknown keys, so it worked, and
  nobody noticed. The backticks are escaped now, and the trap below writes to
  stderr so a failing substitution can never be captured into a generated file.
  Found by running the installer on a machine without the switch on PATH.
- **The `ERR` trap that prints the report URL never fired.** Bash does not
  inherit an `ERR` trap into shell functions unless `-E` is set, and every phase
  is a function: the first real failure printed nothing. `set -eEuo pipefail`
  now.
- **A machine without `firewalld` stopped the install dead.** `firewall-cmd`
  missing (a container image, the WSL image) meant phase 3 exited and nothing
  else ran. The firewall rules are now attempted through a helper that warns
  clearly and continues — the rules matter, but they should not abort a run
  that can still configure everything else.
- **`video` and `render` missing made `usermod` fail.** Minimal images may not
  have the groups Fedora Workstation ships; phase 4 creates what is missing.
- **`SKIP_IMAGE` did not cover the GGUF runtime image**, so a run that meant to
  pull nothing sat downloading 3.7 GB in phase 9. It does now.
- **`superfast-switch use <profile>` did not enable the profile it started.**
  The setup script enables the dense unit and installs every other profile
  disabled, and it says so: "installed (disabled until 'superfast-switch use
  flash')". But `use` only stopped the others and started the one asked for, so
  the profile you picked served until the next reboot and then the machine came
  up on the profile that was still enabled — or, with two enabled, on whichever
  won the race for port 8731. `use` enables the profile it activates and
  disables its siblings now, so the choice survives a reboot.
- **Engine settings were documented, and shipped in `docker-compose.yml`,
  under a name no image reads.** The engines take `HALOGEN_*`; `SUPERFAST_*`
  appears nowhere in either image, so a value set that way is read by nobody
  and the engine silently keeps its default. The consequence was not cosmetic:
  `docker-compose.yml` set `SUPERFAST_BIND: 0.0.0.0`, so the engine bound
  `127.0.0.1` inside its own network namespace and the `api` container could
  never reach it — the two-container topology could not work as written. The
  same prefix was wrong throughout `docs/FLAGS.md`, the README, the vendored
  `deploy/entrypoint.sh` and the EULA. Entries below this one that mention a
  `SUPERFAST_*` engine setting are written under the old prefix; the engine
  name is the same word with `HALOGEN_` in front of it.

### Changed

- **DeepSeek-V4-Flash tool calling was measured, and it does not work in
  practice.** Three budgets were tried — 1,024, 2,048 and 8,192 tokens — and
  the model spent each of them thinking: at 8,192 it had written 6,123
  reasoning tokens with no tool call when the attempt was stopped after 22
  minutes, with the generation down to about 0.4 tokens per second and the
  machine using 105 GB of its 124 GB. The README now says to treat that profile
  as a long-context text model rather than an agentic one, instead of leaving
  the question open.
- **Every timeout is now computed, not chosen.** The profile units carry
  explicit request policy (`HALOGEN_QUEUE_TIMEOUT` 6000 s dense / 3600 s flash,
  `HALOGEN_MAX_TOKENS_CAP` 65536), and the llama.cpp units raise their socket
  timeout (`--timeout`, 600 s by default) to 1800 s for gemma and 3600 s for
  deepseek, whose 507,904-token worst-case prompt is 3,116 s of prefill during
  which the server sends nothing at all — measured. The README derives each
  number from the measured prefill and decode rates, the largest prompt the
  profile serves and the wait behind other requests, and the client entries use
  the results: `streamIdleTimeoutMs` and `timeout` per profile, up to
  8,400,000 ms and 10,800,000 ms on deepseek. Qwen Code's defaults are 4
  minutes of silence and 2 minutes per request, which cut every long turn on
  this machine.
- **The Flash-Next unit now sizes the KV pool for parallel agents.** A coding
  agent that opens subagents runs several conversations at once, and the image
  defaults hold two full-length conversations and eight resumable ones. The
  unit ships `HALOGEN_KV_POOL_POSITIONS=1048576`, `HALOGEN_KV_POOL_FIT=0`,
  `HALOGEN_MAX_TOK=16384` (the prefill arena: the pool only fits with it
  halved), `HALOGEN_KV_SLOTS=4`, `HALOGEN_CTX=262144` and
  `HALOGEN_CACHE_ENTRIES=32`.

  Measured on the reference host with four agents asking **at the same time**,
  each at 139,541 tokens of history: 560,000 positions of KV against the
  524,288 the image's pool holds. On the image defaults the follow-up turn
  takes 229.5 s — two of the four agents are served from cache (139,534 tokens,
  0.44 s) and the other two re-prefill their whole history (119.53 s and
  108.53 s). With this unit all four are served from cache and the whole turn
  takes 2.2 s. The pool is larger than the default by design; the README says
  what it costs in memory and how to step back to the image defaults or to a
  786432-position pool.

### Docs

- The README has a **Many agents at once** section: how the prefix cache
  behaves when several agents share the machine, why there is no cache key to
  send (`prompt_cache_key` is accepted and ignored, because the cache keys on
  the prefix), the measured before/after, and why the disk snapshot
  (`HALOGEN_CACHE_FILE`) is not the lever on unified memory. It opens with a
  plain-words explanation of what the engine remembers and what the minute-long
  pause was, and `docs/PLAIN-GUIDE.md` says the same in its own words under
  "Several helpers working at once".
- The README's setup steps now say how a machine installed before 2026-09-11
  picks these engine settings up: re-run the profiles phase.
- Two drafter files are documented with what was measured on 2026-09-11: the
  Gemma-4 MTP head fails to initialize (`Gemma4Assistant requires ctx_other to
  be set`) even though the runtime now has `--spec-draft-model` and
  `--spec-type draft-mtp`, and the DeepSeek DSpark drafter is still refused
  (`unknown model architecture`). The plain guide no longer says the Gemma
  profile can read images: every profile is text only, as the README said.
- `docs/FLAGS.md` now separates the engines' `HALOGEN_*` settings from this
  project's own `SUPERFAST_*` tooling variables, names which image honours
  each one, and documents the pool, its constraints (at least the context, a
  multiple of 256, at most 16777216) and the prompt-cache entries.
- The client configuration section now gives the values **per profile** in one
  table (`id`, context window, answer budget, `temperature`, `extra_body`)
  instead of asking the reader to derive them. It also says why the dense
  budget is smaller than the flash one: the budget and the client's 15-minute
  stream limit interact, and 32,768 tokens at dense speed takes longer than
  that limit allows. The Gemma and DeepSeek entries in a client need
  `temperature: 0`, because those two profiles declare no sampling default of
  their own.

## 0.1.3

A serving bug-fix release. **The kernels, the checkpoint format and the weights
are unchanged**, so every performance and quality number still stands and your
weights do not need re-downloading. Upgrading is a container pull.

**Greedy output is unchanged**, and that was measured rather than assumed: the
golden fixtures produce byte-identical output on 0.1.3 and 0.1.2, same
filtered hashes and same token ids. If you run with `temperature: 0` — the
default — this release changes nothing about what the model says.

**Streamed replies do change, and that is the point of the second fix below.**
The leading blank line is gone. If you have a workaround that trims it, you
can drop it.

### Fixed

- **`/v1/completions` returned a 500 on every request — in 0.1.0, 0.1.1 and
  0.1.2, every release there has ever been.** The endpoint was listed in this
  README and reported by `/health` the whole time. Internally it read a set of
  sampling settings that had been added to the chat endpoint's request model
  and never to its own, so the first thing it touched raised an error and the
  request came back as an opaque "internal error". It now works, greedy and
  sampled, and rejects out-of-range values the same way the chat endpoint does.

  If you tried this route and concluded the server was broken, it was, and
  only for this route. `/v1/chat/completions` was unaffected.

- **A streamed reply and a non-streamed reply to the same prompt came back
  slightly different.** Asking with `"stream": true` returned the answer with a
  leading blank line the non-streamed form did not have, and the reasoning
  differed by leading or trailing whitespace. The model generated exactly the
  same tokens either way; the two response builders disagreed about tidying
  them, and only one of them was trimming.

  One case was more than cosmetic: on a turn where the model called a tool and
  said nothing else, the non-streamed `content` was `""` and the streamed
  `content` was a blank line, so a client testing "did the model say anything
  as well as calling the tool" got different answers depending only on how it
  had asked.

- **The engine accepted no new connections while it was serving.** It handles
  one client at a time by design — the API front-end opens a single socket and
  multiplexes every request over it — but that meant once the front-end
  connected, nothing else was ever accepted. The kernel completes a few extra
  connections into a backlog without the engine's involvement, and that backlog
  was four, so a handful of connection attempts succeeded and every one after
  them hung for the life of the process.

  Measured on 0.1.2 with a session held: connections one to five succeed, six
  onward time out, and the engine never recovers. The engine now accepts and
  queues connections while a session is running — including during a long
  generation, which on the default serial path can be over an hour — and serves
  the queue before asking for a new connection.

  If you healthcheck the engine port directly, or run anything else that opens
  a second connection to it, this is the fix for it. The `docker-compose.yml`
  in this repository does not healthcheck that port, so a stock deployment
  would not have shown a symptom.

- **A cancelled request that had not started yet was not actually cancelled.**
  Cancellation searched the requests that were running but never the queue, so
  a client that disconnected before its request began still had it generated in
  full, into a slot nobody was reading. This only applies with
  `SUPERFAST_KV_SLOTS` above 1, where a queue exists. It now costs nothing.

- **The front-end could open several connections to the engine at once, and
  strand the requests already using the old one.** It reopens the connection
  when it closes, every request checks that condition, and the reopen was not
  serialised — so a connection that dropped with work in flight raced all of
  the waiting callers into opening their own. Measured: six concurrent callers,
  six connections. Each extra one leaked the previous socket, started a second
  reader on the same stream, and replaced the table of in-flight requests
  underneath requests still using them.

### Added

- **`/health` now lists the endpoints the running build serves**, generated
  from the routing table so it cannot name a route that is not there. This
  exists because of the first fix above: nothing anywhere listed which routes
  were supposed to work, so a published route could be dead for three releases
  with nothing to notice it. The release gate now reads that list and probes
  every route on it, and fails on a route it has no probe for.

## 0.1.2

A sampler bug-fix release. **The kernels, the checkpoint format and the weights
are unchanged**, so every performance and quality number still stands and your
weights do not need re-downloading. Upgrading is a container pull.

**Greedy output is byte-identical to 0.1.1.** If you run with `temperature: 0`
— the default — nothing about this release changes what you get. Every fix
below is on the sampled path, and each one changes sampled output for the
better, so a sampled request will not reproduce a 0.1.1 result even with the
same seed.

### Fixed

- **`top_p` very close to 1.0 silently kept every token.** At about `0.9998` or
  higher the nucleus cut never triggered, so the request was served as though
  no `top_p` had been set at all — a 200, with the setting quietly doing
  nothing. Values further from 1.0 were unaffected, which is why this went
  unnoticed: our own test cases stopped at `0.99`.
- **`presence_penalty`, `frequency_penalty` and `logit_bias` were ignored when
  speculative decoding was active.** That is the default configuration, so in
  practice these three settings did nothing on most sampled requests. The
  request returned 200 with no indication the setting had been dropped. They
  now apply on every path, including mid-round: a token penalized by something
  the model just emitted is penalized before the next tokens are scored.
- **A rounding gap in the sampler could repeat the previous token.** In rare
  cases a draw landed in a gap that belonged to no candidate, and the token
  that came out was the one before it. This was most visible as an occasional
  stutter in sampled output.

### Changed

- `/health` reports the sampler's behavior under `sampling`, including which
  fields are implemented and which are rejected rather than ignored.

### If you used sampling on 0.1.1

Requests that set `top_p` above ~0.9998, or that set `presence_penalty`,
`frequency_penalty` or `logit_bias`, were served with those settings partly or
wholly inactive. They were not errors and nothing in the response said so, so
output that looked insufficiently constrained or unusually repetitive was
likely this rather than your configuration. There is no workaround on 0.1.1
for the penalty fields under the default drafter; pull 0.1.2.

## 0.1.1

A bug-fix release. **The engine is unchanged**: no kernel, no checkpoint, no
format change, so every performance and quality number below still stands and
**your weights do not need re-downloading**. The image carries no weights and
the mount layout is the same, so upgrading is a container pull and nothing else.

### Fixed

- **A default request could come back empty.** `max_tokens` defaulted to 512
  while the chat template defaults `reasoning_effort` to `xhigh`, and reasoning
  tokens count against the budget. A request that ran out before the model
  finished thinking returned `finish_reason: "length"` with an **empty
  `content`** and the whole reply in `reasoning_content`, which most OpenAI
  clients do not display. The default is now **8192**.
- **`max_completion_tokens` and `max_output_tokens` were silently ignored.**
  They were not declared, so a client using the current OpenAI Chat Completions
  field name had it dropped without an error and got the default no matter what
  it asked for. The budget was reachable only under the deprecated `max_tokens`.
  All three names are now accepted and mean the same thing. Send one, or send
  several as long as they agree; two different values is a 400 rather than a
  guess.

### Changed

- `SUPERFAST_MAX_TOKENS_CAP` **16384 to 65536**, so a long reasoning problem is
  not cut off by server policy. `SUPERFAST_QUEUE_TIMEOUT` **2400 to 7200** with
  it: the two are coupled, and a cap that outlasts the timeout makes one long
  request 503 everyone queued behind it. At the xhigh decode rate a full-length
  request is about 109 minutes, which is where 7200 comes from.
- `/health` now reports `max_tokens_default` and `token_budget_aliases`, so a
  client can read which spellings this server accepts instead of guessing.

### If you saw poor output on 0.1.0

Check `finish_reason` on a reply that looked wrong. `"length"` with an empty or
truncated `content` was this bug, and it was not your configuration. Either pull
0.1.1, or stay on 0.1.0 and pass `"max_tokens": 8192` explicitly, which is the
only spelling 0.1.0 reads.

## 0.1.0


First public release. Container image only; the engine is closed source.

### Fixed
- **The quickstart commands now say `podman run`, not `docker run`.** They
  always carried `--group-add keep-groups`, which is a Podman keyword: Podman
  intercepts it and keeps the caller's supplementary groups, while Docker
  resolves `--group-add` names against the container's `/etc/group` and fails
  with `unable to find group keep-groups`. Every command in this project is
  tested under Podman, so the published `docker run` form had never been run.
  The README and `docker-compose.yml` now show the Podman form and give the
  Docker substitution (`--group-add video --group-add render`, or
  `group_add: ["video", "render"]`).

### Added
- OpenAI-compatible endpoint: `/v1/chat/completions`, `/v1/completions`,
  streaming, tool calling, sampling with seeds, reasoning-effort control.
- Native 262,144-token context.
- Three selectable drafters — `dflash2` (default), `mtp`, `serial` — all
  producing byte-identical output.
- Prompt cache: ~20x time-to-first-token on a follow-up turn at 32K, and warm
  answers are byte-identical to cold ones by construction.
- Batched decode: 8 concurrent sequences, 4.87x aggregate, each byte-identical
  to running alone. OFF by default (`SUPERFAST_KV_SLOTS=1`), and currently
  mutually exclusive with speculative decoding — a single user is better off
  with the default.
- `bench` and `sweep` modes in the image, so throughput claims can be checked
  without our cooperation and without any fixture download.

### Measured
- Prefill: 620 t/s (pp512), 710 (pp2048), 566 (pp32768), all over HTTP with
  the bundled `sweep`.
- Decode over HTTP, ten prompt shapes, greedy: dflash2 31.71 t/s mean
  (20.8-44.2), serial 10.58.
- Ships full W4A4 promotion (all 400 i4l planes): +8.96% pp32K measured ABBA
  on the shipped checkpoint, decode unharmed, against about -0.45 pt top-1
  aggregate. This is the one default whose emitted tokens differ from the
  engine's built-in default; it does not affect spec-equals-serial,
  warm-equals-cold or batched-equals-solo. One env var rolls it back.
- Batch-1 decode runs at 249 GB/s against a measured 240 GB/s ceiling — the
  hardware wall, not a tuning target.

### Known limits
- gfx1151 only, by construction. The build rejects every other architecture.
- Text only; the model's vision encoder is not used.
- Unassisted (non-speculative) decode is slower than lower-precision engines,
  which is a deliberate precision choice — see `docs/QUANT.md`.
- A genuinely cold 262K prompt is a multi-minute prefill. The prompt cache
  makes the second turn fast, not the first.
- Speculation and batching cannot currently be used together. Enabling slots
  raises aggregate throughput but drops each stream to serial speed.
- Configuration is by environment variable only; there is no config file.
