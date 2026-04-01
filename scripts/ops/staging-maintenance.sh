#!/usr/bin/env bash
# staging-maintenance.sh — Self-healing and retention for staging preview server.
# Runs periodically via systemd timer. Each section is idempotent and non-fatal.
set -uo pipefail

BASE_DIR="${STAGING_PREVIEW_BASE_DIR:-/opt/staging-preview}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/staging-preview/backups}"
MCP_SERVER="${BASE_DIR}/mcp-server"
REGISTRY="${MCP_SERVER}/registry.json"
LOG_FILE="/var/log/staging-preview-maintenance.log"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"
DISK_CRIT_PERCENT="${DISK_CRIT_PERCENT:-92}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
TRASH_RETENTION_HOURS="${TRASH_RETENTION_HOURS:-24}"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
RUNNER_DIRS="${STAGING_PREVIEW_RUNNER_DIRS:-/opt/staging-preview/actions-runner}"

log() {
  printf "[%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${LOG_FILE}"
}

warn() {
  printf "[%s] WARNING: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${LOG_FILE}"
}

# -------------------------------------------------------------------
# 1. SELF-HEALING: Restart crashed app containers
# -------------------------------------------------------------------
heal_containers() {
  log "[heal] Checking container health..."

  # Get all registered app services that should be running
  if [ ! -f "${REGISTRY}" ]; then
    log "[heal] No registry found, skipping"
    return
  fi

  local services
  services=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null | \
    python3 -c '
import sys, json
for line in sys.stdin:
  line = line.strip()
  if not line: continue
  try:
    entry = json.loads(line)
    svc = entry.get("Service", entry.get("Name", ""))
    state = entry.get("State", "").lower()
    health = entry.get("Health", "").lower()
    if svc.endswith("-app"):
      print(f"{svc}|{state}|{health}")
  except: pass
' 2>/dev/null) || true

  if [ -z "${services}" ]; then
    log "[heal] No app services found"
    return
  fi

  local healed=0
  while IFS='|' read -r svc state health; do
    if [ "${state}" = "running" ]; then
      continue
    fi

    # Service is not running — check if it's in the registry (expected to be up)
    local prefix="${svc%-app}"
    if python3 -c "
import json, sys
r = json.load(open('${REGISTRY}'))
prefixes = [i['prefix'] for i in r.get('instances', []) if i.get('status') != 'provisioning']
sys.exit(0 if '${prefix}' in prefixes else 1)
" 2>/dev/null; then
      warn "[heal] ${svc} is ${state} (expected running) — restarting"
      if docker compose -f "${COMPOSE_FILE}" up -d "${svc}" 2>>"${LOG_FILE}"; then
        log "[heal] Restarted ${svc}"
        healed=$((healed + 1))
      else
        warn "[heal] Failed to restart ${svc}"
      fi
    fi
  done <<< "${services}"

  # Also ensure core infrastructure services are running
  local core_services="${STAGING_PREVIEW_CORE_SERVICES:-pgsql redis caddy}"
  for core_svc in ${core_services}; do
    local core_state
    core_state=$(docker compose -f "${COMPOSE_FILE}" ps --format "{{.State}}" "${core_svc}" 2>/dev/null | head -1) || true
    if [ -n "${core_state}" ] && [ "${core_state}" != "running" ]; then
      warn "[heal] Core service ${core_svc} is ${core_state} — restarting"
      docker compose -f "${COMPOSE_FILE}" up -d "${core_svc}" 2>>"${LOG_FILE}" || true
    fi
  done

  log "[heal] Done (${healed} service(s) healed)"
}

