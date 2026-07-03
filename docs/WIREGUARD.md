# WireGuard component (MVP)

Connect a fleet agent to a customer LAN over the customer's existing **WireGuard**
VPN using a standard `wg-quick` profile (`*.conf` with `[Interface]` / `[Peer]`,
inline private key, `Endpoint`, and a **split-tunnel** `AllowedIPs` — e.g.
`AllowedIPs = 192.168.1.0/24` — so only the LAN goes over the tunnel).

This mirrors the [`openvpn`](./OPENVPN.md) component for customers whose VPN is
WireGuard rather than OpenVPN. The first user is **CSS (Schubystrand) UC1**, whose
agent must reach `C1:Manager` on `192.168.1.0/24`.

## Scope — why the profile is applied manually

The `.conf` carries an **inline private key** (and often a preshared key) — a
per-customer secret. For the MVP it is **not** stored in the portal or baked into
cloud-init. Instead:

- The **`wireguard` component** is the reusable, declarative part: select it in the
  Create-Agent wizard and the agent installs `wireguard-tools` (`wg` + `wg-quick`)
  + the `sb-wg-connect` helper at provision.
- An operator attaches the customer profile **once, post-provision**, over a secure
  channel. One idempotent command does the rest (systemd unit + verification).

A later iteration can automate delivery (per-account profile + a token-authed
fetch) without changing the agent side — `sb-wg-connect` stays the seam.

## 1. Provision with the component

In the Create-Agent wizard, check **WireGuard client** (or pass it in
`AGENT_COMPONENTS`):

```bash
AGENT_COMPONENTS=chrome,sidebutton-server,sidebutton-extension,knowledge-packs,wireguard
```

This installs `wireguard-tools` and `/usr/local/bin/sb-wg-connect`. No tunnel is
connected yet.

## 2. Get SSH access to the agent

The agent's SSH key is generated and stored at provision (SCRUM-1212). Pull the
connection details + private key from the portal (`GET /api/agents/:id/ssh`):

```bash
# JSON: { host, port, username, private_key, has_key, ... }
curl -s "https://sidebutton.com/api/agents/<agent-id>/ssh" -H "Authorization: Bearer <portal-token>"
# …or download just the key file:
curl -s "https://sidebutton.com/api/agents/<agent-id>/ssh?format=pem" -H "Authorization: Bearer <portal-token>" -o agent.pem
chmod 600 agent.pem
```

- **Login user is provider-specific** — the response `username` tells you: **`root`** on
  Hetzner, **`ubuntu`** on AWS.
- Port 22 is firewall-allowlisted to the **provisioning operator's IP** (`user_ip` at
  provision), so connect from that machine. RDP/console is the alternative.

## 3. Attach the profile (one command)

Copy the `.conf` over the secure SSH channel — **never commit it or paste it into a
ticket/log** — then run the helper (`<user>`/`<host>` from step 2):

```bash
scp -i agent.pem css-ki-agent.conf <user>@<host>:/tmp/css-ki-agent.conf
ssh -i agent.pem <user>@<host> 'sudo sb-wg-connect /tmp/css-ki-agent.conf css && shred -u /tmp/css-ki-agent.conf'
```

> ✅ **Split-tunnel is SSH-safe.** Because `AllowedIPs` is just the customer LAN
> (not `0.0.0.0/0`), bringing the tunnel up does **not** reroute your interactive
> SSH session or the portal heartbeat — only traffic to the LAN subnet enters the
> tunnel. (Contrast `sb-vpn-connect`, which must pin the portal off-tunnel because
> an OpenVPN server can push a full-tunnel `redirect-gateway`.)

`sb-wg-connect <profile.conf> [name]` (default name `wg`; the CSS agent uses `css`):

1. stops any existing `wg-quick@<name>` (clean replace), then installs the profile
   as `/etc/wireguard/<name>.conf` (`chmod 600`),
2. **warns** if the profile is full-tunnel (`AllowedIPs` `0.0.0.0/0` / `::/0`) — not
   supported by this split-tunnel MVP,
3. enables + starts `wg-quick@<name>` (so it **reconnects on boot**),
4. waits for a handshake, verifies a route into each `AllowedIPs` subnet, and prints
   a status + portal-reachability check.

## 4. Verify

`sb-wg-connect` prints the result; to re-check later (CSS agent, name `css`):

```bash
systemctl status wg-quick@css                  # active + enabled
wg show css                                     # peer + 'latest handshake: N seconds ago'
ip route get 192.168.1.10                       # → dev css (LAN routes into the tunnel)
ping -c1 192.168.1.10                           # a host on the customer LAN
curl -sI https://sidebutton.com | head -1       # portal still reachable (heartbeat safe)
```

The agent must still show **online** in the portal fleet list after connecting —
under a split tunnel the heartbeat never touches the tunnel, so this is automatic.

## How it stays heartbeat-safe

This MVP only supports **split-tunnel** profiles: `AllowedIPs` lists the customer
LAN subnet(s) (e.g. `192.168.1.0/24`), so `wg-quick` installs routes for **only**
those subnets into the WireGuard interface. The agent's portal heartbeat, secrets
fetch, and cloud metadata keep using the real default route — off-tunnel by
construction — so no `net_gateway`-style carve-outs are needed (and WireGuard has
no equivalent: `wg-quick` uses fwmark policy routing for full tunnels).

If a profile sets a **full-tunnel** `AllowedIPs` (`0.0.0.0/0` / `::/0`), the helper
emits a `WARN` and proceeds, but the heartbeat is not protected — that case is out
of scope for the MVP. Raise a follow-up if a full-tunnel WireGuard customer appears.

## Replace / remove

```bash
sudo sb-wg-connect /path/new.conf css      # replace (idempotent: stops, overwrites, restarts)
sudo sb-wg-connect remove css              # tear down: disable --now wg-quick@css + rm the conf
```

## Security notes

- The `.conf` is a secret (inline private key + preshared key). Transfer over
  RDP/`scp` only; `shred` the temp copy; it is `chmod 600` on disk.
- It is never stored in the portal DB or cloud-init in this MVP.
- `wg show` redacts private/preshared keys by default, but the on-disk `.conf` does
  not — keep its mode at `600` (the helper enforces this).

## Automated delivery — default-path consumption (SCRUM-1599)

The component now **auto-consumes** any `*.conf` at its default path
**`/etc/sidebutton/config/wireguard/`**, declared in the runner catalog
(`components.json` → `config_files[]`, id `wg-profile`). A profile that lands there —
dropped over SSH, or pushed by the portal once that half ships — is applied by
`sb-wg-connect` at boot and on change; removing it tears the tunnel down. Manual
placement and portal delivery converge on identical behaviour, and
`sudo sb-wg-connect …` stays break-glass.

- Base step `19f` installs a systemd path-unit (`sb-config-watch-wireguard.path`) that
  watches the dir and triggers a per-slug reconcile (`sb-config-reconcile wireguard`);
  each `<name>.conf` → `wg-quick@<name>`.
- The reconcile is **sha-gated** (a routine `sb-self-update` never bounces a live tunnel)
  and only tears down tunnels **it** brought up — a manually-created same-named tunnel is
  never cut.
- Portal→agent writes go through one narrow-sudoers wrapper, `sb-config-place`, which
  installs the file `root:600` and confines every write to this declared path.

Portal-side storage/UI (encrypted per-account/workspace store + Files-hub dropzone) is
tracked separately (epic SCRUM-1597, tickets A2–A5); the agent side above is complete and
reaches the existing fleet via `sb-self-update` (`refresh-manifest.txt`).
