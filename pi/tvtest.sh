#!/usr/bin/env bash
# Runs tvtest.py in its own Python environment (made the first time).
set -e
cd "$(dirname "$0")"
if [ ! -x .venv/bin/python ]; then
  echo "Setting up (once)..."
  python3 -m venv .venv
  .venv/bin/pip install -q aiowebostv
fi
exec .venv/bin/python tvtest.py "$@"
