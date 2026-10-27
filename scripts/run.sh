#!/bin/bash
# Builds and launches Sirena. The Meta API key is taken from MODEL_API_KEY or SIRENA_API_KEY
# and handed to the app through the environment; the app stores it in the Keychain so later
# launches from Finder work too.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
scripts/build-app.sh "$CONFIG"

KEY="${MODEL_API_KEY:-${SIRENA_API_KEY:-}}"
pkill -x Sirena 2>/dev/null || true
sleep 0.3
if [ -n "$KEY" ]; then
  open -n build/Sirena.app --env "MODEL_API_KEY=$KEY"
else
  echo "▸ no MODEL_API_KEY / SIRENA_API_KEY in the environment; the app will use the Keychain or ask for a key"
  open -n build/Sirena.app
fi
echo "▸ Sirena launched. Logs: log stream --predicate 'subsystem == \"ai.sirena.app\"' --level debug"
