# A desktop on the machine, from anywhere

The other guide in this folder, [Remote access from
anywhere](REMOTE-ACCESS.md), brings you the API and an SSH shell. This one brings
you the **graphical desktop**, for the times when a shell is not enough: a
setting to change, a window to look at, a file manager.

It uses **GNOME Remote Desktop over RDP**, reachable **only from your
tailnet**. Nothing is published on the internet, and nothing is exposed on your
local network.

Placeholders used below:

| placeholder | meaning |
|---|---|
| `<machine>` | the name of this machine in the tailnet |
| `<user>` | the Linux user the desktop session belongs to |
| `100.x.y.z` | the machine's tailnet address, from `tailscale ip -4` |

## Why RDP goes over the tailnet, and not through the Funnel

Three facts decide this, and each one rules something out.

1. **The Funnel cannot carry RDP.** Funnel serves only `443`, `8443` and
   `10000`, and only for clients that speak TLS first. RDP always begins with a
   plain-text negotiation before it upgrades to TLS, so a normal RDP client
   cannot talk to a Funnel port. It would need a TLS wrapper running on the
   viewing computer.
2. **SSH port forwarding is not available here.** A tunnel through SSH would
   avoid the wrapper, but on Fedora, SELinux denies the SSH session process the
   right to open any outgoing connection, so `ssh -L` fails with
   `channel 2: open failed: connect failed`. This happens on the local network
   too, so it is not about Tailscale: it is the host's own policy. Widening that
   policy would weaken a sandbox for every SSH session.
3. **The tailnet needs neither.** A connection inside the tailnet is a normal
   TCP connection over WireGuard, so RDP works as it does on a local network,
   and only members of your tailnet can reach it.

So the design is: RDP listens on the machine, the firewall allows it on the
tailscale interface only, and the viewing computer needs the Tailscale client.

## Remote Login, not desktop sharing

GNOME offers two things, and they are not the same:

- **Desktop Sharing** shares a session that is already open on the screen. It
  needs someone logged in at the console.
- **Remote Login** (the *system* instance of the service) creates a session when
  you connect. It works on a machine with nobody at the keyboard, which is the
  usual case for a machine that runs a model all day.

This guide configures **Remote Login**.

## Steps

The commands run **on the machine**, as your normal user, with `sudo` where
shown.

### 1. Give the service a TLS certificate

RDP requires TLS. A self-signed certificate is enough here: the connection is
inside the tailnet, and your RDP client will show one warning that you can
accept.

```bash
sudo mkdir -p /etc/gnome-remote-desktop
sudo openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
     -subj "/CN=$(hostname)" \
     -out /etc/gnome-remote-desktop/rdp.crt \
     -keyout /etc/gnome-remote-desktop/rdp.key
```

**Then hand both files to the user the service runs as.** This is the step that
stops people: the daemon runs as the user `gnome-remote-desktop`, so a key that
only root can read makes the daemon start and never listen, with one line in its
log that reads `RDP TLS certificate and key not yet configured properly`.

```bash
sudo chown gnome-remote-desktop:gnome-remote-desktop /etc/gnome-remote-desktop /etc/gnome-remote-desktop/rdp.crt /etc/gnome-remote-desktop/rdp.key
sudo chmod 600 /etc/gnome-remote-desktop/rdp.key
sudo chmod 644 /etc/gnome-remote-desktop/rdp.crt
```

### 2. Configure and enable Remote Login

```bash
sudo grdctl --system rdp set-tls-cert /etc/gnome-remote-desktop/rdp.crt
sudo grdctl --system rdp set-tls-key  /etc/gnome-remote-desktop/rdp.key
sudo grdctl --system rdp set-port 3389
sudo grdctl --system rdp set-auth-methods credentials
sudo grdctl --system rdp set-credentials <user> <password>
sudo grdctl --system rdp enable
sudo systemctl enable --now gnome-remote-desktop.service
```

`grdctl --system` talks to the service, which also prints
`Init TPM credentials failed … using GKeyFile as fallback` on machines without a
usable TPM. That line is harmless: the credentials are stored in a file instead.

The password above is the RDP password, not the system password of the user.
Change it later with the same `set-credentials` command.

### 3. Let the tailnet in, and keep the local network out

The RDP service listens on all interfaces, so the firewall decides who reaches
it. Give the tailscale interface a zone of its own:

```bash
sudo firewall-cmd --permanent --new-zone=tailnet
sudo firewall-cmd --permanent --zone=tailnet --add-service=ssh
sudo firewall-cmd --permanent --zone=tailnet --add-service=rdp
sudo firewall-cmd --permanent --zone=tailnet --add-interface=tailscale0
sudo firewall-cmd --reload
```

After this, RDP answers tailnet members, and the interfaces on your local
network keep the desktop zone, which does not allow `rdp`. SSH stays allowed in
both, so nothing that worked before stops working.

### 4. Verify on the machine

```bash
grdctl --system status          # RDP: enabled, port 3389, certificate set
ss -tln | grep 3389             # must show a listener
tailscale ip -4                 # the address you will connect to
```

## Connect

On the computer you want to see the desktop from:

1. Install the **Tailscale client** and sign in to the same tailnet. This is the
   one thing RDP cannot avoid, and it is the price of not publishing a desktop
   port on the internet.
2. Open an RDP client (`mstsc` on Windows, Remmina or `xfreerdp` on Linux,
   Microsoft Remote Desktop on macOS) and connect to `<machine>` or to
   `100.x.y.z`, user `<user>` and the RDP password.
3. Accept the certificate warning: the certificate is self-signed.

The connection creates a **new** session for the user. The screen at the machine
stays where it was, at the login screen or on whatever it was showing.

## If something does not work

**The service runs but nothing listens on 3389.** Read its log:

```bash
journalctl -u gnome-remote-desktop -n 30
```

`RDP TLS certificate and key not yet configured properly` means step 1: the
certificate and the key must be readable by the user `gnome-remote-desktop`.

**A tailnet peer cannot connect while SSH to the same machine works.** Look at
the zone of the tailscale interface:

```bash
sudo firewall-cmd --get-zone-of-interface=tailscale0
sudo firewall-cmd --zone=tailnet --list-services
```

It must be `tailnet`, and that zone must list `rdp`.

**The connection is refused from the local network.** That is the intent: the
zone used by your Wi-Fi and cable interfaces does not allow `rdp`. If you want
the desktop on the local network as well, add the service to that zone:

```bash
sudo firewall-cmd --permanent --zone=FedoraWorkstation --add-service=rdp
sudo firewall-cmd --reload
```

## Security

- **Nothing is published.** RDP is not mapped through the Funnel, and the local
  network cannot reach it. Only tailnet members can, and they must authenticate.
- **Credentials are the service's own**, set with `grdctl`, not the user's system
  password. RDP negotiates NLA, so the credentials are checked before any
  session starts.
- **View only, if that is all you need.** `sudo grdctl --system rdp
  enable-view-only` removes remote control of keyboard and mouse.
- **Turn it off** with `sudo grdctl --system rdp disable` and `sudo systemctl
  disable --now gnome-remote-desktop.service`.
- **A desktop costs GPU time.** The session draws and encodes on the same
  integrated GPU the model uses, so expect the model to slow down while you use
  the desktop. Close the session when you are done.
