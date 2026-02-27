#!/usr/bin/env bash
# Wait for mongod to become ready (responds to ping).
# Usage: mongo-wait.sh <host> <port> [timeout_seconds]

HOST=${1:-127.0.0.1}
PORT=${2:-27017}
TIMEOUT=${3:-60}

for i in $(seq 1 "$TIMEOUT"); do
    mongosh --quiet --host "$HOST" --port "$PORT" \
        --eval "db.adminCommand('ping')" >/dev/null 2>&1 \
        && echo "mongod ready after ${i}s" && exit 0
    sleep 1
done

echo "ERROR: mongod did not become ready within ${TIMEOUT}s" >&2
exit 1
