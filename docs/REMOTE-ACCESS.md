# Reach the machine from outside the network

This is a step-by-step guide for one situation: you want to use the model from a
computer that is not on the same network as the machine, and the machine has no
public IP address.

That is the normal case for a machine at home. If it is behind a phone hotspot
or a router you cannot configure, then no port can be forwarded to it, and
nothing on the internet can start a connection to it.

A DNS service does not solve this. A name only points to an address, and the
machine has no address that the internet can reach.

What solves it is a tunnel that **the machine itself opens**, in the outbound
direction. Your clients then connect to the tunnel's public address, and the
tunnel carries the traffic back to the machine. The router is not involved.

This guide uses **Tailscale Funnel**, because the computers that connect need
nothing installed: any program that speaks HTTP works. It is the setup we run on
our own machine. Everything below was done by hand first, so the steps include
the errors we hit and what they meant.

## What Funnel gives, and what it costs

| | |
|---|---|
| client on the connecting computer | **none** — the Funnel address is a normal HTTPS address |
| address | `https://<machine>.<tailnet>.ts.net` — a stable name, so it does not change when the network changes |
| ports | only `443`, `8443` and `10000` |
| protocol | HTTPS only. Funnel does not forward plain TCP |
| path | through Tailscale's relay servers, with bandwidth limits that cannot be configured |
| exposure | **public** — anyone on the internet can reach the address, so the API key is the only lock |
| cost | the free Personal plan (limited to a small number of users, unlimited devices) |

Two reasons this is a better fit than a general-purpose tunnel:

- **No HTTP proxy timeout.** A tunnel that proxies HTTP can cut a response that
  stays silent. Cloudflare's proxy, for example, waits 125 seconds for the
  origin to answer and then returns error 524 (6000 seconds, on Enterprise only).
  This engine sends **nothing at all while it prefills**, and a large prompt
  takes minutes: we measured 166,457 prompt tokens in 134 seconds, with no bytes
  from the engine during that time. A tunnel that carries a TCP stream does not
  care.
- **No client to install.** The computers that connect only need the address and
  the key.

