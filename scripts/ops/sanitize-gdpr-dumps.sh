#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/ops/sanitize-gdpr-dumps.sh <dump1> [dump2] ... [output-dir]
#
# If the last argument is a directory (or does not end with .dump), it is used
# as the output directory. Otherwise all sanitized dumps are written next to
# their source files with a ".sanitized.dump" suffix.
#
# Examples:
#   scripts/ops/sanitize-gdpr-dumps.sh /backups/production.dump /tmp/sanitized
#   scripts/ops/sanitize-gdpr-dumps.sh /backups/db1.dump /backups/db2.dump /tmp/out
#
# Notes:
# - Original dumps are never overwritten.
# - Sanitized dumps are exported in PostgreSQL custom format.
# - All phone numbers and personal identification fields are masked.

PG_IMAGE="${PG_IMAGE:-postgres:15-alpine}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-postgres}"
PG_CONTAINER="${PG_CONTAINER:-staging-preview-gdpr-sanitize-pg}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

pg_exec() {
  docker exec \
    -e "PGPASSWORD=${PG_PASSWORD}" \
    -i "${PG_CONTAINER}" \
    psql -v ON_ERROR_STOP=1 -U "${PG_USER}" "$@"
}

cleanup() {
  docker rm -f "${PG_CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Parse arguments: collect dump files and optional output directory
DUMP_FILES=()
OUTPUT_DIR=""

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <dump1> [dump2] ... [output-dir]" >&2
  exit 1
fi

args=("$@")
last_arg="${args[${#args[@]}-1]}"

# If last arg doesn't end in .dump and is not an existing file, treat as output dir
if [[ ! "${last_arg}" =~ \.dump$ ]] || [[ -d "${last_arg}" ]]; then
  OUTPUT_DIR="${last_arg}"
  unset 'args[${#args[@]}-1]'
fi

for arg in "${args[@]}"; do
  if [[ ! -f "${arg}" ]]; then
    echo "Missing dump file: ${arg}" >&2
    exit 1
  fi
  DUMP_FILES+=("${arg}")
done

if [[ ${#DUMP_FILES[@]} -eq 0 ]]; then
  echo "No dump files provided." >&2
  exit 1
fi

if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  log "Removing existing temporary container ${PG_CONTAINER}"
  docker rm -f "${PG_CONTAINER}" >/dev/null
fi

log "Starting temporary PostgreSQL container (${PG_IMAGE})"
docker run -d \
  --name "${PG_CONTAINER}" \
  -e "POSTGRES_USER=${PG_USER}" \
  -e "POSTGRES_PASSWORD=${PG_PASSWORD}" \
  "${PG_IMAGE}" >/dev/null

log "Waiting for PostgreSQL to become ready"
ready=0
for _ in $(seq 1 90); do
  if docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
  echo "Temporary PostgreSQL did not become ready in time." >&2
  exit 1
fi

sanitize_db() {
  local source_dump="$1"
  local db_name="$2"
  local out_dump="$3"
  local source_in_container="/tmp/source.dump"
  local out_in_container="/tmp/${db_name}.sanitized.dump"

  log "Preparing database ${db_name}"
  pg_exec -d postgres -c "DROP DATABASE IF EXISTS ${db_name};"
  pg_exec -d postgres -c "CREATE DATABASE ${db_name};"

  log "Copying source dump into container (${source_dump})"
  docker cp "${source_dump}" "${PG_CONTAINER}:${source_in_container}"

  log "Restoring ${source_dump} into ${db_name}"
  docker exec \
    -e "PGPASSWORD=${PG_PASSWORD}" \
    "${PG_CONTAINER}" \
    pg_restore \
    --no-owner \
    --no-privileges \
    -U "${PG_USER}" \
    -d "${db_name}" \
    "${source_in_container}"

  docker exec "${PG_CONTAINER}" rm -f "${source_in_container}"

  log "Masking phone and personal-code fields in ${db_name}"
  pg_exec -d "${db_name}" <<'SQL'
DO $$
DECLARE
  rec RECORD;
  changed_rows BIGINT;
BEGIN
  FOR rec IN
    SELECT c.table_schema, c.table_name, c.column_name
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.udt_name IN ('varchar', 'text', 'bpchar', 'citext')
      AND (
        (c.column_name ILIKE '%phone%' AND c.column_name NOT ILIKE '%country_code%')
        OR c.column_name IN (
          'id_number',
          'personal_code',
          'person_code',
          'national_id',
          'national_identification_number',
          'identity_number',
          'identity_no'
        )
        OR c.column_name ILIKE '%personal_code%'
      )
  LOOP
    EXECUTE format(
      $fmt$
      WITH numbered AS (
        SELECT ctid, row_number() OVER (ORDER BY ctid) AS rn
        FROM %I.%I
        WHERE %I IS NOT NULL
      )
      UPDATE %I.%I AS t
      SET %I = CASE
        WHEN %L IN (
          'id_number',
          'personal_code',
          'person_code',
          'national_id',
          'national_identification_number',
          'identity_number',
          'identity_no'
        )
        OR %L LIKE '%%personal%%'
        OR %L LIKE '%%national%%'
        OR %L LIKE '%%identity%%'
          THEN 'ID' || lpad(numbered.rn::text, 12, '0')
        ELSE 'PHONE' || lpad(numbered.rn::text, 12, '0')
      END
      FROM numbered
      WHERE t.ctid = numbered.ctid;
      $fmt$,
      rec.table_schema,
      rec.table_name,
      rec.column_name,
      rec.table_schema,
      rec.table_name,
      rec.column_name,
      rec.column_name,
      rec.column_name,
      rec.column_name,
      rec.column_name
    );

    GET DIAGNOSTICS changed_rows = ROW_COUNT;
    RAISE NOTICE 'Masked %.% (% rows)', rec.table_name, rec.column_name, changed_rows;
  END LOOP;

  FOR rec IN
    SELECT c.table_schema, c.table_name, c.column_name, c.udt_name
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.udt_name IN ('json', 'jsonb')
      AND c.column_name ILIKE '%phone%'
      AND c.column_name NOT ILIKE '%country_code%'
  LOOP
    EXECUTE format(
      'UPDATE %I.%I SET %I = %s WHERE %I IS NOT NULL;',
      rec.table_schema,
      rec.table_name,
      rec.column_name,
      CASE
        WHEN rec.udt_name = 'jsonb' THEN '''[]''::jsonb'
        ELSE '''[]''::json'
      END,
      rec.column_name
    );

    GET DIAGNOSTICS changed_rows = ROW_COUNT;
    RAISE NOTICE 'Masked %.% (% rows)', rec.table_name, rec.column_name, changed_rows;
  END LOOP;
END;
$$;
SQL

  log "Exporting sanitized dump to ${out_dump}"
  docker exec \
    -e "PGPASSWORD=${PG_PASSWORD}" \
    "${PG_CONTAINER}" \
    pg_dump \
    --no-owner \
    --no-privileges \
    -F c \
    -U "${PG_USER}" \
    -d "${db_name}" \
    -f "${out_in_container}"

  docker cp "${PG_CONTAINER}:${out_in_container}" "${out_dump}"
  docker exec "${PG_CONTAINER}" rm -f "${out_in_container}"

  log "Sampling masked columns in ${db_name}"
  pg_exec -d "${db_name}" -At <<'SQL' | sed -n '1,80p'
SELECT format('%s.%s.%s', c.table_schema, c.table_name, c.column_name)
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND (
    (c.column_name ILIKE '%phone%' AND c.column_name NOT ILIKE '%country_code%')
    OR c.column_name IN (
      'id_number',
      'personal_code',
      'person_code',
      'national_id',
      'national_identification_number',
      'identity_number',
      'identity_no'
    )
    OR c.column_name ILIKE '%personal_code%'
  )
ORDER BY 1;
SQL
}

OUT_FILES=()
for i in "${!DUMP_FILES[@]}"; do
  dump="${DUMP_FILES[$i]}"
  db_name="sanitize_db_${i}"
  basename_dump="$(basename "${dump}" .dump)"

  if [[ -n "${OUTPUT_DIR}" ]]; then
    out_dump="${OUTPUT_DIR}/${basename_dump}.sanitized.dump"
  else
    out_dump="$(dirname "${dump}")/${basename_dump}.sanitized.dump"
  fi

  sanitize_db "${dump}" "${db_name}" "${out_dump}"
  OUT_FILES+=("${out_dump}")
done

log "Checksums:"
sha256sum "${OUT_FILES[@]}"
log "Done. Original dumps were not modified."
