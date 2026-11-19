#!/usr/bin/env bash
# Rebuilds the app bundle and (re)launches it. Extra args are passed to the app.
set -euo pipefail
cd "$(dirname "$0")/.."
"$(dirname "$0")/build-app.sh"
pkill -x Agents 2>/dev/null || true
sleep 0.5
if [ $# -gt 0 ]; then
  open build/Agents.app --args "$@"
else
  open build/Agents.app
fi
