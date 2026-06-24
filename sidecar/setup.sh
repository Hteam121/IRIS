#!/usr/bin/env bash
#
# Create the IRIS sidecar virtualenv and install dependencies.
#
# Usage:  cd sidecar && ./setup.sh
# Then point IRIS at .venv/bin/python (Settings: sidecarPython, env IRIS_SIDECAR_PYTHON).
#
set -euo pipefail

cd "$(dirname "$0")"

# Prefer a stable Python; very new releases (3.14+) sometimes lack prebuilt wheels
# for the ML deps. Fall back to whatever python3 is available.
PYTHON=""
for cand in python3.12 python3.11 python3.13 python3; do
  if command -v "$cand" >/dev/null 2>&1; then PYTHON="$cand"; break; fi
done
if [ -z "$PYTHON" ]; then
  echo "error: no python3 found on PATH" >&2
  exit 1
fi
echo "Using $($PYTHON --version) at $(command -v "$PYTHON")"

if [ ! -d .venv ]; then
  "$PYTHON" -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e .

echo
echo "✅ Sidecar ready."
echo "   venv python: $(pwd)/.venv/bin/python"
echo
echo "Run it manually with:"
echo "   $(pwd)/.venv/bin/python -m iris_agents.server"
echo
echo "IRIS will spawn it automatically if you set (in ~/.iris/config.json or .env):"
echo "   IRIS_SIDECAR_PYTHON=$(pwd)/.venv/bin/python"
