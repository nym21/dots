# Sourced by every script that runs on a mini before it copies, deletes, syncs or moves anything (brain's seat rules,
# "Scripts that run on a mini"). On 11-23 a proof script copied "${run%/}/." with `run` empty, which is `/.`, into the
# home folder until the disk was full.
#
#   guard_path ROOT PATH...   exits 1, naming the path, unless every PATH is ROOT or lies under it. ROOT is the
#                             script's own work dir (or the one fixed path a step exists to act on): absolute, and
#                             never /, ~, /Users or /Volumes/External itself. No PATH may hold a . or .. part, so an
#                             empty path, /, /., ~ and anything outside ROOT are all refused.
guard_path() {
    local root=${1%/} path
    case $root in
        '' | / | /. | "$HOME" | /Users | /Volumes | /Volumes/External) echo "guard_path: '$1' can't be a root" >&2; exit 1 ;;
        /*) ;;
        *) echo "guard_path: root '$1' is not absolute" >&2; exit 1 ;;
    esac
    shift
    [ $# -gt 0 ] || { echo "guard_path: no path given" >&2; exit 1; }
    for path; do
        case /$path/ in */./* | */../*) echo "guard_path: '$path' has a . or .. part" >&2; exit 1 ;; esac
        case ${path%/} in "$root" | "$root"/*) ;; *) echo "guard_path: '$path' is outside $root" >&2; exit 1 ;; esac
    done
}
