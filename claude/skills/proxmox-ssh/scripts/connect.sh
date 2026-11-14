#!/bin/bash
# Open (or reuse) an authenticated SSH master connection for each host.
# A native macOS dialog asks for the key passphrase (or PIN), the user taps the
# YubiKey, then `ssh -o BatchMode=yes <host> ...` reuses the connection with no
# prompt for 10 min (or 30 with --long).
# Usage: connect.sh [--long] <host> [host...]     Exit code = number of failures.
G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' C=$'\033[1;36m' B=$'\033[1m' D=$'\033[2m' N=$'\033[0m'
YK=~/.dotfiles/ssh/yk-select
ASKPASS=~/.ssh/askpass-macos
[ -x "$ASKPASS" ] || ASKPASS=~/.dotfiles/ssh/askpass-macos
mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh/cm

[[ $(command -v ssh) == /opt/homebrew/bin/ssh* ]] || { echo "${R}✘ ssh is not Homebrew ($(command -v ssh)) - FIDO keys won't work${N}"; exit 99; }
PERSIST=10m
[ "$1" = --long ] && { PERSIST=30m; shift; }
[ $# -gt 0 ] || { echo "usage: connect.sh [--long] <host> [host...]   (--long = reusable 30 min instead of 10)"; exit 2; }

todo=()
for h in "$@"; do
  if ssh -O check "$h" >/dev/null 2>&1; then echo "${G}✔ $h${N} ${D}already connected (no tap needed)${N}"
  else todo+=("$h"); fi
done
[ ${#todo[@]} -eq 0 ] && exit 0

echo "${C}== YubiKey${N}"
desc=$("$YK" --describe); rc=$?; printf '%s\n' "$desc" | sed 's/^/  /'
[ $rc -eq 0 ] || { echo "  ${Y}➜ plug in your primary or backup YubiKey, then run this again${N}"; exit 98; }
slot=$("$YK" --slot)
known=1; "$YK" --known || known=

try() {  # $1 host, $2 log
  SSH_ASKPASS=$ASKPASS SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh -fN -o ControlMaster=yes -o ControlPersist=$PERSIST -o ConnectTimeout=10 "$1" </dev/null >"$2" 2>&1
  ssh -O check "$1" >/dev/null 2>&1
}

fail=0
for h in "${todo[@]}"; do
  echo "${C}== $h${N}"
  echo "  ${Y}➜ Dialog: enter your key passphrase/PIN, then tap the YubiKey when it blinks${N}"
  log=~/.ssh/cm/connect-${h//[^A-Za-z0-9._-]/_}.log
  try "$h" "$log"
  # Mapped slot is wrong ("invalid format" = credential not on this device): flip, relearn, retry once
  if ! ssh -O check "$h" >/dev/null 2>&1 && [ "$slot" != any ] && grep -q "signing failed.*servers_$slot\".*invalid format" "$log"; then
    other=k1; [ "$slot" = k1 ] && other=k2
    echo "  ${Y}! this YubiKey isn't $slot - remapping to $other and retrying (one more dialog + tap)${N}"
    "$YK" --learn "$other" && slot=$other && known=1
    try "$h" "$log"
  fi
  if ssh -O check "$h" >/dev/null 2>&1; then
    echo "  ${G}✔ connected${N} ${D}- reusable for $PERSIST${N}"
    grep -q 'Permanently added' "$log" && echo "  ${D}(new host key saved to known_hosts)${N}"
    if [ -z "$known" ]; then   # new key: remember which slot it turned out to be
      used=$slot
      if [ "$slot" = any ]; then used=k1; grep -q 'signing failed.*servers_k1' "$log" && used=k2; fi
      label=PRIMARY; [ "$used" = k2 ] && label=BACKUP
      "$YK" --learn "$used" 2>/dev/null && echo "  ${B}★ remembered this YubiKey as your $label ($used)${N} ${D}(~/.ssh/yubikey-map)${N}" && slot=$used && known=1
    fi
  else
    fail=$((fail+1)); echo "  ${R}✘ failed${N}"
    if grep -q 'device not found' "$log" && ! grep -q 'Authenticated' "$log"; then
      echo "  ${R}  YubiKey not found - it was unplugged or not inserted fully${N}"
    elif grep -q 'Permission denied' "$log"; then
      echo "  ${R}  key rejected - wrong YubiKey, or this host doesn't have the key in authorized_keys yet${N}"
    elif grep -q 'Connection closed by' "$log" && ! grep -q 'Permission denied' "$log"; then
      echo "  ${R}  dialog cancelled or PIN/tap not given in time - just rerun${N}"
    elif grep -qiE 'timed out|No route|refused' "$log"; then
      echo "  ${R}  host unreachable${N}"
    fi
    sed "s/^/    ${D}/; s/\$/${N}/" "$log"
  fi
done
exit $fail
