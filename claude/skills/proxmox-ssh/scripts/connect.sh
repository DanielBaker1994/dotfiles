#!/bin/bash
# Open (or reuse) an authenticated SSH master connection for each host.
# A native macOS dialog asks for the key passphrase (or PIN), the user taps the
# YubiKey, then `ssh -o BatchMode=yes <host> ...` reuses the connection with no
# prompt for 30 min (ControlPersist in ~/.dotfiles/ssh/proxmox.conf).
# Usage: connect.sh <host> [host...]      Exit code = number of failures.
G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' C=$'\033[1;36m' B=$'\033[1m' D=$'\033[2m' N=$'\033[0m'
YK=~/.dotfiles/ssh/yk-select
ASKPASS=~/.ssh/askpass-macos
[ -x "$ASKPASS" ] || ASKPASS=~/.dotfiles/ssh/askpass-macos
mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh/cm

[[ $(command -v ssh) == /opt/homebrew/bin/ssh* ]] || { echo "${R}✘ ssh is not Homebrew ($(command -v ssh)) - FIDO keys won't work${N}"; exit 99; }
[ $# -gt 0 ] || { echo "usage: connect.sh <host> [host...]"; exit 2; }

todo=()
for h in "$@"; do
  if ssh -O check "$h" >/dev/null 2>&1; then echo "${G}✔ $h${N} ${D}already connected (no tap needed)${N}"
  else todo+=("$h"); fi
done
[ ${#todo[@]} -eq 0 ] && exit 0

echo "${C}== YubiKey${N}"
"$YK" --describe | sed 's/^/  /' || exit 98
slot=$("$YK" --slot)

fail=0
for h in "${todo[@]}"; do
  echo "${C}== $h${N}"
  echo "  ${Y}➜ Dialog: enter your key passphrase/PIN, then tap the YubiKey when it blinks${N}"
  log=~/.ssh/cm/connect-${h//[^A-Za-z0-9._-]/_}.log
  SSH_ASKPASS=$ASKPASS SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh -fN -o ControlMaster=yes -o ConnectTimeout=10 "$h" </dev/null >"$log" 2>&1
  if ssh -O check "$h" >/dev/null 2>&1; then
    echo "  ${G}✔ connected${N} ${D}- reusable for 30 min${N}"
    grep -q 'Permanently added' "$log" && echo "  ${D}(new host key saved to known_hosts)${N}"
    if [ "$slot" = any ]; then   # unknown key: learn which slot it is
      used=k1; grep -q 'signing failed.*servers_k1' "$log" && used=k2
      "$YK" --learn "$used" 2>/dev/null && echo "  ${B}★ remembered this YubiKey as $used${N} ${D}(~/.ssh/yubikey-map)${N}" && slot=$used
    fi
  else
    fail=$((fail+1)); echo "  ${R}✘ failed${N}"
    if grep -q 'Permission denied' "$log"; then
      echo "  ${R}  key rejected - wrong YubiKey, or this host doesn't have the key in authorized_keys yet${N}"
    elif grep -qiE 'timed out|No route|refused' "$log"; then
      echo "  ${R}  host unreachable${N}"
    fi
    sed "s/^/    ${D}/; s/\$/${N}/" "$log"
  fi
done
exit $fail
