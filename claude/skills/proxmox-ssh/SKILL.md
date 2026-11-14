---
name: proxmox-ssh
description: Run commands on the user's Proxmox hosts and their LXC containers / VMs over SSH with YubiKey (FIDO2) keys, without making the user switch tabs or copy commands. It auto-detects which YubiKey (primary k1 / backup k2) is plugged in. Also sets up hardware-key root SSH on new guests and registers them in ssh config + sesh. Use whenever the user mentions proxmoxmediaconnect, proxmoxpersonalconnect, pve, mediaserver, their containers/VMs (notifications, mealplanner, media-vm), YubiKey SSH, or wants SSH access to a homelab guest.
---

# Proxmox SSH with YubiKeys

Everything is versioned in `~/.dotfiles` (a PUBLIC repo: never commit YubiKey serials,
the Tailscale tailnet name, or keys).

| File | Purpose |
|---|---|
| `~/.dotfiles/ssh/proxmox.conf` | Host aliases, ControlMaster, auto key choice. `Include`d at the TOP of `~/.ssh/config` (above any `Host` line, or it gets scoped to that block) |
| `~/.dotfiles/ssh/yk-select` | Detects the plugged-in YubiKey (`ykman list --serials`) and picks k1/k2 |
| `~/.dotfiles/ssh/askpass-macos` | Native macOS passphrase/PIN/touch dialog for ssh (symlinked to `~/.ssh/askpass-macos`) |
| `~/.ssh/yubikey-map` | LOCAL ONLY: `<serial> k1\|k2` lines |
| `~/.dotfiles/sesh/sesh.toml` | sesh sessions for every host/guest |
| `~/.dotfiles/bash/.bashrc` | `proxmoxmediaconnect`, `proxmoxpersonalconnect` etc. |
| this skill | symlinked to `~/.claude/skills/proxmox-ssh` by `~/.dotfiles/symlinks.sh` |

## Hosts
| Alias | Address | Notes |
|---|---|---|
| `proxmoxmediaconnect` | `root@10.0.0.84` | PVE node "mediaserver" |
| `proxmoxpersonalconnect` | `root@10.0.0.226` | also `pve-226` and its Tailscale name |
| `notifications` | CT101 10.0.0.139 | root, hardware keys only |
| `mealplanner` | CT102 10.0.0.206 | root, hardware keys only. The app: see the **mealplanner** skill. Never stop `product-photos-reseed.service` (API poller) |
| `media-vm` | VM100 10.0.0.247 | Ubuntu 24.04. **Root is the only login** (`AllowUsers root`, hardware keys only). daniel deleted 2026-11-13: home archived at `/root/daniel-home-backup.tar.gz`, files/.bashrc/Claude Code moved to /root. `ops-dashboard` (port 8089) runs as no-login `opsdash`. Plex-refresh cron is root's, logging to `/var/log/plex-refresh.log`. `ubuntu` (uid 1000) is kept only as the containers' PUID: nologin, no sudo. Serial console auto-logs in root |
| `metube` | CT103 **100.82.133.76 (Tailscale)** | its CT firewall drops LAN traffic (policy_in DROP), so SSH works over Tailscale only. Keep it that way |
| `immich` | CT105 10.0.0.208 | root, hardware keys only |

Keys: `~/.ssh/id_ed25519_sk_servers_k1` (primary YubiKey, "yubikey-1") and `_k2` (backup, "yubikey-2"),
each on its own device (verified 2026-11-13: k2 on the primary gives `FIDO_ERR_NO_CREDENTIALS`).
They're ED25519-SK, **resident + verify-required** (flags 0x25), so every new connection needs the
YubiKey **PIN** and a touch. The dialog asks for the PIN. In `ssh -v` output, the first
"incorrect passphrase" line is just ssh discovering it needs the PIN. That's normal.
`signing failed ...: invalid format` is a catch-all: run `ssh -v` and look for `FIDO_ERR_NO_CREDENTIALS`
(wrong YubiKey) or `FIDO_ERR_PIN_INVALID` (wrong PIN).
Because the keys are resident, a new Mac can recreate the key files with `ssh-keygen -K` (once per YubiKey).
`yk-select` makes ssh offer only the plugged-in key's file. If the key is unknown or `ykman` is missing,
ssh offers k1 then k2, and connect.sh learns the mapping after a success.
Check the current state: `~/.dotfiles/ssh/yk-select --describe`.
Map a key by hand: plug in only that key, then run `yk-select --learn k1` or `--learn k2`.

