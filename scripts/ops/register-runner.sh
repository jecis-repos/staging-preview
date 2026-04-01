#!/usr/bin/env bash
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-/opt/staging-preview/actions-runner}"
RUNNER_URL="${1:-}"
RUNNER_TOKEN="${2:-}"
RUNNER_LABELS="${3:-self-hosted,linux,staging-vps}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-staging}"
RUNNER_USER="${RUNNER_USER:-$(whoami)}"

if [[ -z "$RUNNER_URL" || -z "$RUNNER_TOKEN" ]]; then
  echo "Usage: $0 <runner_url> <registration_token> [labels]"
  echo "Example: $0 https://github.com/<owner>/<repo> <token> self-hosted,linux,staging-vps"
  exit 1
fi

cd "$RUNNER_DIR"

# Reconfigure in place if runner already exists.
./config.sh \
  --unattended \
  --replace \
  --url "$RUNNER_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work "_work"

sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start
sudo ./svc.sh status
