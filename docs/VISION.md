# Vision (image input)

Vision lets the machine **read pictures**, not just text. You send an image
along with your question — the same way you would to a cloud service — and the
model looks at it and answers. On this project vision is **on by default** for
the models that can carry it: the setup installs the vision drop-in active for
`flash` and `gemma`, so the machine you get after setup can already read
images. Set `VISION_DEFAULT=0` at setup to keep a text-only machine instead.

This page explains how vision works on the machine this project prepares: which
models can see, what turning it on actually does, what it costs in memory, how
to call it over the API, and how it behaves with the prompt cache while a chat
is in progress.

## Which models can see

Two of the four profiles carry an image encoder:

| profile | model | encoder file | size |
|---|---|---|---|
| `flash` | Qwen3.8-Flash-Next | `qwen38-flash-next-vision.hgn` | 897,916,416 B (~856 MiB) |
| `gemma` | Gemma-4-26B-A4B | `mmproj-BF16.gguf` | 1,194,828,256 B (~1.1 GiB) |

The other two — **dense** (Qwen3.8-27B) and **deepseek** (DeepSeek-V4-Flash) —
have no image encoder in their repositories. They are text-only, and the vision
control is unavailable for them (greyed out in the panel, refused by the CLI).

## What turning it on actually does

The encoder file is **downloaded at setup** together with its profile and is
**loaded by default** (unless you set `VISION_DEFAULT=0`). The engine reads the
encoder path only once, at startup:

- flash: the `HALOGEN_VISION_TOWER` environment variable points the engine at
  the tower file;
- gemma: the server is started with `--mmproj` pointing at the projector file.

Because that read happens at startup, **turning vision on or off restarts the
profile** — there is no way to bolt the encoder onto a running engine. The
restart also **clears that profile's prompt cache**, so a conversation that was
warm goes cold. This is the one rule to remember: **toggle vision between
conversations, not in the middle of one.**

Mechanically the toggle is a systemd drop-in. Setup stages the prepared drop-in
under `~/.config/superfast/vision/` and, by default, also installs it **active**
into the unit's override directory
(`~/.config/systemd/user/<unit>.d/override.conf`), so the profile starts with
vision. `superfast-switch vision off` removes that override and restarts the
unit; `vision on` puts it back. With `VISION_DEFAULT=0` the setup only stages
the drop-in and leaves the override out, so the machine comes up text-only and
you turn vision on yourself.

### It rolls itself back if the engine does not come up

The flash engine reserves a large contiguous block of memory at startup, and
that allocator is tight. If loading the tower ever left the engine unable to
come back healthy, the switch does not leave the machine down: after waiting for
`/health` it **removes the override and restarts the profile text-only**, so
the machine keeps serving. You get a clear message in the log rather than a
silent outage.

## Memory: the extra is not cumulative

The two vision files together look like ~2 GiB, but they are **never both in
memory at once**, because only one profile runs at a time. Turning vision on
adds the encoder to whichever profile is already running:

- flash + tower: the ~856 MiB tower sits on top of the running flash profile;
- gemma + projector: the ~1.1 GiB projector sits on top of the running gemma
  profile.

Measured on this host: with the flash profile at its then-shipped
**786,432-position KV pool** (the unit ships 655,360 today), turning vision on
brought the engine back healthy — the tower fits.
This is the same pool that already fixed the earlier startup hang (at the old
1,048,576-position pool the base profile could not even start; see the
project's notes on the block allocator). With flash and its tower loaded the
machine still had roughly **75 GiB available**, so the toggle does not push the
box into memory pressure and does not stack the two profiles' vision memory.

If you ever lower the KV pool for other reasons, the tower still needs its
~856 MiB of contiguous room; the switch's rollback covers the case where it
does not fit.

## Turning it on and off

From the command line (works over SSH too):

```bash
superfast-switch vision on     # load the tower (flash) / projector (gemma); restarts the profile
superfast-switch vision status # supported=yes|no, enabled=yes|no, and the active profile
superfast-switch vision off    # back to text-only
```

`status` reports three things: whether the **running** profile can carry vision
at all (`supported`), whether it is currently **enabled**, and which profile is
active. On dense or deepseek it reads `supported=no`, so you always know
whether a toggle would even apply.

On the desktop the same control is the **Vision** switch in the GNOME panel
menu:

- on **dense** and **deepseek** it is greyed out and labelled
  "Vision (not on this model)" — never clickable;
- on **flash** and **gemma** it toggles on and off;
- while a restart is in flight the switch is **locked** (as are the model
  items), so you cannot start a second change on top of one already running.

## Using it from the API

Once vision is on, send an image the standard OpenAI way: a content part with
an `image_url` carrying the bytes as a **base64 data URI**. Plain `http(s)`
image URLs are refused — the bytes must travel with the request. Through the
gateway (the only LAN path), with the API key:

```bash
curl -s http://<machine-ip>:8741/v1/chat/completions \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<model-name-from-/health>",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "What is in this image?"},
        {"type": "image_url",
         "image_url": {"url": "data:image/png;base64,'"$(base64 -w0 pic.png)"'"}}
      ]
    }]
  }'
```

Limits, reported by `/health`:

- **`max_pixels`** — the largest accepted image, 3,686,400 by default on
  flash. Larger images are downscaled to fit.
- **`size_multiple`** — image dimensions are handled in multiples of 32.

The model name to put in the request is the one `/health` reports (for flash,
`halogen-qwen3.8-flash-next`).

## Vision and the prompt cache, mid-chat

A common worry: what happens to an ongoing text chat if image requests arrive
while it is running? It is safe, and no special handling is needed:

- The prompt cache is keyed on the **token prefix**. An image request and a text
  conversation have different prefixes, so they keep **separate cache entries**
  and never collide.
- The encoder is a **single shared component**. If several images are prefilled
  at once they **serialize** on it — that adds latency under heavy concurrent
  image load, but it is not a correctness problem.
- **Text-only requests never touch the encoder**, so the text bitwise-identical
  guarantees are completely unaffected by vision being on.

In practice: a repeated identical image request was observed to reuse the
cached prompt (`cached_tokens` on the image prefix), and a text chat running
alongside image requests kept its own cache entries untouched.

## Verified on this machine

The flow was exercised end-to-end on the prepared host:

- `vision on` → `/health` reported `vision.enabled: true`, the engine came back
  healthy with the tower loaded at the 786,432-position pool it shipped then (no
  hang, no rollback; the unit ships 655,360 today);
- an image sent through the gateway `:8741` with the Bearer key returned a
  correct description of the picture (a red circle and a blue square, with
  their positions);
- `vision off` → the override was removed and the profile came back
  text-only (`vision.enabled: false`).

So the toggle works both ways and the remote image path works with
authentication. By default the machine comes up with vision already on for
`flash` and `gemma`; `VISION_DEFAULT=0` gives a text-only machine you can turn
on later.
