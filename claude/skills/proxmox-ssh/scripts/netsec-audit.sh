#!/bin/bash
# READ-ONLY network-security audit of a Proxmox node + all its guests:
#   - Proxmox firewall per guest (NIC flag, enabled, policies, guest-isolate group)
#   - automatic updates (unattended-upgrades) per guest + host, pending host updates
#   - Tailscale: device tag + who may connect IN over the tailnet (PVE firewall can't see that traffic)
# Usage: netsec-audit.sh [root@node]   (needs an open connection: connect.sh)
G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' C=$'\033[1;36m' D=$'\033[2m' N=$'\033[0m'
NODE=${1:-root@10.0.0.84}
DIR="$(cd "$(dirname "$0")" && pwd)"
scp -q -o BatchMode=yes "$DIR/tsmap.pl" "$NODE:/tmp/.tsmap.pl" || { echo "${R}✘ can't reach $NODE - run connect.sh first${N}"; exit 1; }

ssh -o BatchMode=yes "$NODE" "G='$G' Y='$Y' R='$R' C='$C' D='$D' N='$N' bash -s" <<'REMOTE'
ok()  { printf "  ${G}✔${N} %s\n" "$*"; }
bad() { printf "  ${R}✘${N} %s\n" "$*"; }
warn(){ printf "  ${Y}!${N} %s\n" "$*"; }
uu_state() {  # run inside a guest/host: prints "on|off"
  sh -c 'dpkg -l unattended-upgrades 2>/dev/null | grep -q ^ii && grep -qs "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades && echo on || echo off'
}
echo "${C}== NODE $(hostname)${N}  $(pveversion | cut -d/ -f2)"
p=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
[ "$p" -gt 20 ] && warn "$p host packages pending - plan an 'apt full-upgrade' + reboot window" || ok "$p host packages pending"
[ "$(uu_state)" = on ] && ok "host auto-updates: $(unattended-upgrade --dry-run -v 2>&1 | grep -m1 -i 'allowed origins' | sed 's/.*: //')" || bad "host auto-updates OFF"
grep -q '^\[group guest-isolate\]' /etc/pve/firewall/cluster.fw && ok "security group guest-isolate defined" || bad "security group guest-isolate missing"
ts=$(command -v tailscale >/dev/null && tailscale status --json 2>/dev/null | perl -MJSON::PP -0777 -ne 'print join(",",@{decode_json($_)->{Self}{Tags}//[]})')
[ -n "$ts" ] && ok "tailscale tag: $ts" || warn "tailscale: none/untagged"

for id in $(pct list | awk 'NR>1{print $1}') $(qm list | awk 'NR>1{print $1}'); do
  if [ -f /etc/pve/lxc/$id.conf ]; then t=CT; c=/etc/pve/lxc/$id.conf; n=$(awk '/^hostname/{print $2}' $c); run="pct exec $id --"
    pct status $id | grep -q running || { echo "${C}-- CT$id $n${N} ${D}(stopped)${N}"; continue; }
  else t=VM; c=/etc/pve/qemu-server/$id.conf; n=$(awk '/^name:/{print $2}' $c); run=""
    qm status $id | grep -q running || { echo "${C}-- VM$id $n${N} ${D}(stopped)${N}"; continue; }
  fi
  echo "${C}-- $t$id $n${N}"
  fw=/etc/pve/firewall/$id.fw
  nic=$(grep -c 'firewall=1' $c); en=$(grep -sE '^enable: *1' $fw | wc -l)
  pin=$(sed -n 's/^policy_in: *//p' $fw 2>/dev/null); pout=$(sed -n 's/^policy_out: *//p' $fw 2>/dev/null)
  if [ "$nic" -ge 1 ] && [ "$en" -ge 1 ] && [ "$pin" = DROP ]; then
    iso=$(grep -c '^GROUP guest-isolate' $fw); lan=$(grep -cE '^OUT DROP -dest (dc/local-net|\+dc/lan6)' $fw)
    if [ "$iso" -ge 1 ] || [ "$lan" -ge 1 ] || [ "$pout" = DROP ]; then ok "firewall: in=DROP out=${pout:-ACCEPT}, LAN egress blocked $( [ $iso -ge 1 ] && echo '(guest-isolate)')"
    else warn "firewall: in=DROP but LAN egress NOT blocked (add GROUP guest-isolate)"; fi
  else bad "firewall: NOT isolating (nic-flag=$nic enabled=$en policy_in=${pin:-none})"; fi
  if [ $t = CT ]; then
    s=$($run sh -c 'dpkg -l unattended-upgrades 2>/dev/null | grep -q ^ii && grep -qs "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades && echo on || echo off')
    tsg=$($run sh -c 'command -v tailscale >/dev/null && tailscale status --json 2>/dev/null' | perl -MJSON::PP -0777 -ne 'my $j=eval{decode_json($_)}; print $j ? (join(",",@{$j->{Self}{Tags}//[]}) || "UNTAGGED") : ""')
  else
    if qm agent $id ping >/dev/null 2>&1; then
      s=$(qm guest exec $id -- sh -c 'dpkg -l unattended-upgrades 2>/dev/null | grep -q ^ii && grep -qs "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades && echo on || echo off' | perl -MJSON::PP -0777 -ne 'print decode_json($_)->{"out-data"}//""' | tr -d '\n')
      tsg=$(qm guest exec $id -- sh -c 'tailscale status --json 2>/dev/null' | perl -MJSON::PP -0777 -ne 'my $o=decode_json($_)->{"out-data"}//""; my $j=eval{decode_json($o)}; print $j ? (join(",",@{$j->{Self}{Tags}//[]}) || "UNTAGGED") : ""')
    else s="unknown (no guest agent)"; tsg=""; fi
  fi
  [ "$s" = on ] && ok "auto-updates on" || bad "auto-updates: $s"
  case "$tsg" in
    "") printf "  ${D}· no tailscale${N}\n" ;;
    UNTAGGED) bad "tailscale UNTAGGED: acts as YOU, inherits your access to every server - tag it" ;;
    *) ok "tailscale tag: $tsg" ;;
  esac
  if [ -n "$tsg" ] && [ $t = CT ]; then
    pct push $id /tmp/.tsmap.pl /tmp/.tsmap.pl 2>/dev/null && { echo "    ${D}tailnet may connect in:${N}"; $run sh -c 'tailscale debug netmap 2>/dev/null | perl /tmp/.tsmap.pl; rm -f /tmp/.tsmap.pl'; }
  fi
done
rm -f /tmp/.tsmap.pl
REMOTE
