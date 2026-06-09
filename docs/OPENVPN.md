# OpenVPN component (MVP)

Connect a fleet agent to a customer VPN (e.g. GoStudent) using an OpenVPN
**Access Server AUTOLOGIN** profile (`*.ovpn` with inline `ca`/`cert`/`key`/
`tls-crypt` — no interactive credentials, so it connects headlessly).

## Scope — why the profile is applied manually

The `.ovpn` carries an **inline private key** — a per-customer secret. For the MVP
it is **not** stored in the portal or baked into cloud-init. Instead:

- The **`openvpn` component** is the reusable, declarative part: select it in the
  Create-Agent wizard and the agent installs the OpenVPN client + the
  `sb-vpn-connect` helper at provision.
- An operator attaches the customer profile **once, post-provision**, over a secure
  channel. One idempotent command does the rest (systemd unit + heartbeat guard).

A later iteration can automate delivery (per-account profile + a token-authed
fetch) without changing the agent side — `sb-vpn-connect` stays the seam.

## 1. Provision with the component

In the Create-Agent wizard, check **OpenVPN client** (or pass it in
`AGENT_COMPONENTS`):

```bash
AGENT_COMPONENTS=chrome,sidebutton-server,sidebutton-extension,knowledge-packs,openvpn
```

This installs `openvpn` and `/usr/local/bin/sb-vpn-connect`. No VPN is connected yet.

## 2. Attach the profile (manual, one command)

Copy the `.ovpn` to the agent over a secure channel — **never commit it or paste it
into a ticket/log**. Use the agent's RDP clipboard, or `scp` to its IP:

```bash
scp profile-XXXX.ovpn root@<agent-ip>:/root/gostudent.ovpn
ssh root@<agent-ip> 'sudo sb-vpn-connect /root/gostudent.ovpn gostudent && shred -u /root/gostudent.ovpn'
```

`sb-vpn-connect <profile.ovpn> [name]` (default name `vpn`):

1. installs the profile as `/etc/openvpn/client/<name>.conf` (`chmod 600`),
2. pins the **portal host + cloud-metadata** to the pre-VPN gateway (see below),
3. enables + starts `openvpn-client@<name>` (so it **reconnects on boot**),
4. waits for `tun0` and prints a status + connectivity check.

## 3. Verify

`sb-vpn-connect` prints the result; to re-check later:

```bash
systemctl status openvpn-client@gostudent     # active + enabled
ip -br addr show tun0                          # tunnel address present
curl -s https://ifconfig.me                    # egress IP (VPN exit, if full-tunnel)
curl -sI https://sidebutton.com | head -1      # portal still reachable (heartbeat safe)
```

The agent must still show **online** in the portal fleet list after connecting.

## How it stays heartbeat-safe

The customer's Access Server may push `redirect-gateway` (a **full tunnel**), which
would otherwise route the agent's portal heartbeat, secrets fetch, and cloud
metadata *through the VPN* and break dispatch. `sb-vpn-connect` appends host routes
that OpenVPN resolves to the **real** default gateway via its native `net_gateway`
keyword, so those stay off the tunnel regardless of what the server pushes:

```
route <portal-host-ip>  255.255.255.255 net_gateway   # outbound heartbeat (PORTAL_HOST; may be CDN)
route <relay-ip>        255.255.255.255 net_gateway   # inbound :9876 probe reply path (origin/relay)
route 169.254.169.254   255.255.255.255 net_gateway   # cloud metadata
```

**Both** the portal host **and** the relay/origin IP matter: `PORTAL_HOST`
(`sidebutton.com`) is often CDN-fronted and only covers the *outbound* heartbeat,
while the portal *probes the agent inbound on :9876* from a **different**
origin/relay IP — the agent's reply must stay off-tunnel too, or the portal marks
it offline (verified end-to-end on a GoStudent full-tunnel agent). Under a split
tunnel these `/32` routes are harmless no-ops. Overrides: `PORTAL_URL=…` /
`SIDEBUTTON_RELAY_IP=…`.

## Replace / remove

```bash
sudo sb-vpn-connect /path/new.ovpn gostudent      # replace (idempotent)
sudo systemctl disable --now openvpn-client@gostudent && sudo rm /etc/openvpn/client/gostudent.conf   # remove
```

## Security notes

- The `.ovpn` is a secret (inline private key). Transfer over RDP/`scp` only; `shred`
  the temp copy; it is `chmod 600` on disk.
- It is never stored in the portal DB or cloud-init in this MVP.
- One profile per agent (the AUTOLOGIN cert is user-locked).

## Future (automated delivery)

Per-account encrypted profile storage + a `sb_token`-authed, component-gated
`GET /api/agents/vpn-profile`, fetched by a `19e-openvpn` step that calls the same
`sb-vpn-connect`. Tracked separately; not required for the MVP.
