#!/usr/bin/env bash
# 0 */6 * * * /usr/local/sbin/ban.sh
set -euo pipefail

URL="https://raw.githubusercontent.com/jahlib/somebody-knocked-my-ssh/refs/heads/main/ban.txt"
SET_NAME="blacklist"
REMOVE_ORPHANS=1          # 0 = только добавлять, 1 = зеркалить файл (удалять лишнее)
LOCK_FILE="/run/blacklist-sync.lock"
IPTABLES_COMMENT="ipset-blacklist-drop"
# ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

ensure_ipset_installed() {
  command -v ipset &>/dev/null && return 0
  log "ipset not found, installing..."
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y ipset
  elif command -v dnf &>/dev/null; then
    dnf install -y ipset
  elif command -v yum &>/dev/null; then
    yum install -y ipset
  elif command -v apk &>/dev/null; then
    apk add --no-cache ipset
  else
    die "ipset not installed and no supported package manager found"
  fi
  command -v ipset &>/dev/null || die "ipset install failed"
  log "ipset installed"
}

valid_octets() {
  local IFS=.
  read -r o1 o2 o3 o4 <<<"$1"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ $o =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
}

is_valid_net() {
  local entry=$1 ip prefix
  if [[ $entry == */* ]]; then
    ip=${entry%/*}
    prefix=${entry#*/}
    [[ $prefix =~ ^[0-9]+$ ]] || return 1
    ((prefix >= 0 && prefix <= 32)) || return 1
  else
    ip=$entry
  fi
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  valid_octets "$ip"
}

entry_in_list() {
  local e=$1
  grep -Fxq "$e" "$tmp" && return 0
  if [[ $e == */32 ]]; then
    grep -Fxq "${e%/32}" "$tmp" && return 0
  elif [[ $e != */* ]]; then
    grep -Fxq "${e}/32" "$tmp" && return 0
  fi
  return 1
}

ensure_ipset() {
  if ipset list "$SET_NAME" &>/dev/null; then
    local t
    t=$(ipset list "$SET_NAME" | awk '/^Type:/ {print $2}')
    [[ $t == "hash:net" ]] || die "Set $SET_NAME is $t, need hash:net. Run: ipset destroy $SET_NAME"
  else
    ipset create "$SET_NAME" hash:net maxelem 1048576
    log "Created ipset: $SET_NAME (hash:net)"
  fi
}

ensure_iptables() {
  if ! iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP -m comment --comment "$IPTABLES_COMMENT" 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$SET_NAME" src -j DROP -m comment --comment "$IPTABLES_COMMENT"
    log "Added iptables DROP rule"
  fi
}

download_list() {
  local dest=$1
  if command -v curl &>/dev/null; then
    curl -fsSL --connect-timeout 15 --max-time 120 "$URL" -o "$dest"
  elif command -v wget &>/dev/null; then
    wget -q -T 120 -O "$dest" "$URL"
  else
    die "Need curl or wget"
  fi
  [[ -s $dest ]] || die "Empty list from $URL"
}

exec {lock_fd}>"$LOCK_FILE"
flock -n "$lock_fd" || die "Already running"

ensure_ipset_installed
ensure_ipset
ensure_iptables

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

download_list "$tmp"
grep -vE '^\s*(#|$)' "$tmp" | sed 's/[[:space:]]//g' >"${tmp}.clean"
mv "${tmp}.clean" "$tmp"

added=0 skipped=0 invalid=0 removed=0

while IFS= read -r entry || [[ -n ${entry:-} ]]; do
  [[ -z $entry ]] && continue
  if ! is_valid_net "$entry"; then
    ((invalid++)) || true
    continue
  fi
  if ipset test "$SET_NAME" "$entry" &>/dev/null; then
    ((skipped++)) || true
  else
    ipset add "$SET_NAME" "$entry"
    ((added++)) || true
  fi
done <"$tmp"

if [[ $REMOVE_ORPHANS == 1 ]]; then
  while IFS= read -r entry; do
    [[ -z $entry ]] && continue
    if ! entry_in_list "$entry"; then
      ipset del "$SET_NAME" "$entry" 2>/dev/null && ((removed++)) || true
    fi
  done < <(ipset list "$SET_NAME" | awk '/^[0-9]+\./ {print $1}')
fi

total=$(ipset list "$SET_NAME" | awk '/Number of entries/ {print $4}')
log "done: added=$added skipped=$skipped invalid=$invalid removed=$removed total=$total"
