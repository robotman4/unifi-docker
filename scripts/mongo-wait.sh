#!/usr/bin/env bash
# Wait for mongod to become ready (responds to ping).
# Usage: mongo-wait.sh <host> <port> [timeout_seconds] [mongo_cli]
#   mongo_cli: path to mongo client binary (default: mongosh).
#              Use the legacy mongo shell for mongod 4.0, which only supports wire protocol v7
#              and cannot be reached by mongosh (which requires wire protocol v8 / MongoDB 4.2+).

HOST=${1:-127.0.0.1}
PORT=${2:-27017}
TIMEOUT=${3:-60}
MONGO_CLI="${4:-mongosh}"

for i in $(seq 1 "$TIMEOUT"); do
    "$MONGO_CLI" --quiet --host "$HOST" --port "$PORT" \
        --eval "db.adminCommand('ping')" >/dev/null 2>&1 \
        && echo "mongod ready after ${i}s" && exit 0
    sleep 1
done

echo "ERROR: mongod did not become ready within ${TIMEOUT}s" >&2
exit 1
