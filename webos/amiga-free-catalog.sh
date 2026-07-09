#!/usr/bin/env bash
# Compatibility wrapper — use setup-amiga.sh (single Amiga tool).
exec "$(cd "$(dirname "$0")" && pwd)/setup-amiga.sh" "$@"
