echo "=== HOST ==="; hostname; pveversion
echo; echo "=== LXC ==="; pct list
for id in $(pct list | awk 'NR>1{print $1}'); do
  echo; echo "--- CT $id ---"
  pct config "$id" | grep -E '^(hostname|net[0-9]|unprivileged|ostype|onboot)'
  if pct status "$id" | grep -q running; then
    pct exec "$id" -- sh -c '
      . /etc/os-release 2>/dev/null; echo "os: $PRETTY_NAME"
      echo "ips: $(ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | tr "\n" " ")"
      if command -v sshd >/dev/null 2>&1; then echo "sshd: $(sshd -V 2>&1 | head -1)"; else echo "sshd: NOT INSTALLED"; fi
      echo "listening22: $(ss -ltn 2>/dev/null | grep -c ":22 ")"
      [ -f /root/.ssh/authorized_keys ] && echo "root authorized_keys lines: $(wc -l < /root/.ssh/authorized_keys)"
      echo "users: $(awk -F: "\$3>=1000 && \$3<65534 {print \$1}" /etc/passwd | tr "\n" " ")"
    ' 2>&1
  else
    echo "status: stopped"
  fi
done
echo; echo "=== VMs ==="; qm list
for id in $(qm list | awk 'NR>1{print $1}'); do
  echo; echo "--- VM $id ---"
  qm config "$id" | grep -E '^(name|net[0-9]|agent|ostype|onboot)'
  if qm status "$id" | grep -q running; then
    if qm agent "$id" ping >/dev/null 2>&1; then
      echo "guest-agent: OK"
      qm guest cmd "$id" get-osinfo 2>/dev/null | grep -E '"(pretty-name|id)"'
      qm guest cmd "$id" network-get-interfaces 2>/dev/null | grep -E '"ip-address"' | grep -vE '127\.0\.0\.1|::1|fe80'
      qm guest exec "$id" -- sh -c 'command -v sshd && sshd -V 2>&1 | head -1; ls /root/.ssh 2>&1' 2>&1 | head -20
    else
      echo "guest-agent: NOT RESPONDING"
    fi
  else
    echo "status: stopped"
  fi
done
