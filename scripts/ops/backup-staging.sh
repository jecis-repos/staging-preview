#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${STAGING_PREVIEW_BASE_DIR:-/opt/staging-preview}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/staging-preview/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
DEST_DIR="${BACKUP_ROOT}/${TS}"
COMPOSE_PROJECT="${STAGING_PREVIEW_COMPOSE_PROJECT:-staging-preview}"
PG_SERVICE="${STAGING_PREVIEW_PG_SERVICE:-pgsql}"
PG_CONTAINER="${COMPOSE_PROJECT}-${PG_SERVICE}-1"
PG_USER="${STAGING_PREVIEW_PG_USER:-sail}"
PG_PASSWORD="${STAGING_PREVIEW_PG_PASSWORD:-password}"
CADDY_DATA_DIR="${STAGING_PREVIEW_CADDY_DATA_DIR:-}"
DB_PATTERN="${STAGING_PREVIEW_DB_PATTERN:-_crm$}"
BACKUP_OWNER="${STAGING_PREVIEW_BACKUP_OWNER:-}"

mkdir -p "${DEST_DIR}"

# Verify zstd is available (required for compression)
if ! command -v zstd &>/dev/null; then
  echo "ERROR: zstd is not installed. Install with: apt install zstd" >&2
  exit 1
fi

log() {
  printf "[%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

log "Starting staging backup into ${DEST_DIR}"

if [ -d "${BASE_DIR}" ]; then
  log "Backing up ${BASE_DIR} (zstd)"
  tar \
    --exclude='*/node_modules/*' \
    --exclude='*/vendor/*' \
    --exclude='*/storage/logs/*' \
    --exclude='*/storage/framework/cache/*' \
    --exclude='*/storage/framework/sessions/*' \
    --exclude='*/storage/framework/views/*' \
    --exclude='*/.git/*' \
    --warning=no-file-changed \
    --ignore-failed-read \
    --zstd \
    -cf "${DEST_DIR}/workspace.tar.zst" \
    -C "$(dirname "${BASE_DIR}")" "$(basename "${BASE_DIR}")" || {
      # tar exits 1 for changed/unreadable files — only fail on empty archive
      if [ ! -s "${DEST_DIR}/workspace.tar.zst" ]; then
        log "ERROR: workspace archive is empty"
        exit 1
      fi
      log "Warning: some files were not readable, archive is partial"
    }
fi

if [ -n "${CADDY_DATA_DIR}" ] && [ -d "${CADDY_DATA_DIR}" ]; then
  log "Backing up ${CADDY_DATA_DIR} (zstd)"
  tar --zstd -cf "${DEST_DIR}/caddy-data.tar.zst" -C "$(dirname "${CADDY_DATA_DIR}")" "$(basename "${CADDY_DATA_DIR}")"
fi

if docker ps --format "{{.Names}}" | grep -q "^${PG_CONTAINER}$"; then
  log "Dumping PostgreSQL databases"
  mapfile -t DBS < <(
    docker exec "${PG_CONTAINER}" env PGPASSWORD="${PG_PASSWORD}" psql -U "${PG_USER}" -d postgres -Atc \
      "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true AND (datname ~ '${DB_PATTERN}' OR datname = 'postgres');"
  )

  for db in "${DBS[@]}"; do
    [ -z "${db}" ] && continue
    log "Dumping ${db}"
    docker exec "${PG_CONTAINER}" env PGPASSWORD="${PG_PASSWORD}" pg_dump -U "${PG_USER}" -d "${db}" -Fc > "${DEST_DIR}/db-${db}.dump"
  done
else
  log "PostgreSQL container ${PG_CONTAINER} not running; skipping DB dumps"
fi

if compgen -G "${DEST_DIR}/*" > /dev/null; then
  (cd "${DEST_DIR}" && sha256sum * > SHA256SUMS)
fi

# Prune old backups but always keep at least 2
if [ "${RETENTION_DAYS}" -ge 1 ] 2>/dev/null; then
  log "Pruning backups older than ${RETENTION_DAYS} days"
  count=$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -not -name latest | wc -l)
  if [ "${count}" -gt 2 ]; then
    find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" -not -name latest -print -exec rm -rf {} +
  fi
fi

# Fix ownership so non-root can manage backups
if [ -n "${BACKUP_OWNER}" ]; then
  chown -R "${BACKUP_OWNER}:${BACKUP_OWNER}" "${DEST_DIR}" 2>/dev/null || true
fi
ln -sfn "${DEST_DIR}" "${BACKUP_ROOT}/latest"
log "Backup complete"
