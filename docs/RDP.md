# RDP client component (FreeRDP)

Open an **outbound** RDP session from a fleet agent to a customer host that has
no API/export/web view — an on-prem Windows ERP (e.g. C1:Manager) — and render
it as a stable, fixed-geometry window on the agent's desktop (`:10`). There the
`computer-use` plugin drives the GUI and operators watch via LiveDesktop.
Reusable for any RDP/desktop customer.

> **Two different "RDP passwords" — don't conflate.** `base/19-secrets.sh` applies
> an **inbound** RDP password so operators can RDP *into* this VM. This component is
> the **outbound** session (agent → customer host); its host + credentials are
> separate and delivered out-of-band (below).

## Scope — why credentials are applied manually

The target host + login are a per-customer **secret**. For the MVP they are **not**
stored in the portal or baked into cloud-init. Instead:

- The **`rdp-client` component** is the reusable, declarative part: select it in the
  Create-Agent wizard and the agent installs FreeRDP (`xfreerdp`) + the
  `sb-rdp-connect` helper + a disabled `sb-rdp.service` at provision.
- An operator drops the credentials **once, post-provision**, over a secure channel
  and enables the service.

A later iteration can automate delivery (per-account secret + a token-authed fetch)
without changing the agent side — `sb-rdp-connect` + `/etc/sidebutton/rdp.env` stay
the seam.

## 1. Provision with the component

In the Create-Agent wizard, check **RDP client (FreeRDP)** (or pass it in
`AGENT_COMPONENTS`):

```bash
AGENT_COMPONENTS=chrome,sidebutton-server,sidebutton-extension,knowledge-packs,rdp-client
```

This installs `freerdp2-x11` (binary `xfreerdp`; falls back to `freerdp3-x11` /
`xfreerdp3`), `/usr/local/bin/sb-rdp-connect`, and a **disabled** `sb-rdp.service`.
No session is connected yet.

## 2. Get SSH access to the agent

Pull the connection details + private key from the portal
(`GET /api/agents/:id/ssh`); the response `username` is provider-specific (**`root`**
on Hetzner, **`ubuntu`** on AWS):

```bash
curl -s "https://sidebutton.com/api/agents/<agent-id>/ssh?format=pem" \
  -H "Authorization: Bearer <portal-token>" -o agent.pem
chmod 600 agent.pem
```

## 3. Drop the credentials + enable (one file, one command)

Create `/etc/sidebutton/rdp.env` on the agent — **never commit it or paste it into a
ticket/log** — then enable the service:

```bash
ssh -i agent.pem <user>@<host> 'sudo install -m 600 /dev/stdin /etc/sidebutton/rdp.env' <<'ENV'
RDP_HOST=10.20.0.5
RDP_USER=KIAgent
RDP_PASS=********
RDP_DOMAIN=CORP            # optional
RDP_GEOMETRY=1600x1000     # optional (default 1600x1000; must fit :10 = 1920x1080)
RDP_EXTRA=                 # optional extra xfreerdp flags, e.g. /sec:tls /network:lan
ENV
ssh -i agent.pem <user>@<host> 'sudo systemctl enable --now sb-rdp'
```

`sb-rdp.service` runs `sb-rdp-connect` as the **`agent`** user on `DISPLAY=:10`,
`Restart=always`. The helper:

1. sources `/etc/sidebutton/rdp.env` (idle-waits if it is absent/incomplete — safe
   to enable before the creds land),
2. launches `xfreerdp` with **pinned geometry** (fixed `/size` + `/scale:100` +
   `-dynamic-resolution`, no `/f` / `/smart-sizing`) so the window's pixel
   dimensions stay identical across reconnects,
3. auto-reconnects on drop (FreeRDP `+auto-reconnect`, plus an outer 5s reconnect
   loop for hard drops / host reboots).

## 4. Verify

```bash
systemctl status sb-rdp                 # active + enabled (reconnects on boot)
journalctl -u sb-rdp -n 30 --no-pager   # "[sb-rdp] connecting to KIAgent@... on :10"
DISPLAY=:10 wmctrl -l                    # an xfreerdp window is present
```

Open LiveDesktop for the agent — the customer session is visible on `:10`. Forcing
a reconnect (`pkill xfreerdp`) brings the window back automatically at the **same
dimensions** (the geometry pin — verify with identical screenshot W×H).

## How geometry stays constant (computer-use stability)

`computer-use` screenshots and clicks the `:10` framebuffer by pixel coordinate, so
the RDP window must not rescale. `sb-rdp-connect` therefore pins it:

| flag | effect |
|---|---|
| `/size:1600x1000` | fixed window size (not `/w`+`/h` percent, not `/f`) |
| `/scale:100` | no desktop scaling |
| `-dynamic-resolution` | session does **not** resize to follow the window |
| (no `/smart-sizing`) | no post-hoc bitmap rescale |

Default `1600x1000` leaves room under the WM titlebar on the `1920x1080` `:10`
display. Override with `RDP_GEOMETRY=WxH` in `rdp.env`.

## Replace / remove

```bash
sudo systemctl restart sb-rdp                                   # re-read rdp.env after an edit
sudo systemctl disable --now sb-rdp && sudo rm /etc/sidebutton/rdp.env   # remove
```

## Security notes

- The credentials are a secret — transfer over SSH only; `rdp.env` is `chmod 600`,
  owned by `root`. It is never stored in the portal DB or cloud-init in this MVP.
- `/p:` is passed on `xfreerdp`'s argv, visible in `ps` to root on this
  single-tenant VM (only the `agent` user runs workloads). `/cert:ignore` accepts the
  customer host certificate unattended. Tighten per-customer via `RDP_EXTRA`.

## Future (automated delivery)

Per-account encrypted credential storage + a `sb_token`-authed, component-gated
fetch that writes `/etc/sidebutton/rdp.env` and enables `sb-rdp`, reusing the same
helper. Tracked separately; not required for the MVP.
