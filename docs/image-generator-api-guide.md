# Accessing the Image Generator via API

The SUPERFAST host (Fedora, Ryzen AI Max+ 395) runs an image generator next to
the language-model profiles. It is **Ideogram 4** through
[`stable-diffusion.cpp`](https://github.com/3M15/superfast-stable-diffusion)
(the `sd-server` binary), packaged as the container `localhost/superfast-image:1`.

It is **not** a language profile: it does not take `:8731`, does not load in
place of a model, and stays off unless the loaded profile leaves it room. It is
started and stopped through `superfast-switch`, then driven over plain HTTP.

---

## 1. Turn it on

From any machine that reaches the host, flip the switch:

```powershell
ssh -F "NUL" -i "C:\Users\andre\.ssh\id_ed25519" -o ConnectTimeout=15 user@192.168.43.253 \
  "superfast-switch image on"
```

Response:

```
image generator on :8733
```

The service `superfast-image.service` comes up on the loopback and listens on
`127.0.0.1:8733`. It only runs when the current profile has RAM headroom
(24 GB peak budget; the gate on `ornith122` is 75 GB).

Check the state any time:

```powershell
ssh -F "NUL" -i "C:\Users\andre\.ssh\id_ed25519" user@192.168.43.253 \
  "superfast-switch image check"
```

Example output:

```
image: supported=yes desired=off peak=24 free=89 runtime=ok profile=ornith
```

- `supported=yes` — the generator is installed and the host has room.
- `desired=off/on` — the remembered choice.
- `peak` — GB the generator would peak at.
- `free` — free RAM when the switch was last run.
- `profile` — the currently loaded model.

## 2. Drive it over HTTP

The generator speaks the **Automatic1113 / ComfyUI** extension API
(`sdapi/v1/...`). The text-to-image endpoint is `txt2img`:

```powershell
curl -s -o image.png -X POST \
  'http://127.0.0.1:8733/sdapi/v1/txt2img' \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "a red cube on a wooden table, studio light",
    "steps": 4,
    "width": 1024,
    "height": 1024
  }'
```

- The body is JSON; `prompt` is a free-form natural-language prompt (Ideogram
  reads language, not tags).
- `steps` from 4 to ~8 — Ideogram 4 converges in very few steps.
- `width` / `height` up to 2048.
- The response body **is the PNG** (HTTP 200). Redirect it to a file with `-o`.

### Timing and status

To check only the status/size without saving the bytes, use `-w`:

```powershell
curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' \
  -X POST 'http://127.0.0.1:8733/sdapi/v1/txt2img' \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"a red cube on a wooden table, studio light","steps":4,"width":1024,"height":1024}'
```

Output:

```
HTTP 200 in 51.41s
```

A 1024×1024, 4-step render on this host returns in roughly **50-76 s**
(depending on RAM pressure) as a single HTTP 200 with a valid PNG. A 2048×2048
render never completes — the resolution itself is the limit, not time or RAM.

### A note on `width`/`height`

Ideogram 4 wants square, power-of-two-ish canvases. Stick to 1024×1024 or the
larger supported sizes; non-standard aspect ratios or 2048px will not close.

## 3. Turn it off

When done, remember the choice so the gate is honored on the next switch:

```powershell
ssh -F "NUL" -i "C:\Users\andre\.ssh\id_ed25519" user@192.168.43.253 \
  "superfast-switch image off"
```

Response:

```
image generator off (choice remembered)
```

`superfast-switch image check` then reports `desired=off`.

---

## Summary

| Step | Command | Result |
| --- | --- | --- |
| Start | `superfast-switch image on` | service up on `:8733` |
| State | `superfast-switch image check` | supported / peak / free / profile |
| Render | `curl -o out.png POST :8733/sdapi/v1/txt2img` | HTTP 200, PNG in body |
| Stop | `superfast-switch image off` | choice remembered, service down |

The generator is a companion to the LLM profiles, not one of them. Start it,
hit `txt2img` with a natural-language prompt and small `steps`, save the PNG
from the HTTP 200 body, and turn it off when finished.
