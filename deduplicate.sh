#!/usr/bin/env bash
# Scan ban.txt: drop invalid IPv4/CIDR lines, remove duplicates, rewrite file.
# Keeps first occurrence of each valid line; order is preserved.
#
# Usage:
#   bash dedupe_ban.sh
#   BAN_FILE=/path/to/ban.txt bash dedupe_ban.sh
#
# Exit codes: 0 = file unchanged, 1 = error, 2 = lines were removed

set -euo pipefail

BAN_FILE="${BAN_FILE:-ban.txt}"

if [[ ! -f "$BAN_FILE" ]]; then
    echo "error: file not found: $BAN_FILE" >&2
    exit 1
fi

TMP="$(mktemp /tmp/banhammer.dedupe.XXXXXX)"
REPORT="$(mktemp /tmp/banhammer.dedupe.report.XXXXXX)"
STATS="$(mktemp /tmp/banhammer.dedupe.stats.XXXXXX)"
trap 'rm -f "$TMP" "$REPORT" "$STATS"' EXIT

exec 9<"$BAN_FILE"
if ! flock -w 10 9; then
    echo "error: could not lock $BAN_FILE" >&2
    exit 1
fi

before=$(wc -l < "$BAN_FILE" | tr -d '[:space:]')

awk -v report_file="$REPORT" -v stats_file="$STATS" '
function trim_cr(line) {
    sub(/\r$/, "", line)
    return line
}

function only_ip_chars(line) {
    return line ~ /^[0-9.]+$/
}

function only_cidr_chars(line) {
    return line ~ /^[0-9.\/]+$/
}

function valid_octet(octet,    value) {
    if (octet == "" || length(octet) > 3) {
        return 0
    }
    if (octet !~ /^[0-9]+$/) {
        return 0
    }
    value = octet + 0
    if (value > 255) {
        return 0
    }
    if (length(octet) > 1 && substr(octet, 1, 1) == "0") {
        return 0
    }
    return 1
}

function valid_ipv4(ip,    parts, i, n) {
    if (!only_ip_chars(ip)) {
        return 0
    }
    n = split(ip, parts, ".")
    if (n != 4) {
        return 0
    }
    for (i = 1; i <= 4; i++) {
        if (!valid_octet(parts[i])) {
            return 0
        }
    }
    return 1
}

function valid_cidr(line,    slash, ip, mask, mask_num) {
    if (!only_cidr_chars(line)) {
        return 0
    }
    slash = index(line, "/")
    if (slash == 0) {
        return 0
    }
    if (index(substr(line, slash + 1), "/") > 0) {
        return 0
    }
    ip = substr(line, 1, slash - 1)
    mask = substr(line, slash + 1)
    if (mask == "" || mask !~ /^[0-9]+$/) {
        return 0
    }
    if (length(mask) > 2) {
        return 0
    }
    if (length(mask) > 1 && substr(mask, 1, 1) == "0") {
        return 0
    }
    mask_num = mask + 0
    if (mask_num < 0 || mask_num > 32) {
        return 0
    }
    return valid_ipv4(ip)
}

function valid_ban_line(line) {
    if (line == "") {
        return 0
    }
    if (index(line, "/") > 0) {
        return valid_cidr(line)
    }
    return valid_ipv4(line)
}

function show_line(line) {
    if (line == "") {
        return "(empty line)"
    }
    return line
}

{
    line = trim_cr($0)

    if (!valid_ban_line(line)) {
        invalid[++invalid_count] = line
        next
    }

    count[line]++
    if (!seen[line]++) {
        print line
    }
}
END {
    dup_count = 0
    for (line in count) {
        if (count[line] > 1) {
            dup_count++
        }
    }
    print invalid_count + 0 > stats_file
    print dup_count + 0 >> stats_file
    close(stats_file)

    for (i = 1; i <= invalid_count; i++) {
        printf "INVALID\t%s\n", show_line(invalid[i]) >> report_file
    }
    for (line in count) {
        if (count[line] > 1) {
            printf "DUPLICATE\t%dx %s\n", count[line], line >> report_file
        }
    }
    close(report_file)
}
' "$BAN_FILE" > "$TMP"

mapfile -t stats < "$STATS"
invalid_removed=${stats[0]:-0}
duplicate_groups=${stats[1]:-0}

after=$(wc -l < "$TMP" | tr -d '[:space:]')
removed=$((before - after))

if (( removed == 0 )); then
    echo "ok: $before valid unique lines, nothing to remove"
    exit 0
fi

if (( invalid_removed > 0 )); then
    echo "invalid lines removed:"
    awk -F '\t' '$1 == "INVALID" { print "  " $2 }' "$REPORT" | sort
fi

if (( duplicate_groups > 0 )); then
    echo "duplicates found:"
    awk -F '\t' '$1 == "DUPLICATE" { print "  " $2 }' "$REPORT" | sort -k2
fi

mv "$TMP" "$BAN_FILE"
trap - EXIT

echo "removed $removed line(s) total; $after valid unique lines remain"
sudo chmod 775 "$BAN_FILE"
exit 2
