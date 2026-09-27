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

## Layout

- `shared/`: common packages, dotfiles, setup internals, and maintenance tools.
- `pc/`: workstation applications, Ghostty and Zed settings, desktop setup, and Tailscale SSH/copy commands.
- `server/`: headless setup, profile, and workload launchers.

Each role's `setup.sh` contains its setup and sources `shared/setup.sh` for
common setup.

Each folder has its own `Brewfile`. Shared Cargo packages are listed in
`shared/cargo.txt`; Helix and its configuration are shared between both roles.

## Maintenance

```sh
./shared/update.sh        # Update Homebrew and installed Cargo packages.
./shared/macos-update.sh  # Confirm before installing macOS updates/restarting.
./shared/save.sh          # Save installed Cargo packages to shared/cargo.txt.
```

## SSH over Tailscale

PC setup makes `tssh` and `tcopy` available on your PATH:

```sh
tssh mini@tailscale-host
```

Copy a directory using `tcopy SOURCE DESTINATION`:

```sh
tcopy mini@m6-1:/absolute/path/to/run-folder/ "$HOME/bench-m6-1-main/"
```

It uses rsync over `tssh`, with progress and partial transfers retained for
resuming. A trailing `/` on the source copies the directory's contents.

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.

When connecting from Ghostty, `tssh` uses the standard `xterm-256color` terminal
definition so fresh servers work without installing Ghostty's terminfo. This
preserves ordinary terminal functionality but omits Ghostty-specific features
such as styled underlines.
