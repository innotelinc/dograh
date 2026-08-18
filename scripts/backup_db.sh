#!/usr/bin/env bash
set -euo pipefail

# Nightly pg_dump backup of the Dograh database to MinIO.
#
# Runs from cron (see the install instructions at the bottom of this file).
# Dumps the postgres container's database with pg_dump in custom format
# (compressed, restore with pg_restore), uploads it to a MinIO bucket via
# the minio/mc image, and prunes backups older than RETENTION_DAYS.
#
# Usage:
#   ./scripts/backup_db.sh              # one-off backup now
#   ./scripts/backup_db.sh --dry-run    # show what would happen, upload nothing
#
# Configuration (read from <project>/.env):
#   MINIO_ACCESS_KEY / MINIO_SECRET_KEY   MinIO root credentials
#   (optional overrides via env):
#   POSTGRES_CONTAINER   postgres container name   (default: vai-postgres-1)
#   BACKUP_BUCKET        MinIO bucket              (default: dograh-backups)
#   RETENTION_DAYS       prune backups older than  (default: 14)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${DOGRAH_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="$PROJECT_DIR/.env"

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-vai-postgres-1}"
BACKUP_BUCKET="${BACKUP_BUCKET:-dograh-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1 (see --help)" >&2
            exit 1
            ;;
    esac
    shift
done

log() { echo "[$(date '+%F %T')] $*"; }

[[ -f "$ENV_FILE" ]] || { log "ERROR: $ENV_FILE not found (set DOGRAH_PROJECT_DIR)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

command -v docker >/dev/null 2>&1 || { log "ERROR: docker not found" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER" \
    || { log "ERROR: postgres container '$POSTGRES_CONTAINER' is not running" >&2; exit 1; }
[[ -n "${MINIO_ACCESS_KEY:-}" && -n "${MINIO_SECRET_KEY:-}" ]] \
    || { log "ERROR: MINIO_ACCESS_KEY / MINIO_SECRET_KEY missing from .env" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
DUMP_FILE="dograh-${STAMP}.dump"
TMP_DIR="$(mktemp -d)"
MC_CONFIG_DIR="${MC_CONFIG_DIR:-/var/lib/dograh/mc-config}"
trap 'rm -rf "$TMP_DIR"' EXIT

# mc keeps its alias config in a home dir. The minio/mc image has no shell, so
# each `docker run` starts a fresh container: persist the config on a host
# directory so aliases survive across invocations.
mc() {
    docker run --rm --network host \
        -v "$MC_CONFIG_DIR:/root/.mc" \
        -v "$TMP_DIR:/backup:ro" \
        minio/mc "$@"
}

mkdir -p "$MC_CONFIG_DIR"
mc alias set dograh-minio http://127.0.0.1:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null
log "Connected to MinIO"

log "Backing up database from $POSTGRES_CONTAINER..."
if ! docker exec "$POSTGRES_CONTAINER" pg_dump -U postgres -d postgres -Fc \
        > "$TMP_DIR/$DUMP_FILE" 2> "$TMP_DIR/pg_dump.err"; then
    log "ERROR: pg_dump failed:" >&2
    cat "$TMP_DIR/pg_dump.err" >&2
    exit 1
fi
DUMP_SIZE="$(du -h "$TMP_DIR/$DUMP_FILE" | cut -f1)"
log "Dump complete: $DUMP_FILE ($DUMP_SIZE)"

if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] Would upload $DUMP_FILE to s3://$BACKUP_BUCKET/ and prune >${RETENTION_DAYS}d"
    exit 0
fi

# Upload via the minio/mc image. --network host so mc can reach the host's
# MinIO on 127.0.0.1:9000 (the compose file binds it to localhost).
log "Uploading to MinIO bucket '$BACKUP_BUCKET'..."
mc mb -p "dograh-minio/$BACKUP_BUCKET" >/dev/null 2>&1 || true
mc cp "/backup/$DUMP_FILE" "dograh-minio/$BACKUP_BUCKET/$DUMP_FILE" >/dev/null
log "Uploaded s3://$BACKUP_BUCKET/$DUMP_FILE"

# Prune backups older than RETENTION_DAYS.
CUTOFF="$(date -d "-$RETENTION_DAYS days" +%Y%m%d)"
for f in $(mc find "dograh-minio/$BACKUP_BUCKET" --name 'dograh-*.dump' 2>/dev/null || true); do
    STAMP_OF_FILE="$(basename "$f" | sed 's/^dograh-\([0-9]*\).*$/\1/')"
    if [[ "$STAMP_OF_FILE" < "$CUTOFF" ]]; then
        mc rm "dograh-minio/$BACKUP_BUCKET/$(basename "$f")" >/dev/null 2>&1 || true
        log "Pruned $(basename "$f") (older than ${RETENTION_DAYS}d)"
    fi
done

log "Backup complete."
