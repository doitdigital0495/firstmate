#!/usr/bin/env bash
# One real-status pass of the Miko cockpit. Pass --help for the shared page checks.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$here/refresh-cockpit.py" "$@"