# -------------------------------------------------------------------
# 2. RETENTION: Clean expired preview instances
# -------------------------------------------------------------------
clean_expired_instances() {
  log "[expiry] Checking instance TTL..."

  if [ ! -f "${REGISTRY}" ]; then
    return
  fi

  local expired
  expired=$(python3 -c "
import json, sys
from datetime import datetime, timezone
r = json.load(open('${REGISTRY}'))
now = datetime.now(timezone.utc)
for i in r.get('instances', []):
    exp = i.get('expires_at')
    if not exp: continue
    try:
        exp_dt = datetime.fromisoformat(exp.replace('Z', '+00:00'))
        if exp_dt < now:
            print(i['prefix'])
    except: pass
" 2>/dev/null) || true

  if [ -z "${expired}" ]; then
    log "[expiry] No expired instances"
    return
  fi

  while read -r prefix; do
    warn "[expiry] Instance ${prefix} has expired — removing"
    if cd "${MCP_SERVER}" && node -e "
      import('./dist/tools/remove-instance.js').then(async m => {
        const result = await m.removeInstanceTool({ name: '${prefix}', keep_database: false, keep_files: false });
        console.log(result);
      });
    " 2>>"${LOG_FILE}"; then
      log "[expiry] Removed expired instance ${prefix}"
    else
      warn "[expiry] Failed to remove ${prefix}"
    fi
  done <<< "${expired}"
}

# -------------------------------------------------------------------
# 3. RETENTION: Prune old backups (tighter than the backup script)
# -------------------------------------------------------------------
prune_backups() {
  log "[backups] Pruning backups older than ${BACKUP_RETENTION_DAYS} days..."

  if [ ! -d "${BACKUP_ROOT}" ]; then
    return
  fi

  local pruned=0
  local count
  count=$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -not -name latest | wc -l)

  # Always keep at least 2 backups regardless of age
  if [ "${count}" -le 2 ]; then
    log "[backups] Only ${count} backup(s), keeping all"
    return
  fi

  while IFS= read -r dir; do
    if [ -L "${BACKUP_ROOT}/latest" ]; then
      local latest_target
      latest_target=$(readlink -f "${BACKUP_ROOT}/latest")
      if [ "$(readlink -f "${dir}")" = "${latest_target}" ]; then
        continue  # Never prune the latest symlink target
      fi
    fi
    log "[backups] Pruning old backup: $(basename "${dir}")"
    rm -rf "${dir}"
    pruned=$((pruned + 1))
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS}" -not -name latest)

  log "[backups] Pruned ${pruned} backup(s), ${count} total"
}

# -------------------------------------------------------------------
# 4. RETENTION: Rotate application logs
# -------------------------------------------------------------------
rotate_app_logs() {
  log "[logs] Rotating app logs older than ${LOG_RETENTION_DAYS} days..."

  local rotated=0
  while IFS= read -r logfile; do
    rm -f "${logfile}"
    rotated=$((rotated + 1))
  done < <(find "${BASE_DIR}" -path "*/storage/logs/*.log" -mtime +"${LOG_RETENTION_DAYS}" -type f 2>/dev/null)

  # Truncate active logs larger than 50MB
  while IFS= read -r logfile; do
    local size
    size=$(stat -c%s "${logfile}" 2>/dev/null) || continue
    if [ "${size}" -gt 52428800 ]; then
      warn "[logs] Truncating oversized log: ${logfile} ($(numfmt --to=iec "${size}"))"
      tail -c 5242880 "${logfile}" > "${logfile}.tmp" && mv "${logfile}.tmp" "${logfile}"
      rotated=$((rotated + 1))
    fi
  done < <(find "${BASE_DIR}" -path "*/storage/logs/*.log" -type f 2>/dev/null)

  log "[logs] Rotated/truncated ${rotated} log file(s)"
}

# -------------------------------------------------------------------
# 5. RETENTION: Clean .trash directory
# -------------------------------------------------------------------
clean_trash() {
  local trash_dir="${BASE_DIR}/.trash"
  if [ ! -d "${trash_dir}" ]; then
    return
  fi

  log "[trash] Cleaning trash older than ${TRASH_RETENTION_HOURS}h..."
  local cleaned=0
  while IFS= read -r entry; do
    rm -rf "${entry}"
    cleaned=$((cleaned + 1))
  done < <(find "${trash_dir}" -mindepth 1 -maxdepth 1 -mmin +"$((TRASH_RETENTION_HOURS * 60))" 2>/dev/null)

  log "[trash] Cleaned ${cleaned} trash entries"
}

