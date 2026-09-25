# dots

Shared macOS dotfiles and setup for a workstation or headless Mac mini.
Run commands from this repository's root as your normal login user.

## Setup

```sh
./pc/import.sh
```

For a headless mini, follow the [server setup instructions](server/README.md),
then run:

```sh
./server/import.sh
```

The importer installs the shared packages and the selected role's additions.
It links `shared/home/` and the role's dotfiles into your home directory,
preserving existing files as `.backup`. Edit those repository files to change
the linked settings.

## Layout

- `shared/`: common packages, dotfiles, setup internals, and maintenance tools.
- `pc/`: workstation applications, Zed settings, desktop setup, and `tssh`.
- `server/`: headless setup, profile, diagnostics, and workload launchers.

Each folder has its own `Brewfile`. Shared Cargo packages are listed in
`shared/cargo.txt`; Helix and its configuration are shared between both roles.

## Maintenance

```sh
./shared/update.sh        # Update Homebrew and installed Cargo packages.
./shared/macos-update.sh  # Confirm before installing macOS updates/restarting.
./shared/save.sh          # Save installed Cargo packages to shared/cargo.txt.
```

## SSH over Tailscale

PC setup makes `tssh` available on your PATH:

```sh
tssh mini@tailscale-host
```

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.

When connecting from Ghostty, `tssh` uses the standard `xterm-256color` terminal
definition so fresh servers work without installing Ghostty's terminfo. This
preserves ordinary terminal functionality but omits Ghostty-specific features
such as styled underlines.
