#!/bin/bash
# READ-ONLY leak sweep of a Proxmox node + every running LXC (pct exec) and VM
# (qm guest exec, needs qemu-guest-agent). Prints paths/perms/categories only.
# Usage: leak-scan.sh [root@node] [--skip VMID,VMID]   (needs an open connection: connect.sh)
G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' C=$'\033[1;36m' D=$'\033[2m' N=$'\033[0m'
NODE=${1:-root@10.0.0.84}; SKIP=${3:-}; [ "$2" = --skip ] || SKIP=""
GUEST="$(dirname "$0")/leak-scan-guest.sh"
B64=$(base64 < "$GUEST" | tr -d '\n')

out=$(ssh -o BatchMode=yes "$NODE" "SKIP='$SKIP' B64='$B64' bash -s" <<'REMOTE'
echo "$B64" | base64 -d > /tmp/.leakscan.sh
echo "@@ node $(hostname)"; sh /tmp/.leakscan.sh
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
  echo ",$SKIP," | grep -q ",$id," && continue
  echo "@@ CT$id $(pct config $id | awk '/^hostname:/{print $2}')"
  pct push $id /tmp/.leakscan.sh /tmp/.leakscan.sh && pct exec $id -- sh /tmp/.leakscan.sh; pct exec $id -- rm -f /tmp/.leakscan.sh
done
for id in $(qm list | awk 'NR>1 && $3=="running"{print $1}'); do
  echo ",$SKIP," | grep -q ",$id," && continue
  echo "@@ VM$id $(qm config $id | awk '/^name:/{print $2}')"
  if qm agent $id ping >/dev/null 2>&1; then
    qm guest exec $id --timeout 600 --pass-stdin 1 -- sh -s < /tmp/.leakscan.sh 2>&1 |
      perl -MJSON::PP -0777 -ne 'my $j=eval{decode_json($_)}; print $j ? ($j->{"out-data"}//"") : $_'
  else echo "SKIPPED|no guest agent||"; fi
done
rm -f /tmp/.leakscan.sh
REMOTE
) || { echo "${R}✘ can't reach $NODE - run connect.sh first${N}"; exit 1; }

echo "${C}== Leak scan: $NODE${N} ${D}(paths and permissions only, no secret values)${N}"
printf '%s\n' "$out" | awk -F'|' -v G="$G" -v Y="$Y" -v R="$R" -v C="$C" -v D="$D" -v N="$N" '
  /^@@ /{sub(/^@@ /,""); printf "\n%s%s%s\n", C, $0, N; next}
  NF<2 {next}
  { col=Y
    if ($1=="PRIVKEY" && $4 ~ /^expected/) col=D
    if ($1=="PRIVKEY" && $4 !~ /^expected/) col=R
    if ($1=="TOKEN"||$1=="CREDFILE") col=R
    if ($1=="ENVFILE" && $4 ~ /^ok/) col=G
    if ($1=="ENVFILE" && $4 !~ /^ok/) col=R
    if ($1=="HISTORY" && $4 ~ / 0 secret/) col=D
    printf "  %s%-8s%s %s %s[%s] %s%s\n", col, $1, N, $2, D, $3, $4, N }'