## Primary vs backup: always say which one
| Name to use with the user | Key file | Comment in .pub | Serial |
|---|---|---|---|
| **Primary YubiKey** | `id_ed25519_sk_servers_k1` | `yubikey-1` | in `~/.ssh/yubikey-map` (local) |
| **Backup YubiKey** | `id_ed25519_sk_servers_k2` | `yubikey-2` | learned the first time it's used |

- When talking to the user, say "primary" or "backup", not k1/k2 on their own.
- `~/.dotfiles/ssh/yk-select --describe` prints which one is plugged in.
- **Check both keys work everywhere:** `bash ~/.claude/skills/proxmox-ssh/scripts/audit.sh [root@node]`.
  It's read-only and shows a PRIMARY / BACKUP ✔/✘ table for the node and every CT/VM
  (it needs an open connection to the node). Run it after setting up any guest.
  Last run 2026-11-13: 10.0.0.84 all ✔ (node, CT101, CT102, VM100). 10.0.0.226 ✔ (node, CT103, CT105).
  CT106 files is deliberately left without root keys (locked-down SFTP box): its ✘ is expected.
  VM200 pbs: out of scope, the user said to forget it (2026-11-13). Don't touch it unless asked.
- **Live-tested 2026-11-13:** the PRIMARY logged into 10.0.0.84, 10.0.0.226 and media-vm. The BACKUP logged into
  10.0.0.84, notifications, mealplanner, media-vm and 10.0.0.226 (all connections closed first, so none were reused).
- An unknown YubiKey is assumed to fill whichever slot is still unmapped. connect.sh records it after the first
  login. If the guess is wrong, connect.sh switches to the other slot, records that, and retries once.

## How to authenticate (never ask the user to switch tabs or copy commands)
1. Tell the user in one line: "A macOS dialog will pop up: enter your passphrase, then tap the YubiKey."
2. Run `bash ~/.claude/skills/proxmox-ssh/scripts/connect.sh <host> [host...]` with a timeout of 180000 ms or more.
   It prints which YubiKey it detected, then shows one dialog and needs one tap per host not already connected.
   If it says "No YubiKey detected", ask the user to plug one in and rerun.
3. From then on, run `ssh -o BatchMode=yes <host> '...'` freely for 10 min (30 with `connect.sh --long`, **5 h with
   `connect.sh --work`**, which the user asked for on working sessions like the meal planner, 2026-11-14): no prompts.
   These are idle timeouts: the master closes only after that long with no ssh use.
   `BatchMode` makes it fail fast if the master has died. If that happens, rerun connect.sh.
4. To end early: `ssh -O exit <host>`.

`ssh` must be `/opt/homebrew/bin/ssh`. Apple's ssh can't use these keys.

## Hardening applied (2026-11-13, user asked for "maximum security")
- Both nodes: sshd accepts only sk keys and no passwords. The web UI/API is limited to LAN and Tailscale via
  `/etc/default/pveproxy` (ALLOW_FROM 10.0.0.0/24,100.64.0.0/10, DENY_FROM all).
- **Web UI 2FA = WebAuthn only** (2026-11-13): root@pam has `Key1` and `Key2` (primary and backup YubiKey)
  plus recovery keys. Yubico OTP is removed, and so is the realm-level `tfa type=yubico` on the `pam` realm.
  That realm setting was what greyed out WebAuthn, because realm TFA forces its own type. Backups:
  `/root/domains.cfg.bak-*`. **Never re-add realm TFA.**
- WebAuthn needs a hostname and a trusted cert, so log in at `https://<node>.<tailnet>.ts.net:8006`. On a bare
  IP the WebAuthn tab fails ("effective domain is not a valid domain"), and only recovery keys work there.
  Both nodes run Tailscale (tag:server, accept-dns off) and get a Let's Encrypt cert via `tailscale cert`,
  renewed monthly by `pve-tailscale-cert-renew.timer` (`/usr/local/bin/pve-tailscale-cert-renew.sh`).
  `datacenter.cfg` has `webauthn: rp=…,origin=https://…:8006,id=…`.
- The tailnet ACL only grants access to `tag:server`. A new node needs `tailscale up --advertise-tags=tag:server`,
  or its inbound packet filter is empty (Tailscale ping works but TCP is silently dropped).
  The mediaserver node's PVE firewall also needed `IN ACCEPT -source 100.64.0.0/10 -p tcp -dport 8006`.
