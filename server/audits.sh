#!/usr/bin/env bash
set -euo pipefail

# The file work of fleet's audit sync (sync_audits in pc/fleet), on this mini.
# Bitview's block audits are observations of its own mempool and can't be
# rebuilt from the chain, so before a group takes prod its servers take the
# history of the servers leaving it: copies of their stores, checked here with
# the installed bitviewd, then merged by bitviewd itself when it opens its
# store (it merges <store>/import/*, in name order, and removes import/).
# fleet streams this file, after path-guard.sh and external.sh, for every step
# but place, which runs in a job on the entering server from its own dots: the
# servers leaving prod keep the dots they had.
#
#   audits.sh supported    whether the installed bitviewd merges audit copies: 0 yes, 4 no
#   audits.sh clone        an APFS clone of this mini's store into OUT, for fleet to fetch
#   audits.sh clear        remove OUT and fleet's numbered copies in STAGE
#   audits.sh check NAME   bitviewd --checkaudits STAGE/NAME (a copy fleet put there)
#   audits.sh place        every copy in STAGE goes into the store's import/, once bitviewd is stopped
#   audits.sh merged       whether the store has no import/ left: bitviewd merged it
#
# A copy put in STAGE by hand under a name after the numbers (as "repair")
# stays until a place, and merges last, so it wins.

# Streamed by fleet, path-guard.sh and external.sh came first; run as a file, it sources them.
if ! declare -F guard_path > /dev/null; then
    # shellcheck source=server/external.sh
    source "$(dirname "$0")/external.sh"
    # shellcheck source=shared/path-guard.sh
    source "$(dirname "$0")/../shared/path-guard.sh"
fi
# As workloads.sh runs bitviewd: ssh brings no PATH of the login shell's.
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$EXTERNAL_VOLUME/bitview/mempool"
STORE="$ROOT/audits"
OUT="$ROOT/audits-out"
STAGE="$ROOT/audits-stage"

case "$#:${1:-}" in
    1:supported)
        # 4 only when bitviewd ran and lacks the flag: every failure to ask
        # (external.sh's 1, a missing bitviewd, ssh's 255) is another status,
        # which fleet takes as an error, never as a build without the merge.
        # (Read whole first: grep -q ending the pipe early fails it under pipefail.)
        help="$(bitviewd --help)" || exit 2
        case "$help" in *--checkaudits*) ;; *) exit 4 ;; esac
        ;;
    1:clone)
        # A clone of the live store: one write per block makes a torn clone
        # rare, and check refuses one.
        [ -d "$STORE" ] || { echo "no audit store at $STORE" >&2; exit 3; }
        guard_path "$ROOT" "$OUT" "$OUT/import"
        rm -rf "$OUT"
        cp -c -R "$STORE" "$OUT"
        rm -rf "$OUT/import"
        ;;
    1:clear)
        guard_path "$ROOT" "$OUT"
        rm -rf "$OUT"
        for copy in "$STAGE"/[0-9]*; do
            [ -e "$copy" ] || continue
            guard_path "$ROOT" "$copy"
            rm -rf "$copy"
        done
        ;;
    2:check)
        case "$2" in '' | */* | .*) echo "bad copy name $2" >&2; exit 1 ;; esac
        bitviewd --checkaudits "$STAGE/$2"
        ;;
    1:place)
        # The managed bitviewd, not a seat's own of the same name.
        if "$(dirname "$0")/workloads.sh" running bitviewd; then
            echo "bitviewd runs: its store can't take an import now" >&2
            exit 1
        fi
        [ -d "$STAGE" ] || { echo "nothing staged at $STAGE" >&2; exit 1; }
        mkdir -p "$STORE/import"
        # Each copy replaces one of its name left by a run cut short before its restart.
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
        echo "Usage: $0 supported | clone | clear | check NAME | place | merged" >&2
        exit 1
        ;;
esac
