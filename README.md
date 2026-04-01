# staging-preview

Vercel-style PR preview environments on your own infrastructure. Open a PR, get a live URL in 60 seconds. Close the PR, instance destroyed. Zero vendor lock-in.

## How it works

1. A pull request is opened (or updated) against your repository.
2. The `Staging Preview Lifecycle` workflow triggers on a self-hosted runner.
3. CI derives an instance name from the branch (e.g. `feature/PROJ-123-login` becomes `proj123`).
4. The MCP server provisions a Docker Compose service, wires up a Caddy reverse-proxy route, and optionally seeds the database.
5. A comment is posted on the PR with the live preview URL (`https://<instance>.<domain>`).
6. When the PR is closed or merged, the same workflow destroys the instance and reclaims all resources.

A separate reconciliation workflow runs hourly to catch orphaned instances that slipped through (force-deleted branches, interrupted runs, etc.).

## Quick start

```bash
# 1. Clone onto your VPS
git clone https://github.com/<owner>/staging-preview.git /opt/staging-preview
cd /opt/staging-preview

# 2. Install Node dependencies for the MCP server
npm --prefix mcp-server ci
npm --prefix mcp-server run build

# 3. Register a self-hosted GitHub Actions runner
scripts/ops/register-runner.sh \
  https://github.com/<owner>/<repo> \
  <registration-token> \
  "self-hosted,linux,staging-vps"

# 4. Copy the workflow files into your application repo
cp -r .github/workflows/staging-preview*.yml <your-app>/.github/workflows/

# 5. Configure GitHub secrets (see table below)

# 6. Install the systemd maintenance timer
sudo cp systemd/staging-preview-maintenance.service /etc/systemd/system/
sudo cp systemd/staging-preview-maintenance.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now staging-preview-maintenance.timer
```

## GitHub secrets configuration

| Secret | Description | Example |
|---|---|---|
| `STAGING_BASE_DIR` | Absolute path to the staging-preview installation | `/opt/staging-preview` |
| `STAGING_DOMAIN` | Wildcard domain for preview instances | `preview.example.com` |
| `CERT_PATH` | Host path to the TLS certificate | `/etc/ssl/certs/preview.pem` |
| `CERT_KEY_PATH` | Host path to the TLS private key | `/etc/ssl/private/preview.key` |
| `CADDY_CERT_PATH` | Container-mounted path to the TLS certificate | `/etc/caddy/certs/preview.pem` |
| `CADDY_CERT_KEY_PATH` | Container-mounted path to the TLS private key | `/etc/caddy/certs/preview.key` |

Optional repository variable:

| Variable | Description | Default |
|---|---|---|
| `TIMEZONE` | Timezone for preview instances | `UTC` |

## Architecture

```
Pull Request Event
       |
       v
+-------------------------------+
| staging-preview.yml           |  GitHub Actions (self-hosted runner)
|  1. Checkout + build MCP      |
|  2. rsync workspace to VPS    |
|  3. derive-preview-meta.mjs   |  --> instance name, mode, db seed
|  4. preview-lifecycle.mjs     |  --> provision / update / destroy
|  5. Post PR comment           |
+-------------------------------+
       |
       v
+-------------------------------+
| MCP Server                    |  Node.js tooling layer
|  create-instance              |
|  update-instance              |
|  remove-instance              |
+-------------------------------+
       |
       v
+-------------------------------+
| Docker Compose                |  Per-instance app container
|  Caddy (reverse proxy + TLS)  |  Shared infrastructure
|  PostgreSQL, Redis            |  Shared infrastructure
+-------------------------------+
```

Reconciliation runs on a cron schedule (`staging-preview-reconcile.yml`). It queries the GitHub API for open PRs, compares against the local instance registry, and destroys any orphaned previews.

## Ops scripts

| Script | Purpose |
|---|---|
| `scripts/ops/staging-maintenance.sh` | Self-healing daemon: restarts crashed containers, expires TTL instances, prunes backups/logs/trash, cleans Docker resources, monitors disk space |
| `scripts/ops/backup-staging.sh` | Full database backup with zstd compression and configurable retention |
| `scripts/ops/sanitize-gdpr-dumps.sh` | Masks PII (phone numbers, personal codes) in PostgreSQL dumps before use in staging |
| `scripts/ops/register-runner.sh` | Registers (or re-registers) a self-hosted GitHub Actions runner with the correct labels |

## CI scripts

