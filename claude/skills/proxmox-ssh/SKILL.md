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
| `mealplanner` | CT102 10.0.0.206 | root, hardware keys only |
| `media-vm` | VM100 10.0.0.247 | root NOT provisioned yet. `daniel@10.0.0.247` works (non-hardware key, NOPASSWD sudo) |

Keys: `~/.ssh/id_ed25519_sk_servers_k1` (primary) and `_k2` (backup). Both are ED25519-SK
with a file passphrase, so every new connection needs a passphrase and a touch. `yk-select`
makes ssh offer only the plugged-in key's file. If the key is unknown or `ykman` is missing,
ssh offers k1 then k2, and connect.sh learns the mapping after a success.
Check the current state: `~/.dotfiles/ssh/yk-select --describe`.
Map a key by hand: plug in only that key, then run `yk-select --learn k1` or `--learn k2`.

## How to authenticate (never ask the user to switch tabs or copy commands)
1. Tell the user in one line: "A macOS dialog will pop up: enter your passphrase, then tap the YubiKey."
2. Run `bash ~/.claude/skills/proxmox-ssh/scripts/connect.sh <host> [host...]` with a timeout of 180000 ms or more.
   It prints which YubiKey it detected, then shows one dialog and needs one tap per host not already connected.
   If it says "No YubiKey detected", ask the user to plug one in and rerun.
3. From then on, run `ssh -o BatchMode=yes <host> '...'` freely for 30 min: no prompts.
   `BatchMode` makes it fail fast if the master has died. If that happens, rerun connect.sh.
4. To end early: `ssh -O exit <host>`.

`ssh` must be `/opt/homebrew/bin/ssh`. Apple's ssh can't use these keys.

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
