#!/usr/bin/env bash
# Stepwise MongoDB upgrade: 3.6 → 4.0 → 4.2 → 4.4 → 5.0 → 6.0 → 7.0
# Each step: start mongod for that version, set FCV, stop cleanly.
# Idempotent: skips steps already completed (uses detect-db-version.sh).
# Usage: mongo-upgrade.sh <dbpath>

set -euo pipefail

DBPATH="${1:-/data/db}"
UPGRADE_PORT=27117
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "$(date +'[%Y-%m-%d %T,%3N]') [MIGRATION] $*"; }

# Returns 0 (true) if version $1 >= version $2
version_gte() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

VERSIONS=("4.0" "4.2" "4.4" "5.0" "6.0" "7.0")

for VERSION in "${VERSIONS[@]}"; do
    CURRENT=$("$SCRIPTS_DIR/detect-db-version.sh" "$DBPATH")
    log "Current DB version: ${CURRENT}, target step: ${VERSION}"

    # Skip if already at or past this version
    if [[ "$CURRENT" != "empty" && "$CURRENT" != "unknown" ]] \
        && version_gte "$CURRENT" "$VERSION"; then
        log "Skipping step ${VERSION} (already at ${CURRENT})"
        continue
    fi

    # Select the mongod binary for this step
    if [[ "$VERSION" == "7.0" ]]; then
        MONGOD="/usr/bin/mongod"
    else
        MONGOD="/usr/local/mongo/${VERSION}/bin/mongod"
    fi

    if [[ ! -x "$MONGOD" ]]; then
        log "ERROR: mongod binary not found or not executable: ${MONGOD}"
        exit 1
    fi

    PIDFILE="/tmp/mongod-upgrade-${VERSION}.pid"
    LOGFILE="/tmp/mongod-upgrade-${VERSION}.log"

    log "Starting mongod ${VERSION} on ${DBPATH} (port ${UPGRADE_PORT})"
    "$MONGOD" \
        --dbpath "$DBPATH" \
        --port "$UPGRADE_PORT" \
        --bind_ip 127.0.0.1 \
        --fork \
        --logpath "$LOGFILE" \
        --pidfilepath "$PIDFILE" \
        --logappend

    log "Waiting for mongod ${VERSION} to be ready..."
    "$SCRIPTS_DIR/mongo-wait.sh" 127.0.0.1 "$UPGRADE_PORT" 60

    log "Setting featureCompatibilityVersion to ${VERSION}"
    if [[ "$VERSION" == "7.0" ]]; then
        # MongoDB 7.0 requires confirm:true for FCV changes
        mongosh --quiet --host 127.0.0.1 --port "$UPGRADE_PORT" admin \
            --eval "db.adminCommand({setFeatureCompatibilityVersion: '7.0', confirm: true})"
    else
        mongosh --quiet --host 127.0.0.1 --port "$UPGRADE_PORT" admin \
            --eval "db.adminCommand({setFeatureCompatibilityVersion: '${VERSION}'})"
    fi

    log "Stopping mongod ${VERSION} cleanly"
    mongosh --quiet --host 127.0.0.1 --port "$UPGRADE_PORT" admin \
        --eval "db.adminCommand({shutdown: 1})" || true

    # Wait for mongod process to exit
    if [[ -f "$PIDFILE" ]]; then
        MGPID=$(cat "$PIDFILE")
        for i in $(seq 1 30); do
            kill -0 "$MGPID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$MGPID" 2>/dev/null; then
            log "ERROR: mongod ${VERSION} did not stop within 30s (PID ${MGPID})"
            exit 1
        fi
    else
        sleep 3
    fi

    # Write marker so the next invocation knows where we are
    echo "$VERSION" > "$DBPATH/.mongo_version"
    log "Successfully upgraded to MongoDB ${VERSION}"
done

log "Migration to MongoDB 7.0 complete"
