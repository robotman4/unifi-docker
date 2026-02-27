#!/usr/bin/env bash
# Detect the MongoDB version of a WiredTiger data directory.
# Usage: detect-db-version.sh <dbpath>
# Output: version string (e.g. "3.6", "4.4", "7.0"), "empty", or "unknown"
# Exit: always 0 — caller decides what to do.

DBPATH="${1:-/data/db}"

# No directory or empty directory → fresh install, no migration needed
if [[ ! -d "$DBPATH" ]] || [[ -z "$(ls -A "$DBPATH" 2>/dev/null)" ]]; then
    echo "empty"
    exit 0
fi

# Marker file written by mongo-upgrade.sh after each successful step
if [[ -f "$DBPATH/.mongo_version" ]]; then
    cat "$DBPATH/.mongo_version"
    exit 0
fi

# WiredTiger.turtle is a text file present in every WiredTiger data directory.
# The WiredTiger major version maps reliably to MongoDB major version:
#   WT 2.x  → MongoDB 3.6
#   WT 3.1  → MongoDB 4.0
#   WT 3.2  → MongoDB 4.2
#   WT 3.3+ → MongoDB 4.4
#   WT 10.x → MongoDB 5.0  (conservative; re-running the 5.0 FCV step is a no-op)
#   WT 11.x → MongoDB 7.0
TURTLE="$DBPATH/WiredTiger.turtle"
if [[ -f "$TURTLE" ]]; then
    WT_MAJOR=$(grep -oE 'WiredTiger version major: [0-9]+' "$TURTLE" | grep -oE '[0-9]+$' | head -1)
    WT_MINOR=$(grep -oE 'WiredTiger version minor: [0-9]+' "$TURTLE" | grep -oE '[0-9]+$' | head -1)
    if [[ -n "$WT_MAJOR" ]]; then
        case "$WT_MAJOR" in
            2)  echo "3.6" ;;
            3)  case "${WT_MINOR:-0}" in
                    1) echo "4.0" ;;
                    2) echo "4.2" ;;
                    *) echo "4.4" ;;   # 3.3 = MongoDB 4.4
                esac ;;
            10) echo "5.0" ;;          # WT 10 covers both 5.0 and 6.0; treat as 5.0 (idempotent)
            11) echo "7.0" ;;
            *)  echo "unknown" ;;
        esac
        exit 0
    fi
fi

# Fallback: parse mongod.log for a version string
for LOGFILE in "/unifi/log/mongod.log" "$DBPATH/../mongod.log"; do
    if [[ -f "$LOGFILE" ]]; then
        # JSON structured log (MongoDB 4.4+): "version":"X.Y.Z"
        VER=$(grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' "$LOGFILE" 2>/dev/null \
              | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ -n "$VER" ]]; then echo "$VER"; exit 0; fi

        # Legacy text log (MongoDB 3.6/4.0): "db version vX.Y.Z"
        VER=$(grep -oE 'db version v[0-9]+\.[0-9]+' "$LOGFILE" 2>/dev/null \
              | tail -1 | grep -oE '[0-9]+\.[0-9]+')
        if [[ -n "$VER" ]]; then echo "$VER"; exit 0; fi
    fi
done

echo "unknown"
exit 0