# -------------------------------------------------------------------
# 6. RETENTION: Docker resource cleanup
# -------------------------------------------------------------------
clean_docker() {
  log "[docker] Cleaning unused Docker resources..."

  # Remove dangling images
  local dangling
  dangling=$(docker images -f dangling=true -q 2>/dev/null | wc -l) || true
  if [ "${dangling}" -gt 0 ]; then
    docker image prune -f >>"${LOG_FILE}" 2>&1 || true
    log "[docker] Pruned ${dangling} dangling image(s)"
  fi

  # Remove unused volumes (not attached to any container)
  docker volume prune -f >>"${LOG_FILE}" 2>&1 || true

  # Remove old build cache (keep last 2GB)
  docker builder prune --keep-storage 2GB -f >>"${LOG_FILE}" 2>&1 || true

  log "[docker] Docker cleanup done"
}

# -------------------------------------------------------------------
# 7. MONITORING: Disk space check
# -------------------------------------------------------------------
check_disk_space() {
  log "[disk] Checking disk usage..."

  local usage_pct
  usage_pct=$(df --output=pcent / | tail -1 | tr -d ' %')

  if [ "${usage_pct}" -ge "${DISK_CRIT_PERCENT}" ]; then
    warn "[disk] CRITICAL: Disk usage at ${usage_pct}%! Emergency cleanup starting..."

    # Emergency: reduce backup retention to 3 days
    find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +3 -not -name latest -exec rm -rf {} + 2>/dev/null || true

    # Emergency: prune all Docker build cache
    docker builder prune -af >>"${LOG_FILE}" 2>&1 || true

    # Emergency: remove all unused images
    docker image prune -af >>"${LOG_FILE}" 2>&1 || true

    # Re-check
    usage_pct=$(df --output=pcent / | tail -1 | tr -d ' %')
    log "[disk] After emergency cleanup: ${usage_pct}%"
  elif [ "${usage_pct}" -ge "${DISK_WARN_PERCENT}" ]; then
    warn "[disk] Disk usage at ${usage_pct}% (warning threshold: ${DISK_WARN_PERCENT}%)"
  else
    log "[disk] Disk usage at ${usage_pct}% — OK"
  fi
}

# -------------------------------------------------------------------
# 8. SELF-HEALING: Rotate maintenance log itself
# -------------------------------------------------------------------
rotate_maintenance_log() {
  if [ -f "${LOG_FILE}" ]; then
    local size
    size=$(stat -c%s "${LOG_FILE}" 2>/dev/null) || return
    if [ "${size}" -gt 10485760 ]; then  # 10MB
      mv "${LOG_FILE}" "${LOG_FILE}.1"
      log "Rotated maintenance log"
    fi
  fi
}

# -------------------------------------------------------------------
# 9. RETENTION: GitHub Actions runner diagnostic log cleanup
# -------------------------------------------------------------------
clean_runner_logs() {
  log "[runner-logs] Cleaning runner diagnostic logs..."
  local cleaned=0
  IFS=':' read -ra runner_dirs <<< "${RUNNER_DIRS}"
  for runner_dir in "${runner_dirs[@]}"; do
    runner_dir="${runner_dir## }"
    runner_dir="${runner_dir%% }"
    if [ -d "${runner_dir}/_diag" ]; then
      # Keep last 3 days of logs, delete the rest
      local count
      count=$(find "${runner_dir}/_diag" -name "*.log" -mtime +3 2>/dev/null | wc -l) || true
      if [ "${count}" -gt 0 ]; then
        find "${runner_dir}/_diag" -name "*.log" -mtime +3 -delete 2>/dev/null || true
        log "[runner-logs] Removed ${count} old log(s) from ${runner_dir}/_diag"
        cleaned=$((cleaned + count))
      fi
    fi
  done
  log "[runner-logs] Cleaned ${cleaned} runner log file(s)"
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
  log "========== Staging maintenance started =========="

  # Pre-check: Docker daemon must be running
  if ! docker info &>/dev/null; then
    warn "Docker daemon is not running — skipping container-dependent tasks"
    rotate_app_logs
    clean_trash
    check_disk_space
    rotate_maintenance_log
    log "========== Staging maintenance complete (Docker skipped) =========="
    return
  fi

  heal_containers
  clean_expired_instances
  prune_backups
  rotate_app_logs
  clean_trash
  clean_docker
  clean_runner_logs
  check_disk_space
  rotate_maintenance_log

  log "========== Staging maintenance complete =========="
}

main
