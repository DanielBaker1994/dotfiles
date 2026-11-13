set -e
KEYS="$(cat)"
for id in "$@"; do
  echo "--- CT $id ---"
  printf '%s\n' "$KEYS" | pct exec "$id" -- sh -c '
    set -e
    command -v sshd >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server; }
    install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    while IFS= read -r k; do [ -n "$k" ] && { grep -qxF "$k" /root/.ssh/authorized_keys || echo "$k" >> /root/.ssh/authorized_keys; }; done
    cat > /etc/ssh/sshd_config.d/10-yubikey.conf <<CONF
# Managed by Claude proxmox-ssh skill: hardware-key-only root login
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PubkeyAcceptedAlgorithms sk-ssh-ed25519@openssh.com,sk-ecdsa-sha2-nistp256@openssh.com
CONF
    sshd -t
    systemctl enable --now ssh >/dev/null 2>&1 || true
    systemctl reload ssh || systemctl restart ssh
    echo "keys: $(wc -l < /root/.ssh/authorized_keys)"; sshd -T 2>/dev/null | grep -Ei "^(permitrootlogin|passwordauthentication|pubkeyacceptedalgorithms) "
  '
done
