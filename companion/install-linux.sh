#!/bin/sh
# Installs or updates the Un-Ninja Bank Discord companion as a systemd user service.
cd "$(dirname "$0")" || exit 1
exec python3 install.py "$@"
