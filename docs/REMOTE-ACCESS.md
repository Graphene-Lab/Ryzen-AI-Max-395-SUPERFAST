# Reach the machine from outside the network

This guide is for one situation: the machine has no public IP address, and you
want to use it from a computer on another network.

That is the normal case for a machine at home. If it is behind a phone hotspot
or a router you cannot configure, no port can be forwarded to it, and nothing on
the internet can open a connection to it.

A DNS name alone does not solve this. A name only points to an address, and the
machine has no address the internet can reach.

What solves it is a tunnel that **the machine opens itself**, in the outbound
direction. Clients connect to the public address of the tunnel, and the tunnel
carries the traffic back to the machine. The router is not involved.

This guide uses **Tailscale Funnel**. The computers that connect need nothing
installed: any client that speaks HTTPS works. Follow the steps in order, and
the setup works the first time.

Placeholders used below:

| placeholder | meaning |
|---|---|
| `<machine>` | the name you give this machine in the tailnet |
| `<tailnet>` | the name of your tailnet, chosen by Tailscale at sign-up |
| `<port>` | the local port of the service you expose |
| `<key>` | the API key of the gateway, from `superfast-switch api-key show` |
| `<user>` | the Linux user you log in as |

## What Funnel gives, and what it costs

| | |
|---|---|
| client on the connecting computer | **none** — the Funnel address is a normal HTTPS address |
| address | `https://<machine>.<tailnet>.ts.net`, stable, so it does not change when the network changes |
| ports | only `443`, `8443` and `10000` |
| protocol | HTTPS, and TLS-terminated TCP. Funnel never forwards a plain connection: the client speaks TLS and the machine decrypts it |
| path | through Tailscale's relay servers, with bandwidth limits that cannot be configured |
| exposure | **public**: anyone on the internet can reach the address, so the API key is the lock |
| cost | the free Personal plan (a few users, unlimited devices) |

Why a tunnel that carries TCP is the right tool for this engine: a tunnel that
proxies HTTP can cut a response that stays silent. Cloudflare's proxy, for
example, waits about 125 seconds for the origin and then returns error 524; the
6000-second limit is Enterprise only. This engine sends **nothing** while it
prefills a long prompt, and a long prompt takes minutes. Funnel carries a
TLS-terminated TCP stream, so that silence is not a problem.

