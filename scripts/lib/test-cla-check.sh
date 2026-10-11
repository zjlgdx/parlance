#!/bin/bash
# Offline API/git-object fixtures; no real git mutations or network calls.
set -uo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "$LIB/test_cla_check.py" "$@"