If you prefer nothing to be public, see [the private
alternative](#the-private-alternative-the-client-everywhere) at the end.

## Requirements

From the Tailscale documentation:

- Tailscale version 1.38.3 or later.
- MagicDNS enabled for your tailnet.
- HTTPS certificates enabled, with a valid certificate for the tailnet name.
- A `funnel` node attribute in the tailnet policy file.

## Steps

The commands below are run **on the machine**, as your normal user, with `sudo`
where shown. Our machine runs Fedora, so the package comes from the Fedora
repositories: no third-party repository is needed.

### 1. Install Tailscale and start the service

```bash
sudo dnf install -y tailscale
sudo systemctl enable --now tailscaled
tailscale version
```

### 2. Join the tailnet

```bash
sudo tailscale up --hostname=fedora
```

The command prints a link like `https://login.tailscale.com/a/…` and then waits.
Open that link in a browser on any computer, sign in, and approve the machine.
The command finishes by itself when the login is complete.

Notes:

- Choose the account you will use to administer the tailnet. The first login
  creates the tailnet if you do not have one.
- `--hostname` sets the name in the address. We use the machine's own hostname,
  so the address becomes `https://fedora.<tailnet>.ts.net`.
- If the command appears to hang, it is waiting for the browser step, not broken.

### 3. Enable HTTPS certificates

In the admin console, open the **DNS** page
(<https://console.tailscale.com/admin/dns>) and, under **HTTPS Certificates**,
select **Enable HTTPS**. Confirm the warning: the machine name and the tailnet
name are published in a public certificate log.

Without this step, the certificate request fails with a message that is easy to
misread:

```
500 Internal Server Error: your Tailscale account does not support getting TLS certs
```

That message does not mean your plan is wrong. It means the feature is not
enabled yet.

You can test it with one command:

```bash
sudo tailscale cert --cert-file=/tmp/cert.crt --key-file=/tmp/cert.key fedora.<tailnet>.ts.net
openssl x509 -in /tmp/cert.crt -noout -subject -issuer -enddate
```

A valid certificate means the step is done.

### 4. Allow Funnel in the policy

Run the Funnel command once; if the tailnet does not allow it yet, the command
prints the exact link to fix that:

```bash
sudo tailscale funnel --bg --https=443 http://127.0.0.1:8741
```

```
Funnel is not enabled on your tailnet.
To enable, visit:

        https://login.tailscale.com/f/funnel?node=…
```

Open that link and enable Funnel for the node. In the console this is also under
**Access controls** → **Funnel** → **Add Funnel to policy**, which adds this to
the policy file:

```json
"nodeAttrs": [
  { "target": ["autogroup:member"], "attr": ["funnel"] }
]
```

Check that the machine has the capability:

```bash
tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["CapMap"])'
```

The output must contain `funnel` and a `funnel-ports` entry with `443`.

### 5. Expose the gateway

```bash
sudo tailscale funnel --bg --https=443 http://127.0.0.1:8741
tailscale funnel status
```

Expected:

```
https://fedora.<tailnet>.ts.net (Funnel on)
|-- / proxy http://127.0.0.1:8741
```

Expose **only the gateway on 8741**, which asks for the API key. Do not expose
the engine port (8731): it is bound to loopback for a reason and has no
authentication of its own.

### 6. Point the client at the new address

Use `https://` — Funnel accepts TLS only, so `http://` will not work — and keep
the two timeouts from the [client
table](../README.md#recommended-client-configuration-qwen-code-or-any-agentic-client):

```json
"baseUrl": "https://fedora.<tailnet>.ts.net/v1",
"envKey": "SUPERFAST_API_KEY"
```

## Verify it

From a computer that has **no** Tailscale client installed:

```bash
curl -s https://fedora.<tailnet>.ts.net/v1/models \
     -H "Authorization: Bearer <key>"
```

You should get the model list, for example `halogen-qwen3.8-flash-next`.

Then check that a long prefill survives the public path. The machine itself
resolves that name **inside** the tailnet, so force the public address to test
the relay:

```bash
curl --resolve fedora.<tailnet>.ts.net:443:<public-ip> \
     -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer <key>" \
     https://fedora.<tailnet>.ts.net/v1/models
```

and then send one request with a very large prompt and a small `max_tokens`. If
it returns 200 after several minutes of silence, the path holds. On our machine
that request came back **HTTP 200 after 136.9 seconds, with 166,457 prompt
tokens**: the relay held the silence, and the public path was proven, not
assumed.

## Troubleshooting

These are the five problems we actually met.

**The Funnel command prints nothing and seems to hang.** It is waiting, and it
prints its reason before it waits. Run it with a timeout so you always see the
output:

```bash
timeout 120 sudo tailscale funnel --bg --https=443 http://127.0.0.1:8741
```

**A certificate request fails with "does not support getting TLS certs".** HTTPS
certificates are not enabled: step 3.

**The public name does not resolve.** The name can take up to 10 minutes to
appear in public DNS. Check with a public resolver, not with your own machine,
which resolves it through MagicDNS and always succeeds:

```bash
curl -s "https://dns.google/resolve?name=fedora.<tailnet>.ts.net&type=A"
```

A section named `Answer` must contain an address. If the name exists but returns
no address, the record is not published yet. On our machine the record appeared
**about 45 minutes** after Funnel was enabled, so the delay can be much longer
than the documented 10 minutes. The published address is one of Tailscale's
relay servers, not the machine: that is how Funnel hides the machine's own
address.

**`curl: (6) Could not resolve host` from the other computer.** This is DNS, not
the machine. The machine can be serving perfectly while its public name does not
exist yet.

**The name works on one network and not on another, and it changes by itself.**
Some networks intercept DNS and answer with their own content. We met this on a
phone hotspot: the public record was correct — three A records with a 300-second
TTL, visible over DNS-over-HTTPS — but the hotspot's resolver answered with only
an IPv6 address, and there was no usable IPv6 route, so Windows reported "host
not found" and Node reported `ENOTFOUND`. Ten minutes later the same query
worked, with nothing changed on our side. Check what your own computer sees
before blaming the tunnel: if `nslookup <name>` shows only an IPv6 address, that
answer is the problem. If this path needs to be dependable, do not rely on the
network's DNS: use encrypted DNS on the computer that connects, or pin the relay
address in its hosts file.

**How to set encrypted DNS on Windows.** It is a setting of the network adapter,
and two commands apply it, from an elevated PowerShell:

```powershell
netsh dns set encryption server=9.9.9.9 dohtemplate=https://dns.quad9.net/dns-query autoupgrade=yes udpfallback=no
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses 9.9.9.9,149.112.112.112
Clear-DnsClientCache
```

`udpfallback=no` means **encrypted only**: the computer does not fall back to a
plain query, which is the only kind a network can intercept. The price is that on
a network with a captive portal — a hotel, an airport — the login page may not
open until you set `udpfallback=yes` and reconnect. That is the one command to
remember for travelling.

Quad9 is used here because it also filters domains known to distribute malware,
it is free, it does not log, and Windows already knows its template. Cloudflare
for Families (`1.1.1.2`) and AdGuard DNS (`94.140.14.14`) work the same way, with
their own templates.

Check the result with `Get-DnsClientDohServerAddress` (it shows the template and
whether a plain fallback is allowed) and with `Resolve-DnsName <name>`, which
should return the same records that a DNS-over-HTTPS query returns. To undo it:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ResetServerAddresses
```

## Security

- **The address is public.** The API key is the lock. Treat it as a secret.
- **Expose the gateway only.** Port 8741 checks the key; port 8731 does not.
- **Rotate the key if it leaks.** On the machine: `superfast-switch api-key set`
  generates a new one; then update the clients.
- **The traffic is encrypted end to end.** The connection is TLS from the client
  to the machine, and the relay cannot read it. An observer on the network sees
  the tailnet name, the timing and the volume, not the prompts or the answers.

## The private alternative: the client everywhere

Tailscale without Funnel gives a private network instead of a public address.
Nothing is exposed to the internet, and the service is reachable at the
machine's tailnet address (`100.x.y.z`) from every device in your tailnet. The
cost is that each connecting device needs the Tailscale client installed.

Use Funnel when you want to connect from any computer with no setup. Use the
private network when you only connect from your own devices.

## The alternative with no third party

If you own a server with a public address, you can do the same thing with one
SSH command, and no third party is involved:

```bash
ssh -N -R 8741:127.0.0.1:8741 user@your-server
```

The server then forwards its own port 8741 to the machine. Make it permanent
with `autossh` and a systemd unit, and open only that port in the server's
firewall. You keep the same benefits (no client on the connecting computer, a
TCP stream, no HTTP timeouts) and you maintain it yourself.

## What this costs the machine

Nothing in the model path changes. The engine still serves on loopback, the
gateway still requires the key, and the local network keeps working as before.
The tunnel only adds a second way to reach the gateway.