- **YubiKey OTP interface disabled on both keys** (2026-11-13, `ykman config usb --disable OTP`) so stray taps
  stop typing codes. Only FIDO and CCID are enabled. Re-enable with `ykman config usb --enable OTP`.
- **Browser: Chrome only** for registering or using the YubiKeys. Safari and Firefox on this Mac hand off to the
  macOS passkey sheet, which never reaches the key (tapping just types an OTP). In Chrome pick "Use a security key".
- The `root@mediaserver`/`root@pve` RSA keys in the nodes' authorized_keys are managed by Proxmox, and
  sshd already rejects them (sk-only). Leave them alone.
- `dashboard@pve` and `prometheus@pve` are PVEAuditor (read-only).
- ControlPersist is 10 min by default. Use `connect.sh --long` for 30 min, `--work` for 5 h (dev sessions).
- Break-glass if SSH ever fails: `qm guest exec <vmid> -- ...` / `pct exec <ctid> -- ...` from the node.
  media-vm's serial console auto-logs in root.

## Network isolation, updates, watchtower (2026-11-13)
Check everything: `bash ~/.claude/skills/proxmox-ssh/scripts/netsec-audit.sh root@<node>` (READ-ONLY): firewall per
guest, auto-updates, host pending updates, Tailscale tag + who may connect in over the tailnet.

**Model:** every guest can reach the internet (so apt, docker pulls and model downloads just work), but never other LAN
devices or guests. Inbound is DROP except its own service ports. Two layers are needed:
- **Proxmox firewall** = LAN traffic. It CANNOT see Tailscale traffic inside guests that run tailscale (decrypted on
  tailscale0), so for those guests the **Tailscale policy** is the only control on tailnet traffic.

**Firewall template** = security group `guest-isolate` + IPSet `lan6` in each node's `/etc/pve/firewall/cluster.fw`
(backup: `/root/cluster.fw.pre-isolate`). The group allows DHCP/DHCPv6, Tailscale direct UDP 41641, SSH from the LAN,
and DNS to the gateway, then drops all IPv4 LAN egress and IPv6 LAN egress (tcp/udp: link-local, ULA and the ISP /64s
in `lan6`; **update lan6 if the ISP prefix changes**, a stale entry fails open). To isolate a guest:
1. Inventory first: `ss -tlnu`, LAN peers, network mounts, and who calls it (e.g. host `tailscale serve`).
2. Write `/etc/pve/firewall/<id>.fw`: `[OPTIONS] enable: 1 / policy_in: DROP / policy_out: ACCEPT`, then `[RULES]`
   with the specific IN ports (`-source dc/local-net`, or a single host) and any OUT exceptions **before** `GROUP guest-isolate`.
3. Add `firewall=1` to net0 (`pct set <id> --net0 "<current>,firewall=1"` / `qm set`). This applies live.
4. Wait about 10s (pve-firewall reloads periodically), then verify: service ports from the Mac, internet from inside,
   and LAN + LAN-v6 blocked from inside.
Rollback: `enable: 0` in the guest .fw (instant).
Applied: immich 105 (2283 only from 10.0.0.226 = host serve), notifications 101 (80/443/8080 from LAN), mealplanner 102
(80/443/8765), media-vm 100 (web UIs from LAN, Plex 32400 from anywhere, Plex/Jellyfin discovery; OUT exception
10.0.0.84:8006 for ops-dashboard). metube/files/pbs already had equivalent rules. Port 80/443 on guests usually only
listen on tailscale0 (tailscale serve), which is expected.

**Auto-updates:** `unattended-upgrades` on all CTs (Debian default: stable + security) and media-vm (Ubuntu: security).
Hosts are restricted to **Debian-Security only** (`/etc/apt/apt.conf.d/52unattended-local` uses `#clear` on
Origins-Pattern). Proxmox packages are never automatic: run `apt full-upgrade` + reboot in a window. No automatic reboots
anywhere. `files` (CT106) has out=DROP, so it can't update until egress is decided.

**Watchtower (media-vm):** nightly 04:00 updates every container except itself. It's pinned to
`nickfedor/watchtower:1.24.0` with `com.centurylinklabs.watchtower.enable=false`, because it holds the docker socket
(= root). Bump it deliberately. Cleanup stays on (7.5G free, and `--filter until` prunes by build date, so a rollback
window is unreliable). Compose backup: `/root/docker-compose.yaml.bak-20261113`.