| Script | Purpose |
|---|---|
| `scripts/ci/derive-preview-meta.mjs` | Parses the PR event payload, extracts task tokens from branch names, determines provision/destroy/skip mode, and writes GitHub Actions outputs |
| `scripts/ci/preview-lifecycle.mjs` | Orchestrates instance create/update/destroy via the MCP server with conflict recovery and post-provision health checks |
| `scripts/ci/reconcile-previews.mjs` | Compares the instance registry against open GitHub PRs and removes orphaned previews |
| `scripts/ci/preview-naming.mjs` | Shared naming utilities: slug sanitization, task token extraction, instance name derivation |

## systemd integration

The maintenance daemon runs as a systemd timer, executing daily at 04:00 UTC.

```bash
# Install
sudo cp systemd/staging-preview-maintenance.service /etc/systemd/system/
sudo cp systemd/staging-preview-maintenance.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now staging-preview-maintenance.timer

# Check status
systemctl status staging-preview-maintenance.timer
journalctl -u staging-preview-maintenance.service --no-pager -n 50

# Run manually
sudo systemctl start staging-preview-maintenance.service
```

The service unit configures all environment variables with sane defaults (base dir, backup retention, disk thresholds). Override them by editing the service file or using a drop-in.

## Self-healing

The maintenance daemon (`staging-maintenance.sh`) performs the following on each run:

1. **Container health** -- Iterates registered app services. Any service that should be running but is not gets restarted. Core infrastructure (PostgreSQL, Redis, Caddy) is checked separately.
2. **TTL expiration** -- Instances with an `expires_at` timestamp in the registry that has passed are destroyed automatically.
3. **Backup pruning** -- Removes backup directories older than `BACKUP_RETENTION_DAYS` (default: 7), always keeping at least 2.
4. **Log rotation** -- Deletes application logs older than `LOG_RETENTION_DAYS` (default: 7). Truncates any active log exceeding 50 MB to the last 5 MB.
5. **Trash cleanup** -- Purges `.trash` entries older than `TRASH_RETENTION_HOURS` (default: 24).
6. **Docker cleanup** -- Prunes dangling images, unused volumes, and build cache (keeps last 2 GB).
7. **Runner log cleanup** -- Removes GitHub Actions runner diagnostic logs older than 3 days.
8. **Disk monitoring** -- Warns at 85% usage. At 92% (critical), triggers emergency cleanup: aggressive backup pruning, full Docker image and build cache purge.
9. **Self-rotation** -- Rotates its own log file at 10 MB.

All sections are idempotent and non-fatal. If Docker is unavailable, container-dependent tasks are skipped gracefully.

## GDPR sanitization

The `sanitize-gdpr-dumps.sh` script prepares production database dumps for safe use in staging environments:

```bash
# Sanitize a single dump
scripts/ops/sanitize-gdpr-dumps.sh /backups/production.dump /tmp/sanitized

# Sanitize multiple dumps
scripts/ops/sanitize-gdpr-dumps.sh /backups/db1.dump /backups/db2.dump /tmp/out
```

How it works:

1. Spins up an ephemeral PostgreSQL container (`postgres:15-alpine`).
2. Restores the source dump into a temporary database.
3. Scans `information_schema.columns` for columns matching phone and personal identification patterns (`%phone%`, `personal_code`, `id_number`, `national_id`, etc.).
4. Replaces all matching text values with sequential placeholders (`PHONE000000000001`, `ID000000000001`).
5. Nullifies JSON/JSONB phone columns.
6. Exports the sanitized database as a PostgreSQL custom-format dump.
7. Destroys the ephemeral container on exit.

Original dumps are never modified. Sanitized files are written with a `.sanitized.dump` suffix or to a specified output directory.

## Prerequisites

- **VPS** with Docker Engine and Docker Compose v2
- **Self-hosted GitHub Actions runner** with labels `self-hosted,linux,staging-vps`
- **Node.js 20+**
- **Wildcard DNS** pointing `*.preview.example.com` to the VPS
- **TLS certificate** for the wildcard domain (or use Caddy's managed TLS)
- **zstd** for backup compression (`apt install zstd`)

## PR labels

| Label | Effect |
|---|---|
| `skip-staging` | Suppresses preview creation for the PR |
| `db:<seed-name>` | Seeds the preview database with the named dataset (default: `default`) |

## License

MIT -- see [LICENSE](LICENSE).

---

Author: [Jekabs Porietis](https://github.com/coolJecis)
