#!/usr/bin/env bash
set -euo pipefail

# ship status, on the workstation: what only you can do, while it is missing,
# as setup ends with. fleet status tells the servers'.

if [ "$#" -ne 0 ]; then
    echo "Usage: ship status" >&2
    exit 1
fi

# shellcheck disable=SC2034 # read by shared/setup.sh
ROLE=pc
source "$(dirname "$(readlink -f "$0")")/../shared/setup.sh"

missing="$(missing_steps)"
if [ -n "$missing" ]; then
    echo "Remaining:"
    sed 's/^/  - /' <<< "$missing"
else
    echo "Nothing is missing."
fi
