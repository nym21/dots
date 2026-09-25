#!/usr/bin/env bash

set -euo pipefail

rustup update

cargo install --locked bitviewd

RUST_BACKTRACE=1 LOG=debug exec bitviewd
