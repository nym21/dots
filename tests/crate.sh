#!/usr/bin/env bash
# server/crate.sh's install_crate: what it asks of cargo, in each mode.
source "$(dirname "$0")/lib.sh"
mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho "$*"\n' > "$TMP/bin/cargo"
chmod +x "$TMP/bin/cargo"
export HOME="$TMP" PATH="$TMP/bin:$PATH"
SERVER_DIR="$REPO/server"
source "$REPO/server/crate.sh"
rev=330bfa8c01138ebd55b277038c89b9de5afeaf37

check "prod installs the crate's own binary alone, so cargo skips one it has" \
    [ "$(install_crate bitviewd prod 0.12.2)" = "install --locked bitviewd --bin bitviewd --version 0.12.2" ]
check "prod without a pin takes the newest" [ "$(install_crate bitview_mcp prod)" = "install --locked bitview_mcp --bin bitview_mcp" ]
check "a branch's pinned commit, its own binary alone" \
    [ "$(install_crate bitviewd next "$rev")" = "install --locked --git https://github.com/bitcoinresearchkit/mono --rev $rev bitviewd --bin bitviewd" ]
check "a branch without a pin, its newest commit" \
    [ "$(install_crate bitviewd next)" = "install --locked --git https://github.com/bitcoinresearchkit/mono --branch next bitviewd --bin bitviewd" ]
check "local mode builds the copy" contains "$(install_crate bitviewd local)" "$HOME/Developer/mono/crates/bitviewd"
finish
