#!/usr/bin/env bash
# 0 */6 * * * /usr/local/sbin/ban.sh
set -euo pipefail

URL="https://raw.githubusercontent.com/jahlib/somebody-knocked-my-ssh/refs/heads/main/ban.txt"
SET_NAME="blacklist"
SET_TMP="${SET_NAME}_tmp"
LOCK_FILE="/run/blacklist-sync.lock"
IPTABLES_COMMENT="ipset-blacklist-drop"
# -----------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

# ---------- инструменты ----------
ensure_ipset_installed() {
  command -v ipset &>/dev/null && return 0
  log "ipset not found, installing..."
  if   command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y ipset
  elif command -v dnf &>/dev/null; then dnf install -y ipset
  elif command -v yum &>/dev/null; then yum install -y ipset
  elif command -v apk &>/dev/null; then apk add --no-cache ipset
  else die "ipset not installed and no supported package manager found"
  fi
  command -v ipset &>/dev/null || die "ipset install failed"
  log "ipset installed"
}

ensure_iptables() {
  if ! iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP \
       -m comment --comment "$IPTABLES_COMMENT" 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$SET_NAME" src -j DROP \
      -m comment --comment "$IPTABLES_COMMENT"
    log "Added iptables DROP rule"
  fi
}

# ---------- основная работа ----------
ensure_ipset_installed

# Заблокировать параллельный запуск
exec {lock_fd}>"$LOCK_FILE"
flock -n "$lock_fd" || die "Already running"

tmp=$(mktemp)
restore_file=$(mktemp)
trap 'rm -f "$tmp" "$restore_file"' EXIT

# Скачать список
log "Downloading list from $URL ..."
if command -v curl &>/dev/null; then
  curl -fsSL --connect-timeout 15 --max-time 120 "$URL" -o "$tmp"
elif command -v wget &>/dev/null; then
  wget -q -T 120 -O "$tmp" "$URL"
else
  die "Need curl or wget"
fi
[[ -s $tmp ]] || die "Empty list from $URL"

# Валидация и сборка restore-файла для временного сета
invalid=0
total_valid=0

# Заголовок restore-файла
echo "create ${SET_TMP} hash:net family inet maxelem 1048576" > "$restore_file"

while IFS= read -r line; do
  # убрать комментарии и пробелы
  line="${line%%#*}"
  line="${line//[[:space:]]/}"
  [[ -z "$line" ]] && continue

  # Быстрая валидация: IPv4 или IPv4/prefix
  if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
    echo "add ${SET_TMP} ${line}" >> "$restore_file"
    ((total_valid++)) || true
  else
    ((invalid++)) || true
  fi
done < "$tmp"

echo "COMMIT" >> "$restore_file"

[[ $total_valid -gt 0 ]] || die "No valid entries in downloaded list"

# Уничтожить старый временный сет если остался с прошлого раза
ipset destroy "$SET_TMP" 2>/dev/null || true

# Загрузить весь список одной командой (bulk restore)
log "Loading $total_valid entries via ipset restore ..."
ipset restore < "$restore_file"

# Убедиться что основной сет существует (первый запуск)
if ! ipset list "$SET_NAME" &>/dev/null; then
  ipset create "$SET_NAME" hash:net family inet maxelem 1048576
  log "Created ipset: $SET_NAME"
fi

# Атомарно подменить живой сет временным
ipset swap "$SET_TMP" "$SET_NAME"

# Убрать старый (теперь он называется SET_TMP после swap)
ipset destroy "$SET_TMP"

# Добавить iptables правило (если ещё нет — теперь сет точно существует)
ensure_iptables

total=$(ipset list "$SET_NAME" | awk '/Number of entries/ {print $4}')
log "done: loaded=${total_valid} invalid=${invalid} total_in_set=${total}"
