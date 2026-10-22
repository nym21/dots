# dots

Shared macOS dotfiles and setup for a workstation or headless Mac mini.
Run commands from this repository's root as your normal login user.

## Setup

On a new Mac, as its user, with nothing installed yet:

```sh
curl -fsSL https://raw.githubusercontent.com/nym21/dots/main/bootstrap | bash -s -- pc
```

`bootstrap` installs the Command Line Tools, clones this repository into
`~/Developer/dots` over HTTPS, and runs `./pc/setup.sh`, which also installs
Claude Code and has dots push over SSH. Setup ends by listing what is left for
you, such as logins and Lockdown Mode, only while it is missing; run it again
to check. From a clone, run `./pc/setup.sh` directly.

For a headless mini, follow the [server setup instructions](server/README.md),
then run `bootstrap` with `server`, or `./server/setup.sh` from a clone.

Setup installs the shared packages and the selected role's additions.
It links `shared/home/` and the role's dotfiles into your home directory,
preserving existing files as `.backup`. Edit those repository files to change
the linked settings.

Codex and Claude Code settings are the exception: both write machine state
into them, such as trusted projects, hooks, and auto mode, so PC setup and
`ship update` merge `shared/home/.codex/config.toml` and
`shared/home/.claude/settings.json` into each machine's own file instead.
Shared keys overwrite the machine's values and everything else is kept.
Removing a key from a shared file does not remove it from machines that
already have it.

PC setup also installs Mullvad VPN when missing, which then updates itself,
and pins its tunnel's MTU to 1380, which Tailscale's packets need, with IPv6
off.

Rex's settings work the same way: Rex keeps them in its preferences, so
`pc/save.sh` saves them to `pc/rex-settings` and PC setup writes them back.

## Layout

- `shared/`: what both roles use: packages, shell and editor dotfiles, setup internals, and maintenance tools.
- `pc/`: the workstation: development tools, Codex and Claude Code, Rex and Zed settings, desktop setup, Tailscale SSH/copy commands, and Cloudflare's `cf`, which Bun runs since the workstation has no Node.
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
fleet update   # On the workstation: give each server its part and update it, in turn.
fleet restart  # On the workstation: restart the servers' workloads cleanly, in turn.
fleet tunnels  # On the workstation: give each server a tunnel named after it.
fleet purge    # On the workstation: purge Cloudflare's cache of the servers' hostnames.
```

`ship update` pulls this repository and runs the version pulled. It then
installs what the Brewfiles and Cargo lists gained, upgrades Homebrew, Rust,
and the listed Cargo tools, and on a server updates Rex and the workloads within
the mini's mode (see the [server instructions](server/README.md)). Last, if
macOS has an update or upgrade, it downloads the newest, waits 30 seconds for
Ctrl-C, stops a server's workloads cleanly, installs it, and restarts; the
workloads come back at boot. Without one, it installs the newest of the other
updates, such as the Command Line Tools.

It asks for a password only when a step needs root, and a run with nothing
such asks for none. Once it was typed, `ship update` installs
`/etc/sudoers.d/dots`, which lets the next runs install Apple's updates and,
on a server, restart the Rex and Tailscale daemons without one; setup installs
it too. Installing a daemon still asks. A macOS update always asks for the Mac
owner's password, so without a terminal `ship update` only downloads it.

The workstation decides what each server runs. `pc/fleet.conf` lists the
servers by their Tailscale names, each with its mode, prod, next, or local, and
the tunnels it shares. Cloudflare holds their tokens, and `fleet` keeps them
at hand in the Git-ignored `pc/.tunnels`, one `NAME TOKEN` per line, fetching
any it lacks with `cf`, so a new workstation needs only `cf auth login`. Each
server gets only those of its own tunnels. Each server also serves the tunnel
named after it, if there is one, to reach that server alone, at a hostname
such as `m4-1.bitview.space`.
A tunnel is named after what it serves: a mode's site (`prod`, `next`,
`local`), `mcp`, or a server. `fleet tunnels SERVER...`, all of them by
default, keeps Cloudflare to that with `cf`, once `cf auth login` has run: it
gives every tunnel its `pc/.tunnels` name, and for each server creates its
tunnel, routes the server's hostname alone through it to the site, makes that
hostname the only DNS name pointing at it, and saves its token in
`pc/.tunnels`, each only where that differs. Run it after adding a server to
`fleet.conf`. Since
tokens go out by name, `fleet update` first checks that every server is on the
tailnet under its `fleet.conf` name and calls itself that, and `fleet status`
also names a Mac on the tailnet that `fleet.conf` lacks. `fleet update SERVER...`, all of
them by default, brings the servers to the newest version of their mode:

1. It pins one version per mode for the whole run, the newest crates.io release
   in prod and the branch's current commit otherwise, so servers in the same
   mode end on the same version even when the branch moves meanwhile.
2. It readies every server at once, while all keep serving: it writes each
   one's mode and the run's versions, in local mode copies `~/Developer/mono`
   to it, and runs `ship fetch` there at a low priority, which builds them and
   downloads a macOS update, restarting nothing. A failed build stops the run
   before any server restarts.
3. Then it updates them in turn, and the servers that share a tunnel together,
   so a tunnel never serves two versions. Each leaves the shared tunnels while
   it updates, the others still serving them; the updated ones take them back
   before the last one leaves, which overlaps two versions for a few seconds
   rather than leaving the tunnel without a server.
4. For each server it gives it its tunnels, runs `ship update` there, which
   installs what was readied and restarts only what runs another build than
   the one installed, and waits until it serves again: workloads running,
   tunnels connected, and Bitview at the tip.
5. Once servers sharing tunnels all run a new version, it purges Cloudflare's
   cache of the hostnames their tunnels route, so none serves what the old
   version cached; servers already at the run's versions keep their tunnels
   throughout and their cache. `fleet purge SERVER...` purges by hand, as when a
   purge failed.

Groups not in prod go first, so a bad version shows there before prod, and one
server at a time, so prod never loses two at once. It stops if a server does
not serve again within 45 minutes. Selecting a server selects every server it
shares a tunnel with, and `fleet.conf` may not give a shared tunnel two modes.
`fleet status` prints a line per server and flags a server that differs from
`fleet.conf` or a tunnel that serves more than one version.

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

Keep every server's Rex reachable from the Rex app with `trex`, which also
makes each server a host of your Rex home, named after it, so the Rex app lists
it and `rex -S SERVER` reaches it:

```sh
trex         # forward every server in pc/fleet.conf
trex --stop  # stop them all until the next trex
```

The servers are those in `pc/fleet.conf`, by their Tailscale names. `trex`
checks a new one once and skips it unless it accepts your SSH key as
`mini` and runs a Rex server. Each server keeps the port it was first given, in
`~/Library/Application Support/trex/ports`, so its host stays valid; run
`trex` again after adding a server to `fleet.conf`. Each forward runs `tssh` as a LaunchAgent
that starts at login and reconnects on its own. The Rex app only accepts
http(s) hosts and Rex has no login on them, so any process on this Mac can use
the ports to act as the servers' users.

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.