If you prefer nothing to be public, see [the private
alternative](#the-private-alternative-a-client-on-every-device) at the end.

## Requirements

- Tailscale 1.38.3 or later on the machine.
- MagicDNS enabled for the tailnet.
- HTTPS certificates enabled, with a certificate for the tailnet name.
- A `funnel` node attribute in the tailnet policy.

## Steps

The commands run **on the machine**, as your normal user, with `sudo` where
shown.

### 1. Install Tailscale and start the service

On Fedora and RHEL:

```bash
sudo dnf install -y tailscale
sudo systemctl enable --now tailscaled
tailscale version
```

On Debian and Ubuntu the package comes from Tailscale's own repository:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
tailscale version
```

### 2. Join the tailnet

```bash
sudo tailscale up --hostname=<machine>
```

The command prints a link, for example `https://login.tailscale.com/a/…`, and
then waits. Open the link in a browser on any computer, sign in, and approve the
machine. The command finishes by itself when the login is complete.

- Sign in with the account you will use to administer the tailnet. The first
  login creates the tailnet if you do not have one.
- `--hostname` sets the name that appears in the address, so the address becomes
  `https://<machine>.<tailnet>.ts.net`.
- The command is not stuck: it is waiting for the browser step.

### 3. Enable HTTPS certificates

Open <https://console.tailscale.com/admin/dns> and, under **HTTPS
Certificates**, select **Enable HTTPS**. Confirm the warning: the machine name
and the tailnet name are published in a public certificate log.

Check it from the machine:

```bash
sudo tailscale cert --cert-file=/tmp/cert.crt --key-file=/tmp/cert.key <machine>.<tailnet>.ts.net
openssl x509 -in /tmp/cert.crt -noout -subject -issuer -enddate
```

A valid certificate means this step is done. If the request answers
`500 Internal Server Error: your Tailscale account does not support getting TLS
certs`, HTTPS certificates are not enabled yet: it is a missing toggle, not a
plan problem.

### 4. Allow Funnel in the policy

Run the Funnel command once. If the tailnet does not allow it yet, the command
prints the exact link to enable it:

```bash
sudo tailscale funnel --bg --https=443 http://127.0.0.1:<port>
```

```
Funnel is not enabled on your tailnet.
To enable, visit:

        https://login.tailscale.com/f/funnel?node=…
```

Open that link and enable Funnel for the node. In the console the same setting is
under **Access controls** → **Funnel** → **Add Funnel to policy**, which adds
this to the policy file:

```json
"nodeAttrs": [
  { "target": ["autogroup:member"], "attr": ["funnel"] }
]
```

Check the machine has the capability:

```bash
tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["CapMap"])'
```

The output must contain `funnel`, and a `funnel-ports` entry that includes `443`.

### 5. Expose the gateway

Expose the gateway, which asks for the API key:

```bash
sudo tailscale funnel --bg --https=443 http://127.0.0.1:8741
tailscale funnel status
```

Expected:

```
https://<machine>.<tailnet>.ts.net (Funnel on)
|-- / proxy http://127.0.0.1:8741
```

Do not expose the engine port (8731). It is bound to loopback for a reason and
has no authentication of its own. The gateway on 8741 is the only service meant
for remote clients.

### 6. Point the client at the new address

Use `https://`. Funnel accepts TLS only, so `http://` does not work:

```json
"baseUrl": "https://<machine>.<tailnet>.ts.net/v1",
"envKey": "SUPERFAST_API_KEY"
```

Keep the two timeouts from the [client
table](../README.md#recommended-client-configuration-qwen-code-or-any-agentic-client),
because a long prefill can be silent for minutes.

## Verify it

From a computer that has **no** Tailscale client installed:

```bash
curl -s https://<machine>.<tailnet>.ts.net/v1/models \
     -H "Authorization: Bearer <key>"
```

The answer is the model list, for example `halogen-qwen3.8-flash-next`.

Then check that a long prefill survives the public path. The machine resolves its
own name inside the tailnet, so force the public address to test the relay:

```bash
curl --resolve <machine>.<tailnet>.ts.net:443:<public-ip> \
     -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer <key>" \
     https://<machine>.<tailnet>.ts.net/v1/models
```

and send one request with a very large prompt and a small `max_tokens`. The
engine stays silent while it prefills. If the request returns `200` after that
silence, the path holds.

## If something does not work

**The Funnel command prints nothing and seems to hang.** It prints its reason,
then waits. Run it under `timeout` so the reason is always visible:

```bash
timeout 120 sudo tailscale funnel --bg --https=443 http://127.0.0.1:8741
```

**The public name does not resolve.** Ask a public resolver, not the machine
itself: the machine resolves its own name through MagicDNS and always succeeds.

```bash
curl -s "https://dns.google/resolve?name=<machine>.<tailnet>.ts.net&type=A"
```

A section named `Answer` must contain an address. If the name exists but has no
address, the record is not published yet. The documentation says it can take up
to 10 minutes; allow up to an hour. The published address is a Tailscale relay
server, not the machine: that is how Funnel hides the machine's own address.

**The name resolves on one network and not on another.** Some networks intercept
DNS and answer with their own content, and the answer can be wrong. Check what
the connecting computer sees: if the resolver returns only an IPv6 address and
the network has no working IPv6, the name appears not to exist. Use encrypted
DNS on the computer that connects, which a network cannot intercept or rewrite.

**Encrypted DNS on Windows 11.** Three commands, from an elevated PowerShell:

```powershell
netsh dns add encryption server=1.1.1.2 dohtemplate=https://security.cloudflare-dns.com/dns-query autoupgrade=yes udpfallback=no
netsh dns add encryption server=1.0.0.2 dohtemplate=https://security.cloudflare-dns.com/dns-query autoupgrade=yes udpfallback=no
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses 1.1.1.2,1.0.0.2
Clear-DnsClientCache
```

The addresses above are Cloudflare for Families, which also filters domains
known to distribute malware. Quad9 (`9.9.9.9`) and AdGuard
(`94.140.14.14`) work the same way with their own templates.

`udpfallback=no` means **encrypted only**: the computer does not fall back to a
plain query, which is the only kind a network can intercept. On a network with a
captive portal, a hotel or an airport for example, set `udpfallback=yes` and
reconnect, or the login page will not open.

To check the result:

```powershell
Get-DnsClientDohServerAddress
Resolve-DnsName <machine>.<tailnet>.ts.net -Type A
```

To undo it:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ResetServerAddresses
```

## SSH through the same Funnel

The same tunnel can carry SSH, so you can administer the machine from any
computer with no client installed.

Two rules decide the setup:

- **Port 22 cannot be exposed.** Funnel serves only `443`, `8443` and `10000`.
- **A plain SSH client cannot connect.** Funnel never forwards a plain
  connection: the client speaks TLS and the machine decrypts it.

So SSH runs inside TLS on one of the allowed ports, and the client wraps it.

On the machine, with the HTTPS mapping already in place:

```bash
sudo tailscale funnel --bg --tls-terminated-tcp 10000 tcp://127.0.0.1:22
tailscale funnel status
```

```
|-- tcp://<machine>.<tailnet>.ts.net:10000 (TLS terminated, Funnel on)
|--> tcp://127.0.0.1:22
https://<machine>.<tailnet>.ts.net (Funnel on)
|-- / proxy http://127.0.0.1:8741
```

Use `--tls-terminated-tcp`, not `--tcp`. Both flags exist, and `--tcp` looks
like the right one, but with `--tcp` the relay closes a plain SSH connection and
SSH never completes.

On the connecting computer, wrap SSH in TLS with `openssl s_client`. Linux and
macOS have `openssl` already:

```bash
ssh -p 10000 -o 'ProxyCommand=openssl s_client -quiet -connect %h:%p -servername %h' \
    <user>@<machine>.<tailnet>.ts.net
```

Windows does not ship `openssl`, but Git for Windows does. Use its short path,
because OpenSSH on Windows cannot start a program whose path contains spaces:

```powershell
ssh -p 10000 `
  -o 'ProxyCommand=C:\PROGRA~1\Git\usr\bin\openssl.exe s_client -quiet -verify_quiet -connect %h:%p -servername %h' `
  <user>@<machine>.<tailnet>.ts.net
```

Two notes:

- After `tailscale funnel reset`, a TCP mapping needs a moment to come back. In
  that moment the TLS handshake completes and the SSH banner never arrives.
  Wait a minute and try again.
- This makes SSH reachable from the internet. Use key authentication, check the
  setting with `sudo sshd -T | grep -i passwordauthentication`, and remove the
  mapping when you do not need it:

  ```bash
  sudo tailscale funnel --tls-terminated-tcp=10000 off
  ```

## Security

- **The address is public.** The API key is the lock, so treat it as a secret.
- **Expose the gateway only.** Port 8741 checks the key; port 8731 does not.
- **Rotate the key if it leaks.** On the machine, `superfast-switch api-key set`
  generates a new one; then update the clients.
- **The traffic is encrypted end to end.** The connection is TLS from the client
  to the machine, and the relay cannot read it. An observer on the network sees
  the tailnet name, the timing and the volume, not the prompts or the answers.

## The private alternative: a client on every device

Tailscale without Funnel gives a private network instead of a public address.
Nothing is exposed to the internet, and the service is reachable at the
machine's tailnet address (`100.x.y.z`) from every device in the tailnet. The
price is that each connecting device needs the Tailscale client installed.

Use Funnel when you want to connect from any computer with no setup. Use the
private network when you connect only from your own devices.

## The alternative with no third party

If you own a server with a public address, one SSH command gives the same result
with no third party involved:

```bash
ssh -N -R 8741:127.0.0.1:8741 <user>@<server>
```

The server forwards its own port 8741 to the machine. Make it permanent with
`autossh` and a systemd unit, and open only that port in the server's firewall.
This keeps the same advantages: no client on the connecting computer, a TCP
stream, and no HTTP timeout.

## What this changes on the machine

Nothing in the model path. The engine still serves on loopback, the gateway
still requires the key, and the local network keeps working as before. The tunnel
only adds a second way to reach the gateway.
