# dots

Shared macOS dotfiles and setup for a workstation or headless Mac mini.
Run commands from this repository's root as your normal login user.

## Setup

```sh
./pc/setup.sh
```

For a headless mini, follow the [server setup instructions](server/README.md),
then run:

```sh
./server/setup.sh
```

Setup installs the shared packages and the selected role's additions.
It links `shared/home/` and the role's dotfiles into your home directory,
preserving existing files as `.backup`. Edit those repository files to change
the linked settings.

Codex settings are the exception: Codex rewrites `~/.codex/config.toml` with
machine state, replacing any symlink, so PC setup merges
`shared/home/.codex/config.toml` into it instead. Shared keys overwrite the
machine's values and everything else is kept; re-run setup after changing the
shared file. Removing a key from the shared file does not remove it from
machines that already have it.

Rex's settings work the same way: Rex keeps them in its preferences, so
`pc/save.sh` saves them to `pc/rex-settings` and PC setup writes them back.

## Layout

- `shared/`: what both roles use: packages, shell and editor dotfiles, setup internals, and maintenance tools.
- `pc/`: the workstation: development tools, Codex and Claude Code, Rex and Zed settings, desktop setup, and Tailscale SSH/copy commands.
- `server/`: headless setup, profile, and workload launchers.

Each role's `setup.sh` contains its setup and sources `shared/setup.sh` for
common setup. Servers stay lean: development happens on the workstation,
which also makes every Git write.

Each role has its own `Brewfile` and `cargo.txt`, installed after the shared
ones; Helix and its configuration are shared between both roles.

## Maintenance

Every Mac has `ship`, for itself; the workstation also has `fleet`, for the
servers. Setup links them into `~/.local/bin` and records the Mac's role in
`~/.config/dots/role`, and `ship update` keeps them there. They run the scripts
in this repository, so pulling it updates them too. `ship` alone lists the
commands this Mac has.

```sh
ship update    # Update everything and restart what changed; macOS last.
ship save      # On the workstation: save Cargo tools to pc/cargo.txt and Rex settings to pc/rex-settings.
fleet status   # On the workstation: one line per server.
fleet update   # On the workstation: ship update on each server in turn.
```

`ship update` pulls this repository and runs the version pulled. It then
installs what the Brewfiles and Cargo lists gained, upgrades Homebrew, Rust,
and the listed Cargo tools, and on a server updates Rex and the workloads within
the mini's mode (see the [server instructions](server/README.md)). Last, if
macOS has an update or upgrade, it downloads the newest, waits 30 seconds for
Ctrl-C, stops a server's workloads cleanly, installs it, and restarts; the
workloads come back at boot. Without one, it installs the newest of the other
updates, such as the Command Line Tools.

It asks for a password only when it must. Its first run installs
`/etc/sudoers.d/dots`, which lets it install Apple's updates and, on a server,
restart the Rex and Tailscale daemons without one; installing a daemon still
asks. A macOS update always asks for the Mac owner's password, so without a
terminal `ship update` only downloads it.

`fleet update` updates the servers not in prod first, then each prod server,
waiting until each serves again, workloads running, tunnels connected, and
Bitview at the tip, before the next, so prod never loses two at once. It stops
if a server does not serve again within 45 minutes.

## SSH over Tailscale

PC setup makes `tssh`, `tcopy`, `tscreen`, and `trex` available on your PATH:

```sh
tssh mini@tailscale-host
```

Copy a directory in either direction using `tcopy SOURCE DESTINATION`:

```sh
tcopy mini@m6-1:/absolute/path/to/run-folder/ "$HOME/bench-m6-1-main/"
tcopy "$HOME/bench-m6-1-main/" mini@m6-1:/absolute/path/to/run-folder/
```

It uses rsync over `tssh`, with progress and partial transfers retained for
resuming. A trailing `/` on the source copies the directory's contents.

Open Screen Sharing to a Tailscale host with `tscreen`:

```sh
tscreen mini@m6-2
```

Tailscale host names only resolve inside `tssh`, so `vnc://m6-2` does not work
directly. When `tailscale ping` reaches the host directly at a private LAN
address, `tscreen` opens Screen Sharing on that address, which allows High
Performance mode. Otherwise it forwards the host's Screen Sharing port through
`tssh` to a free local port from 5901 and opens Screen Sharing on it in Standard
mode. The tunnel closes after Screen Sharing disconnects, or after a minute if it
never connects. `tssh --tailscale ARGS` runs other `tailscale` commands, such as
`status`, against the same daemon.

Keep every server's Rex reachable from the Rex app with `trex`, then add each
printed `http://127.0.0.1:PORT` URL in Rex with Add Remote Host, named after
its server:

```sh
trex         # forward every server on the tailnet
trex --stop  # stop them all until the next trex
```

The servers are the other Macs on the tailnet, under their Tailscale names.
`trex` checks a new one once and skips it unless it accepts your SSH key as
`mini` and runs a Rex server. Each server keeps the port it was first given, in
`~/Library/Application Support/trex/ports`, so saved hosts stay valid; run
`trex` again after adding a server. Each forward runs `tssh` as a LaunchAgent
that starts at login and reconnects on its own. The Rex app only accepts
http(s) hosts and Rex has no login on them, so any process on this Mac can use
the ports to act as the servers' users.

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.
