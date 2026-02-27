# UniFi Docker Migration Project

## Goal
Build a Docker image for UniFi Controller 10.1.85 + MongoDB 7.0 on Ubuntu 24.04
that automatically migrates an existing MongoDB 3.6 data volume on container startup.

## Current state
- Working image: Ubuntu 20.04, UniFi 10.0.160, MongoDB 3.6
- Target image: Ubuntu 24.04, UniFi 10.1.85, MongoDB 7.0
- Test data volume is available with real 3.6 data at: ~/docker/unifi/data

## Migration strategy
MongoDB requires stepwise in-place upgrade, no version skipping:
3.6 → 4.0 → 4.2 → 4.4 → 5.0 → 6.0 → 7.0

Each step:
1. Start mongod for that version on the data directory
2. Wait until ready (mongo ping)
3. Set featureCompatibilityVersion to current version
4. Stop mongod cleanly (SIGTERM, wait for exit)
5. Proceed to next version

All logic lives in docker-entrypoint.sh / scripts/mongo-upgrade.sh.
Triggered automatically on container start, no manual intervention.

## DB version detection
Parse WiredTiger.turtle or WiredTiger.wt metadata file in the data directory.
Fallback: check for existence of version-specific files or parse last mongod.log.
Result determines which upgrade steps to skip (idempotent — already on 7.0 = no-op).

## Requirements
- Fully automatic: triggered by docker compose pull && docker compose up -d
- Idempotent: safe to run repeatedly, skips steps already completed
- Non-destructive: backup data directory to /data/db_backup_<timestamp> before any migration
- Backup must succeed before migration proceeds — abort if backup fails
- All migration activity must be logged clearly with timestamps
- If any migration step fails, stop immediately and log the error (do not proceed to next version)

## Environment
- VPS with Docker installed
- Repo path: ~/claude/unifi-docker
- Docker compse path: ~/docker/unifi/compose.yml
- Data mount path: ~/docker/unifi/volumes/unifi/data/db
- VPS OS: Debian 13

## Test procedure
1. docker compose build
2. docker compose up -d
3. docker logs -f unifi
4. Verify in logs: each migration step completed, UniFi started cleanly
5. Verify in UniFi UI that data (sites, devices, clients) is intact

## MongoDB binaries in image
Bundle mongod binaries for versions: 4.0, 4.2, 4.4, 5.0, 6.0, 7.0
Install under /usr/local/mongo/<version>/bin/mongod
Use official MongoDB Ubuntu packages — use 20.04 (focal) packages for 4.0/4.2/4.4,
22.04 (jammy) packages for 5.0/6.0, 24.04 (noble) packages for 7.0.
Only mongod binary needed per version (not full server package) to keep image size down.

## Startup sequence in docker-entrypoint.sh
1. Check if migration needed (detect DB version)
2. If yes: backup data dir, run mongo-upgrade.sh
3. Start mongod 7.0 (production config)
4. Wait for mongod ready
5. Start UniFi Controller
6. Tail logs / wait on UniFi process

## Key files
- Dockerfile
- compose.yml
- docker-entrypoint.sh
- scripts/mongo-upgrade.sh     — stepwise upgrade logic
- scripts/mongo-wait.sh        — wait-for-mongod-ready helper
- scripts/detect-db-version.sh — reads WiredTiger metadata

## Image size consideration
Bundling 6 versions of mongod will create a large image.
Acceptable trade-off for a self-contained migration.
After migration completes successfully, the old binaries are never used again
but remain in the image (removing them would require a separate image tag).
Consider adding a log warning post-migration: "Migration complete. Consider
switching to a slim image tag that excludes legacy mongo binaries."

## Out of scope
- Multi-container setup (mongo as separate container) — single container by design
- MongoDB authentication during migration — assume no auth on local socket
- Replica sets

## Git & Image
- Repo: ~/claude/unifi-docker
- Commit all changes to this repo
- Commit message format: <type>: <short description>
  Examples: feat: add mongo 5.0 upgrade step, fix: mongod wait timeout too short
- Only commit when the image builds successfully (docker build must pass)
- Do not force push, do not amend commits that have already been made

## Docker environment
- DOCKER_HOST=unix:///run/user/1000/docker.sock
- Image must be tagged: felipdocker/unifi-docker:10.1.85
- Build command: DOCKER_HOST=unix:///run/user/1000/docker.sock docker build -t felipdocker/unifi-docker:10.1.85 .

## Test environment
Location: ~/docker/unifi
Contains a compose.yml pre-configured to use felipdocker/unifi-docker:10.1.85 — read this file
before making any assumptions about volume mounts, ports, or environment variables.

Start test:
  cd ~/docker/unifi
  docker compose up -d
  docker compose logs

Revert test environment (full reset to original 3.6 data):
  cd ~/docker/unifi
  docker compose down
  sudo rm -r volumes
  sudo tar -xf volumes.tar

## Critical constraints
- Never run revert without being asked — it destroys test data
- The backup inside the container (/data/db_backup_<timestamp>) is the production safety net
- The tar revert is only for resetting the test environment between test runs
- Always confirm migration completed in logs before declaring success

## Error handling & iteration behavior
- If a build or test fails, stop and explain what failed and why before attempting a fix
- Propose the fix and wait for approval before applying it
- Maximum 2 self-correction attempts on any single problem before stopping and asking
- Do not work around errors with hacks to make output "look" correct — fix the root cause
- If a migration step fails during testing, do not modify the revert/test procedure to hide it

