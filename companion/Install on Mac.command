#!/bin/bash
# Installs or updates the Un-Ninja Bank Discord companion. Double-click it (or right-click > Open the first time).
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null; then
  echo "Python isn't installed. Get it from https://www.python.org/downloads/, then run this again."
else
  python3 install.py "$@"
fi
read -r -p "Press Return to close."
