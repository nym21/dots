#!/usr/bin/env bash
set -euo pipefail

# The file work of fleet's audit sync (sync_audits in pc/fleet), on this mini.
# Bitview's block audits are observations of its own mempool and can't be
# rebuilt from the chain, so before a group takes prod its servers take the
# history of the group leaving it: copies of four stores, checked here with
# the installed bitviewd, then merged by bitviewd itself when it opens its
# store (it merges <store>/import/*, in name order, and removes import/).
# fleet streams this file from the workstation for every step but place, which
# runs in a job on the entering server, so a prod server's dots stays as it is.
#
#   audits.sh clone        an APFS clone of this mini's store into OUT, for fleet to fetch
#   audits.sh clear        remove OUT and STAGE
#   audits.sh check NAME   bitviewd --checkaudits STAGE/NAME (a copy fleet put there)
#   audits.sh place        STAGE's copies go into the store's import/, once bitviewd is stopped
#   audits.sh merged       whether the store has no import/ left: bitviewd merged it

# (By their fixed paths: streamed, this script has no directory of its own.)
# shellcheck source=server/external.sh
source ~/Developer/dots/server/external.sh
# shellcheck source=shared/path-guard.sh
source ~/Developer/dots/shared/path-guard.sh

ROOT="$EXTERNAL_VOLUME/bitview/mempool"
STORE="$ROOT/audits"
OUT="$ROOT/audits-out"
STAGE="$ROOT/audits-stage"

case "$#:${1:-}" in
    1:clone)
        # A clone of the live store: one write per block makes a torn clone
        # rare, and check refuses one.
        [ -d "$STORE" ] || { echo "no audit store at $STORE" >&2; exit 3; }
        guard_path "$ROOT" "$OUT"
        rm -rf "$OUT"
        cp -c -R "$STORE" "$OUT"
        rm -rf "$OUT/import"
        ;;
    1:clear)
        guard_path "$ROOT" "$OUT" "$STAGE"
        rm -rf "$OUT" "$STAGE"
        ;;
    2:check)
        case "$2" in '' | */* | .*) echo "bad copy name $2" >&2; exit 1 ;; esac
        bitviewd --checkaudits "$STAGE/$2"
        ;;
    1:place)
        if pgrep -x bitviewd >/dev/null; then
            echo "bitviewd runs: its store can't take an import now" >&2
            exit 1
        fi
        [ -d "$STAGE" ] || { echo "nothing staged at $STAGE" >&2; exit 1; }
        mkdir -p "$STORE/import"
        # Each copy replaces one of its name left by a run cut short before its
        # restart; a copy put there by hand under a later name stays, and wins.
        for copy in "$STAGE"/*; do
            [ -e "$copy" ] || continue
            guard_path "$ROOT" "$copy" "$STORE/import/${copy##*/}"
            rm -rf "$STORE/import/${copy##*/}"
            mv "$copy" "$STORE/import/"
        done
        guard_path "$ROOT" "$STAGE"
        rm -rf "$STAGE"
        ;;
    1:merged)
        [ ! -e "$STORE/import" ]
        ;;
    *)
        echo "Usage: $0 clone | clear | check NAME | place | merged" >&2
        exit 1
        ;;
esac
