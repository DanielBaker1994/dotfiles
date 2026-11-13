#!/bin/bash
# Audit which YubiKeys can log in as root on a Proxmox node and ALL its guests.
# Reads /root/.ssh/authorized_keys on the node, each LXC (pct exec) and each VM
# (qm guest exec, needs qemu-guest-agent). Read-only.
# Usage: audit.sh [node]   (default root@10.0.0.84; needs an open connection: connect.sh first)
G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' C=$'\033[1;36m' D=$'\033[2m' N=$'\033[0m'
NODE=${1:-root@10.0.0.84}
K1=$(awk '{print $2}' ~/.ssh/id_ed25519_sk_servers_k1.pub)
K2=$(awk '{print $2}' ~/.ssh/id_ed25519_sk_servers_k2.pub)

dump=$(ssh -o BatchMode=yes "$NODE" 'bash -s' 2>&1 <<'REMOTE'
echo "@@ node $(hostname)"; cat /root/.ssh/authorized_keys 2>/dev/null
for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
  echo "@@ CT$id $(pct config $id | awk '/^hostname:/{print $2}')"
  if pct status $id | grep -q running; then pct exec $id -- cat /root/.ssh/authorized_keys 2>/dev/null
  else echo "!! stopped"; fi
done
for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  echo "@@ VM$id $(qm config $id | awk '/^name:/{print $2}')"
  if ! qm status $id | grep -q running; then echo "!! stopped"
  elif qm agent $id ping >/dev/null 2>&1; then
    qm guest exec $id -- cat /root/.ssh/authorized_keys 2>/dev/null \
      | perl -MJSON::PP -0777 -ne 'print((decode_json($_)->{"out-data"})//"")'
  else echo "!! no guest agent - can't check"; fi
done
REMOTE
) || { echo "${R}✘ can't reach $NODE - run connect.sh $NODE first${N}"; echo "$dump" | tail -3; exit 1; }

echo "${C}== Root login audit: $NODE and its guests${N}"
printf "  ${D}%-28s %-16s %-16s %s${N}\n" "MACHINE" "PRIMARY (k1)" "BACKUP (k2)" "OTHER KEYS"
bad=0
report() {
  [ -z "$name" ] && return
  if [ -n "$note" ]; then printf "  %-28s ${Y}%s${N}\n" "$name" "$note"; bad=$((bad+1)); return; fi
  local a b o
  grep -qF "$K1" <<<"$keys" && a="${G}✔ yes${N}" || { a="${R}✘ MISSING${N}"; bad=$((bad+1)); }
  grep -qF "$K2" <<<"$keys" && b="${G}✔ yes${N}" || { b="${R}✘ MISSING${N}"; bad=$((bad+1)); }
  o=$(grep -E '^(ssh|sk-|ecdsa)' <<<"$keys" | grep -vF -e "$K1" -e "$K2" | awk '{print $NF}' | paste -sd, -)
  printf "  %-28s %-27s %-27s ${D}%s${N}\n" "$name" "$a" "$b" "${o:-none}"
}
name= keys= note=
while IFS= read -r line; do
  case "$line" in
    "@@ "*) report; name=${line#@@ }; keys=; note= ;;
    "!! "*) note=${line#!! } ;;
    *) keys+="$line"$'\n' ;;
  esac
done <<<"$dump"
report
echo
[ $bad -eq 0 ] && echo "${G}✔ Both YubiKeys (primary + backup) can log in everywhere.${N}" \
               || echo "${Y}! $bad gap(s) above${N}"
