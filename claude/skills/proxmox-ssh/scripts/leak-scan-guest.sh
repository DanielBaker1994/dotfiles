#!/bin/sh
# READ-ONLY secret/leak scan, run INSIDE one guest (or a node) as root.
# Prints only paths + mode/owner + a category. NEVER prints secret values.
# Output lines: CATEGORY|path|mode owner:group|note
# Categories: PRIVKEY, CREDFILE, TOKEN, HISTORY, ENVFILE, ARCHIVE, ENVMOUNT
ROOTS="/root /home /opt /srv /etc /var/www /var/lib/docker/volumes /usr/local/etc"
# Dependency caches / library test fixtures ship fake keys: skip them (they are not your secrets)
SKIP='/proc/|/sys/|/dev/|/run/|/var/lib/docker/overlay2/|/var/lib/containerd/|Plex Media Server/(Media|Metadata|Cache|Crash Reports)|/node_modules/|/\.cache/|/usr/share/|/etc/ssl/certs/|/\.git/objects/|/go/pkg/mod/|/pnpm/store/|/site-packages/|/dist-packages/|/\.?venv/|-venv/|/(testdata|test-data|SelfTest|fixtures|e2e-auth-server)/'

meta() { stat -c '%a %U:%G' "$1" 2>/dev/null; }
files() {  # small regular files under the roots, minus noisy trees
  for r in $ROOTS; do [ -d "$r" ] && find "$r" -xdev -type f -size -1024k 2>/dev/null; done | grep -Ev "$SKIP"
}
LIST=$(mktemp); files > "$LIST"

# 1) private keys (PEM/OpenSSH). SSH host keys + /etc/ssl/private are expected.
tr '\n' '\0' < "$LIST" | xargs -0 -r grep -lIE -- '-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----' 2>/dev/null |
while IFS= read -r f; do
  case "$f" in
    /etc/ssh/ssh_host_*) n="expected: this machine's SSH host key" ;;
    /etc/ssl/private/*|/etc/pve/*|/etc/pve-ssl*) n="expected: TLS/system key" ;;
    /root/.ssh/id_rsa) if [ -d /etc/pve ]; then n="expected: Proxmox node key (managed by PVE; sk-only sshd rejects it)"; else n="USER SSH PRIVATE KEY"; fi ;;
    */.ssh/*) n="USER SSH PRIVATE KEY" ;;
    *) n="private key file" ;;
  esac
  echo "PRIVKEY|$f|$(meta "$f")|$n"
done

# 2) well-known credential files by name
grep -E '/(\.git-credentials|\.netrc|\.pgpass|\.my\.cnf|rclone\.conf|credentials\.json|\.credentials\.json|hosts\.yml|config\.json|kubeconfig)$|/\.aws/credentials$|/\.kube/config$|/\.docker/config\.json$|/\.config/gh/hosts\.yml$' "$LIST" |
while IFS= read -r f; do
  case "$f" in */.docker/config.json) grep -q '"auths": *{ *}' "$f" 2>/dev/null && continue ;; esac
  case "$f" in */config.json) case "$f" in */.docker/*|*/.claude*|*/gh/*) ;; *) continue ;; esac ;; esac
  echo "CREDFILE|$f|$(meta "$f")|credential store"
done

# 3) token-shaped strings in non-env files (pattern name only, never the value)
tr '\n' '\0' < "$LIST" | xargs -0 -r grep -lIE 'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20}|sk-ant-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}' 2>/dev/null |
grep -vE '(^|/)\.env|\.env$|\.env\.|_history$' |
while IFS= read -r f; do
  p=$(grep -oE 'ghp_|github_pat_|glpat-|sk-ant-|AKIA|xox[baprs]-' "$f" 2>/dev/null | sort -u | tr '\n' ' ')
  echo "TOKEN|$f|$(meta "$f")|looks like: $p"
done

# 4) shell/REPL histories: count lines that look like they contain secrets
grep -E '/\.[a-z_]*history$|/\.bash_history|/\.zsh_history|/\.python_history|/\.mysql_history|/\.psql_history' "$LIST" |
while IFS= read -r f; do
  c=$(grep -ciE 'passw|token|secret|api[_-]?key|bearer|authorization:|-p[^ ]{4,}|ghp_|sk-|AKIA|--password' "$f" 2>/dev/null)
  echo "HISTORY|$f|$(meta "$f")|$(wc -l < "$f") lines, $c secret-looking"
done

# 5) env files: permissions only (contents never read beyond this stat)
grep -E '/\.env$|/\.env\.[^/]*$|\.env$|/[^/]*\.env\.bak[^/]*$' "$LIST" |
while IFS= read -r f; do
  m=$(stat -c '%a' "$f"); o=$(echo "$m" | cut -c3); g=$(echo "$m" | cut -c2)
  n="ok"; [ "$o" != 0 ] && n="WORLD-READABLE"; case "$g" in 2|3|6|7) n="$n GROUP-WRITABLE";; esac
  case "$f" in *.example|*/example.env|*.sample) [ "$n" = "WORLD-READABLE" ] && n="ok (template)";; esac
  echo "ENVFILE|$f|$(meta "$f")|$n"
done

# 6) archives/backups in home dirs (may hold old keys/history)
for d in /root /home/*; do [ -d "$d" ] && find "$d" -maxdepth 2 -type f \( -name '*.tar*' -o -name '*.tgz' -o -name '*.zip' -o -name '*.bak*' \) 2>/dev/null; done |
while IFS= read -r f; do echo "ARCHIVE|$f|$(meta "$f")|$(du -h "$f" | cut -f1)"; done

# 7) env files bind-mounted into containers (so perms changes don't break them)
command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}}|{{.Config.User}}|{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null |
while IFS='|' read -r n u m; do
  for s in $m; do case "$s" in *.env|*/.env*|*env*) echo "ENVMOUNT|$s|$(meta "$s")|mounted into $n (user '${u:-root}')";; esac; done
done
rm -f "$LIST"
