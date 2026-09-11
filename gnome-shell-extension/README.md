# SUPERFAST GNOME Shell extension

A small control panel for the machine: pick which model profile is serving,
toggle the small orchestrator, and see at a glance what is running. It is a
thin wrapper around the `superfast-switch` command, so anything you set here
is the same state you see over SSH.

## Install

```bash
# from a clone of the repository, on the machine itself:
gnome-extensions install --force ./gnome-shell-extension
gnome-extensions enable superfast@graphene-lab
```

Then log out once and back in (GNOME Shell only loads extensions at login).
If the extension is not listed, check:

```bash
gnome-extensions list | grep superfast
gnome-extensions info superfast@graphene-lab
```

For development, copy the folder to
`~/.local/share/gnome-shell/extensions/superfast@graphene-lab/` and use the
`Looking Glass` console (`Alt+F2`, type `lg`) to `enable`/`disable` it.

## What the menu does

- **Serving:** which model currently answers (loopback on port 8731; from the
  LAN it is the gateway on port 8741).
- **Model:** activate `dense`, `flash`, `gemma` or `deepseek` (one at a time).
- **Orchestrator:** on/off for the small fast router on port 8732.
- **API key:** turn LAN access on or off, copy the key to the clipboard,
  generate a new key, or clear it. On = the gateway on port 8741 answers, and
  only with `Authorization: Bearer <key>`. Off = the gateway is stopped and
  there is no access from the network at all, because every profile binds its
  port to loopback on the host.
- **Open terminal menu:** launches the text interface (`superfast-tui`) in the
  first terminal emulator found on the machine, in this order: `ptyxis`,
  `gnome-terminal`, `kgx`, `xterm`, `konsole`. The order matters: Fedora 44
  ships **Ptyxis** and does not install `gnome-terminal` at all, so a
  hardcoded `gnome-terminal` would simply fail on the reference machine — which
  is how this was found.

It performs no network calls of its own: every action goes through the local
CLI, and the menu re-reads the real state on each refresh. After a profile
change it refreshes itself for about a minute, because a profile takes from a
few seconds (dense) to a minute and a half (deepseek) to load.
