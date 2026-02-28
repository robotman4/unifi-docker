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

# Returns 0 (true) if version $1 > version $2 (strictly greater)
version_gt() {
    version_gte "$1" "$2" && [ "$1" != "$2" ]
}

# Download mongod binary (and legacy mongo shell for 4.0) for a given version.
# No-op if the binary already exists at /usr/local/mongo/<ver>/bin/mongod.
# On failure: logs error and exits 1.
download_mongod() {
    local ver="$1"
    local dest="/usr/local/mongo/${ver}/bin"
    local mongod_bin="${dest}/mongod"

    # Already present — skip download (e.g. pre-installed via volume mount)
    if [[ -x "$mongod_bin" ]]; then
        log "mongod ${ver} binary already present, skipping download"
        return 0
    fi

    local name url tarball
    case "$ver" in
        4.0) name="mongodb-linux-x86_64-ubuntu1804-4.0.28" ;;
        4.2) name="mongodb-linux-x86_64-ubuntu1804-4.2.25" ;;
        4.4) name="mongodb-linux-x86_64-ubuntu2004-4.4.29" ;;
        5.0) name="mongodb-linux-x86_64-ubuntu2004-5.0.31" ;;
        6.0) name="mongodb-linux-x86_64-ubuntu2204-6.0.20" ;;
        *)   log "ERROR: No download URL configured for mongod ${ver}"; exit 1 ;;
    esac
    url="https://fastdl.mongodb.org/linux/${name}.tgz"
    tarball="/tmp/mongod-${ver}.tgz"

    log "Downloading mongod ${ver} from ${url}..."
    mkdir -p "$dest"
    if ! wget -q "$url" -O "$tarball"; then
        log "ERROR: Failed to download mongod ${ver} from ${url}"
        rm -f "$tarball"
        exit 1
    fi

    tar xzf "$tarball" --strip-components=2 -C "$dest" "${name}/bin/mongod"
    chmod +x "$mongod_bin"

    # 4.0 also needs the legacy mongo shell — mongosh requires wire protocol v8 (MongoDB 4.2+)
    if [[ "$ver" == "4.0" ]]; then
        tar xzf "$tarball" --strip-components=2 -C "$dest" "${name}/bin/mongo"
        chmod +x "${dest}/mongo"
    fi

    rm -f "$tarball"
    log "mongod ${ver} ready at ${mongod_bin}"
}

VERSIONS=("4.0" "4.2" "4.4" "5.0" "6.0" "7.0")

for VERSION in "${VERSIONS[@]}"; do
    # Idempotency: only skip if the .mongo_version marker confirms this step was completed.
    # Never skip based on WiredTiger format alone — the FCV in admin.system.version may not
    # match the WiredTiger format (e.g. prior session upgraded WT but never set FCV).
    MARKER=$(cat "$DBPATH/.mongo_version" 2>/dev/null || echo "")
    if [[ -n "$MARKER" ]] && version_gte "$MARKER" "$VERSION"; then
        log "Skipping step ${VERSION} (completed, marker=${MARKER})"
        continue
    fi

    # Download binary on-demand (no-op if already present or version is 7.0)
    if [[ "$VERSION" != "7.0" ]]; then
        download_mongod "$VERSION"
    fi

    # Safety: if the current WiredTiger format is strictly newer than what this step's mongod
    # binary supports, running it would fail. Abort with a clear message instead.
    WT_VER=$("$SCRIPTS_DIR/detect-db-version.sh" "$DBPATH")
    log "Step ${VERSION}: WiredTiger format=${WT_VER}, marker=${MARKER}"
    if [[ "$WT_VER" != "empty" && "$WT_VER" != "unknown" ]] \
        && version_gt "$WT_VER" "$VERSION"; then
        log "ERROR: WiredTiger data (${WT_VER}) is newer than step ${VERSION}."
        log "ERROR: A previous failed run may have partially upgraded the data."
        log "ERROR: Restore /data/db from backup before retrying migration."
        exit 1
    fi

    # Select the mongod binary and the appropriate mongo client for this step.
    # mongosh requires wire protocol v8 (MongoDB 4.2+); mongod 4.0 only supports v7.
    # Use the legacy mongo shell bundled with the 4.0 tarball for the 4.0 step only.
    if [[ "$VERSION" == "7.0" ]]; then
        MONGOD="/usr/bin/mongod"
        MONGO_CLI="mongosh"
    elif [[ "$VERSION" == "4.0" ]]; then
        MONGOD="/usr/local/mongo/4.0/bin/mongod"
        MONGO_CLI="/usr/local/mongo/4.0/bin/mongo"
    else
        MONGOD="/usr/local/mongo/${VERSION}/bin/mongod"
        MONGO_CLI="mongosh"
    fi

    if [[ ! -x "$MONGOD" ]]; then
        log "ERROR: mongod binary not found or not executable: ${MONGOD}"
        exit 1
    fi
    if [[ ! -x "$MONGO_CLI" ]] && [[ "$MONGO_CLI" != "mongosh" ]]; then
        log "ERROR: mongo client not found or not executable: ${MONGO_CLI}"
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
    "$SCRIPTS_DIR/mongo-wait.sh" 127.0.0.1 "$UPGRADE_PORT" 60 "$MONGO_CLI"

    log "Setting featureCompatibilityVersion to ${VERSION}"
    if [[ "$VERSION" == "7.0" ]]; then
        # MongoDB 7.0 requires confirm:true for FCV changes
        "$MONGO_CLI" --quiet --host 127.0.0.1 --port "$UPGRADE_PORT" admin \
            --eval "db.adminCommand({setFeatureCompatibilityVersion: '7.0', confirm: true})"
    else
        "$MONGO_CLI" --quiet --host 127.0.0.1 --port "$UPGRADE_PORT" admin \
            --eval "db.adminCommand({setFeatureCompatibilityVersion: '${VERSION}'})"
    fi

    log "Stopping mongod ${VERSION} cleanly"
    "$MONGO_CLI" --quiet --host 127.0.0.1 --port "$UPGRADE_PORT" admin \
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

    # Clean up migration binary immediately — it is never needed again
    if [[ "$VERSION" != "7.0" ]]; then
        rm -rf "/usr/local/mongo/${VERSION}"
        log "Cleaned up mongod ${VERSION} binaries"
    fi
done

log "Migration to MongoDB 7.0 complete"
