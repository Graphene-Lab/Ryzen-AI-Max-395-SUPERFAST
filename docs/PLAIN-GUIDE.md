# SUPERFAST — the plain-language guide

This page explains the project without assuming you are an engineer. The full
technical README is next to it; this is the friendly version.

## What this is

SUPERFAST turns one small desktop computer — an AMD machine with a Ryzen AI
Max processor (the same family used in some mini-PCs and laptops) — into a
private artificial-intelligence server. The AI models run on that computer,
not in someone else's cloud. You talk to them through a standard interface
that many apps already understand.

Think of it as owning a very good assistant instead of renting one:

- it works without an internet connection,
- nothing you type leaves your house,
- there is no monthly bill and no usage limit.

## What you need

- The computer with the AMD Ryzen AI Max processor, 128 GB of memory.
- A USB stick of at least 8 GB to install Fedora Workstation 44 (the Linux
  system we recommend — see the main README for why).
- Patience for the first setup: the models are large files (tens of
  gigabytes) and download once.

## What the machine gives you

Several "models" live on the machine, and you pick one at a time:

- **Qwen3.8-27B (dense)** — the careful, high-quality model. Best answers,
  slower (about 21 words per second).
- **Qwen3.8-Flash-Next (MoE)** — a bigger, newer model that works differently
  and is much faster.
- **Gemma-4-26B (MoE, FP4)** — very fast (about 57 words per second). Text
  only, like the others.
- **DeepSeek-V4-Flash** — a very large model (284 billion parameters) for
  coding and hard problems. It is the **slowest** of the four (about 11 words
  per second), it needs a large answer budget, and it requires two kernel
  settings on the machine, which the setup script applies.
- **The orchestrator** — a tiny, very fast model that acts like a dispatcher:
  it reads simple requests and answers or routes them immediately, so the big
  model is not woken up for trivial work. It is a bit like the conductor of an
  orchestra, or a good office manager who looks busy but mostly decides who
  does what.

All of them answer on the same address, so nothing on your side has to change
when you switch.

## The five-minute version

1. Install Fedora Workstation 44 on the machine (the README has the steps).
2. Connect to it once over SSH (a cable or your home network is fine).
3. Run one script: it updates the system, downloads the models, sets up the
   services and installs a small desktop control panel (a GNOME extension).
   On a fresh machine the first run stops after a few minutes and tells you to
   log out and back in once: that is what gives your user access to the
   graphical processor. Run the same script again and it finishes the job.
4. Open the control panel (or the terminal menu) and choose which model to
   use.
5. Point any OpenAI-compatible app at `http://<machine>:8741` and send the API
   key (read it with `superfast-switch api-key show`). On the machine itself,
   `http://127.0.0.1:8731` needs no key.

## Everyday use

- The desktop control panel (or `superfast-tui` in a terminal) lets you pick
  the model, turn the orchestrator on or off, and turn the API key on or off.
  When it is on, a stranger on your network cannot use your machine without the
  key; when it is off, nobody on the network can use it, only you on the
  machine itself.
- You can do all of it over SSH as well; the terminal tool has a simple
  `help`.

## Several helpers working at once

A coding assistant can open **subagents**: several small helpers working on
different tasks at the same time. The machine sees them as several
conversations at once, and it keeps in memory the beginning of every
conversation it has already read, so the next turn does not read it again.

That memory has a fixed size. With the size the engine picked on its own, it
held about four conversations of 131,000 tokens. When the conversations grew
past that, the engine had to forget one conversation to keep another, and the
helper whose conversation was forgotten read its whole history again. That is
the pause of a minute or more.

The flash profile now reserves room for four long conversations. Measured on
this machine with four helpers working together, each with about 140,000
tokens of history:

- **before:** the second turn took 229 seconds, and two of the four helpers
  read everything again (120 and 109 seconds each);
- **after:** the second turn takes 2 seconds, and all four answer from memory.

Short conversations were never a problem, and one helper alone is not affected
either. The full numbers are in the main README, under "Many agents at once".

## Honest notes

- **A long answer is never cut by a timeout.** While the machine reads a long
  prompt it sends nothing at all, and reading the longest prompt a profile
  accepts can take up to 52 minutes on the largest model. Every timeout is
  therefore computed from those worst cases, on the machine and in the client
  settings, and the main README shows the arithmetic under "Timeouts, and why
  they are what they are".
- A few settings are about avoiding an AI bad habit: some models can "think"
  for too long and loop. The main README explains the defaults we ship and
  why, in the same plain style.
- The first time you load a very large model can take a minute or two.
- Numbers that describe this machine are measured on it. Where the document
  quotes figures from somebody else (a model vendor, or another project), it
  says so next to the table.
