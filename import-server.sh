#!/usr/bin/env bash
set -e

DOTS_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DOTS_DIR/import.sh" server
