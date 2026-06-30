#!/usr/bin/env bash
# Scan ban.txt for duplicate lines, report them, rewrite file without duplicates.
# First occurrence of each line is kept; order is preserved.
#
# Usage:
#   bash dedupe_ban.sh
#   BAN_FILE=/path/to/ban.txt bash dedupe_ban.sh
#
# Exit codes: 0 = no duplicates (file unchanged), 1 = error, 2 = duplicates removed

set -euo pipefail

BAN_FILE="${BAN_FILE:-ban.txt}"

if [[ ! -f "$BAN_FILE" ]]; then
    echo "error: file not found: $BAN_FILE" >&2
    exit 1
fi

TMP="$(mktemp /tmp/banhammer.dedupe.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

exec 9<"$BAN_FILE"
if ! flock -w 10 9; then
    echo "error: could not lock $BAN_FILE" >&2
    exit 1
fi

before=$(wc -l < "$BAN_FILE" | tr -d '[:space:]')

awk '!seen[$0]++ { sub(/\r$/, ""); print }' "$BAN_FILE" > "$TMP"

after=$(wc -l < "$TMP" | tr -d '[:space:]')
removed=$((before - after))

if (( removed == 0 )); then
    echo "no duplicates ($before lines)"
    exit 0
fi

echo "duplicates found:"
awk '
    {
        sub(/\r$/, "")
        count[$0]++
    }
    END {
        for (line in count) {
            if (count[line] > 1) {
                printf "  %dx %s\n", count[line], line
            }
        }
    }
' "$BAN_FILE" | sort -k3

mv "$TMP" "$BAN_FILE"
trap - EXIT

echo "removed $removed duplicate line(s); $after unique lines remain"
exit 2
