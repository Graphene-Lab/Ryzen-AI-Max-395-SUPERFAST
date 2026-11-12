# Vision (image input)

Vision lets the machine **read pictures**, not just text. You send an image
along with your question — the same way you would to a cloud service — and the
model looks at it and answers. On this project vision is **on by default** for
the models that can carry it: the setup installs the vision drop-in active for
`gemma`, `ornith` and `ornith122`, so the machine you get after setup can
already read images. Set `VISION_DEFAULT=0` at setup to keep a text-only
machine instead.

This page explains how vision works on the machine this project prepares: which
models can see, what turning it on actually does, what it costs in memory, how
to call it over the API, and how it behaves with the prompt cache while a chat
is in progress.

## Which models can see

Three of the four profiles carry an image encoder:

| profile | model | encoder file | size |
|---|---|---|---|
| `gemma` | Gemma-4-26B-A4B | `mmproj-BF16.gguf` | 1,194,828,256 B (~1.1 GiB) |
| `ornith` | Ornith-1.5-35B-A3B | `mmproj-Ornith-1.5-35B-BF16.gguf` | 902,822,016 B (~861 MiB) |
| `ornith122` | Ornith-1.5-122B | `mmproj-Ornith-1.5-122B-BF16.gguf` | 912,263,200 B (~870 MiB) |

The optional **deepseek** (DeepSeek-V4-Flash) has no image encoder in its
repository: it is text-only, and the vision control is unavailable for it
(greyed out in the panel, refused by the CLI). **ornith122** (Ornith-1.5-122B)
is the one profile whose projector does not come from the same repository as
its weights: the base model has an encoder, the MXFP4 quant ships none, so the
setup fetches `mmproj-Ornith-1.5-122B-BF16.gguf` from `ornith-ai/Ornith-1.5-122B-GGUF`
and downloads it with the profile.

## What turning it on actually does

The encoder file is **downloaded at setup** together with its profile and is
**loaded by default** (unless you set `VISION_DEFAULT=0`). The engine reads the
encoder path only once, at startup: all three profiles run llama.cpp, and the
drop-in passes `--mmproj` pointing at the projector file.

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

A projector that cannot load stops the server before it ever answers, so the
switch does not leave the machine down: after waiting for `/health` it
**removes the override and restarts the profile text-only**, so the machine
keeps serving. You get a clear message in the log rather than a silent outage.

## Memory: the extra is not cumulative

The three vision files together look like ~3 GiB, but they are **never all in
memory at once**, because only one profile runs at a time. Turning vision on
adds the encoder to whichever profile is already running:

- gemma + projector: the ~1.1 GiB projector sits on top of the running gemma
  profile, which is about 23 GB at its 262,144-token window;
- ornith + projector: the ~861 MiB projector sits on top of the running ornith
  profile, which is about 25 GB at the same window;
- ornith122 + projector: the ~870 MiB projector sits on top of the running
  ornith122 profile, which is about 75 GB.

None pushes the machine into memory pressure: the largest profile,
Ornith-1.5-122B, is 75 GB resident and still leaves about 45 GB of the 124 GB
pool — 44 GB with its projector loaded. The projectors are never stacked,
because the profile that would carry the second one is not running.

## Turning it on and off

From the command line (works over SSH too):

```bash
superfast-switch vision on     # load the projector; restarts the profile
superfast-switch vision status # supported=yes|no, enabled=yes|no, and the active profile
superfast-switch vision off    # back to text-only
```

`status` reports three things: whether the **running** profile can carry vision
at all (`supported`), whether it is currently **enabled**, and which profile is
active. On deepseek it reads `supported=no`, so you always know whether a
toggle would even apply.

On the desktop the same control is the **Vision** switch in the GNOME panel
menu:

- on **deepseek** it is greyed out and labelled "Vision (not on this model)" —
  never clickable;
- on **gemma**, **ornith** and **ornith122** it toggles on and off;
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

The engine downsizes an image larger than the resolution it accepts, and image
dimensions are handled in multiples of 32. The model name to put in the request
is the one `/health` reports (`gemma-4-26b-a4b` or `ornith-1.5-35b-a3b`).

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

In practice: a repeated identical image request reuses the cached prompt
(`cached_tokens` on the image prefix), and a text chat running alongside image
requests keeps its own cache entries untouched.

## Verified on this machine

The flow was exercised end-to-end on the prepared host, on all three profiles:

- `vision on` → the engine came back healthy with the projector loaded (no
  hang, no rollback);
- an image sent through the gateway `:8741` with the Bearer key returned a
  correct description of the picture — on gemma the panel menu labels of a real
  screenshot were read back exactly, on ornith the same was verified on a real
  screenshot;
- on ornith122 the projector was added on 2026-11-12 (the MXFP4 quant ships
  none, so it came from the base model's GGUF repository): the engine logged
  `loaded multimodal model` and transcribed a rendered page containing a random
  code exactly, `R7QM-4821-ZX`, in 5 s with a 280-token prompt;
- `vision off` → the override was removed and the profile came back
  text-only.

So the toggle works both ways and the remote image path works with
authentication. By default the machine comes up with vision already on for
`gemma`, `ornith` and `ornith122`; `VISION_DEFAULT=0` gives a text-only machine
you can turn on later.