**Tailscale (needs the user, in the admin console):** see the to-do in the conversation of 2026-11-13: tag immich, remove
stale `debian`/`umbrel`, split `tag:server` into role tags, replace server->server `*` with specific grants, add tests.

## Leak sweep (secrets lying around in guests)
`bash ~/.claude/skills/proxmox-ssh/scripts/leak-scan.sh root@<node> [--skip VMID,...]` is READ-ONLY. It scans the node
and every running CT (pct exec) and VM (guest agent) for private keys, credential stores (gh, Claude Code, docker,
aws, netrc...), token-shaped strings, secret-looking shell-history lines, env-file permissions and stray backups.
It **prints paths, perms and categories only, never secret values.** Dependency caches and library test fixtures are
skipped (they hold fake keys). Use `--skip 200` for pbs (out of scope).
Rules agreed with the user (2026-11-13):
- **Never edit env files' contents.** Only fix perms: real env files get 600 with the same owner. Every env
  file here is loaded via systemd `EnvironmentFile=` or docker compose as root, so 600 is safe (check
  consumers first on new ones). Templates (`.env.example`) just lose group/world write.
- Delete unused user SSH private keys (check git remotes, ~/.ssh/config, cron and systemd first). Keep
  `/etc/ssh/ssh_host_*` (server identity) and the PVE node `/root/.ssh/id_rsa`.
- Histories: remove only secret-looking lines, not the whole file.
- First sweep 2026-11-13: removed daniel's key (media-vm), root@pve ed25519 (226), daniel's home archive,
  domains.cfg backups (old Yubico API secret), and 217 secret-looking history lines (187 on mealplanner).
  Logged Claude Code + gh out on BOTH NODES (hosts must hold no account tokens). The user chose to keep them
  logged in on the guests (notifications, mealplanner, media-vm). Expected leftovers in a scan: those guest
  credential files, CT101 `/root/env.bak-pre-twilio` (env backup, 640 root:nudge, contents untouched by rule)
  and CT101's two app-data zips (600).

## Inventory a node
`ssh -o BatchMode=yes root@10.0.0.84 'bash -s' < ~/.claude/skills/proxmox-ssh/scripts/inventory-remote.sh`
(this only reads: pct/qm lists, OS, IPs, sshd version, guest-agent status).

## Give a new guest hardware-key root SSH
Keys file: `cat ~/.ssh/id_ed25519_sk_servers_k1.pub ~/.ssh/id_ed25519_sk_servers_k2.pub > ~/.ssh/cm/keys.pub`

- **LXC** (from the host, no guest login needed):
  `scp -q ~/.ssh/cm/keys.pub ~/.claude/skills/proxmox-ssh/scripts/provision-ct.sh root@<node>:/tmp/ && ssh -o BatchMode=yes root@<node> 'bash /tmp/provision-ct.sh <ctid>... < /tmp/keys.pub; rm -f /tmp/provision-ct.sh /tmp/keys.pub'`
  This is idempotent. It installs openssh-server if it's missing, appends the keys, and writes
  `/etc/ssh/sshd_config.d/10-yubikey.conf` (prohibit-password, no passwords, sk-only algorithms).
  It runs `sshd -t` first. A "Reload failed" from Debian socket activation is harmless; the
  script falls back to a restart. The sk-only rule is global, so only use it when no other user
  logs in with regular keys. Otherwise put it under `Match User root`.
  Recovery if locked out: `pct enter <ctid>` on the host.
- **VM**: use `qm guest exec <vmid> -- ...` if `qm agent <vmid> ping` works. Otherwise go through an
  existing login with sudo. Put the sk-only algorithms under `Match User root` so other users'
  keys keep working. Install `qemu-guest-agent` too.
- **Register it** (then commit and push dotfiles when the user asks):
  1. `~/.dotfiles/ssh/proxmox.conf`: add `Host <alias>` / `HostName <ip>` / `User root`, add the
     alias to the shared `Host` line, and add the IP to all three `Match ... host` lists.
  2. `~/.dotfiles/sesh/sesh.toml`: add a `[[session]]` with `startup_command = "ssh <alias>"`.
  3. Update the host tables in this file.
  For DHCP guests, confirm the IP with `ip neigh` on the node, matching the MAC from `qm config`/`pct config`.
- Verify: `connect.sh <alias>`, then `ssh -o BatchMode=yes <alias> 'hostname; whoami'`.

Before overwriting or deleting anything on a guest, look at it first, e.g. an existing `authorized_keys`.
