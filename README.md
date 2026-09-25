# dots

Shared macOS dotfiles and setup for a workstation or headless Mac mini.
Run commands from this repository's root as your normal login user.

## Setup

```sh
./shared/import.sh pc
```

For a headless mini, follow the [server setup instructions](server/README.md),
then run:

```sh
./shared/import.sh server
```

The importer installs the shared packages and the selected role's additions.
It links `shared/home/` and the role's dotfiles into your home directory,
preserving existing files as `.backup`. Edit those repository files to change
the linked settings.

## Layout

- `shared/`: importer, common packages, dotfiles, maintenance tools, and `tssh`.
- `pc/`: workstation applications, Zed settings, and desktop setup.
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

Setup makes `tssh` available on your PATH:

```sh
tssh mini@tailscale-host
```

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.
