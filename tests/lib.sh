# shellcheck shell=bash disable=SC2034 # REPO and ON_EXIT, for the tests
# Sourced by each test: the repository, a scratch directory removed at the
# end, with ON_EXIT run first, and check, which says whether a command held.
# finish ends the test, failing when any check failed.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
ON_EXIT=''
trap 'eval "$ON_EXIT"; rm -rf "$TMP"' EXIT
failed=0

# check DESCRIPTION COMMAND...: whether COMMAND succeeds.
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  ok    $description"
    else
        echo "  FAIL  $description"
        failed=$((failed + 1))
    fi
}

# Whether COMMAND... fails.
fails() {
    ! "$@"
}

# Whether COMMAND... exits with STATUS.
status_is() {
    local want="$1" status=0
    shift
    "$@" || status=$?
    [ "$status" -eq "$want" ]
}

# Whether FILE lacks PATTERN.
lacks() {
    ! grep -q -- "$1" "$2"
}

# Whether the words of LIST include WORD.
contains() {
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

finish() {
    exit "$failed"
}
