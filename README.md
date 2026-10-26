# dots

Shared macOS dotfiles and setup for a workstation and headless Mac minis.
Run commands from this repository's root as your normal login user.

## Setup

On a new Mac, as its user, with nothing installed yet:

```sh
curl -fsSL https://raw.githubusercontent.com/nym21/dots/main/bootstrap | bash -s -- pc
```

`bootstrap` installs the Command Line Tools, clones this repository into
`~/Developer/dots` over HTTPS, and runs `./pc/setup.sh`; from a clone, run that
directly. For a headless mini, follow the
[server setup instructions](server/README.md), then run `bootstrap` with
`server`, or `./server/setup.sh`. Setup ends by listing what only you can do,
such as logins, Lockdown Mode, App Store apps, or a backup, while it is
missing; run it again to check.

Setup installs the shared packages and the role's, from the `Brewfile` and
`cargo.txt` in `shared/` and in the role's directory. It links `shared/home/`
and the role's dotfiles into your home directory, keeping existing files as
`.backup`; edit the repository's files to change them. On the workstation, it
also has dots push over SSH, as the workstation makes every Git write.

Some settings cannot be linked, as their programs rewrite them:

- **Codex and Claude Code** write machine state into their settings, such as
  trusted projects, hooks, and auto mode, so setup and `ship update` merge
  `shared/home/.codex/config.toml` and `shared/home/.claude/settings.json`
  into each machine's own file. Shared keys overwrite the machine's values and
  the rest is kept; removing a key from a shared file does not remove it from
  machines that have it.
- **Rex and macOS** keep theirs in their preferences, so `ship save` saves
  them to `pc/rex-settings` and `pc/macos-settings`, and setup writes them
  back. For macOS, those are the Dock, Finder, keyboard, trackpad, and
  screenshot settings this Mac sets among the ones `pc/save.sh` lists; add a
  `DOMAIN KEY` line there to keep another.

Some apps cannot come from the Brewfile:

- **Apps that update themselves or predate Homebrew here,** such as Mullvad
  VPN, ChatGPT, Claude, Discord, Signal, and GPG Suite: setup installs them from
  their casks only when missing, since Homebrew cannot adopt an existing copy
  without App Management access.
- **Sparrow Wallet** has its own installer, `pc/sparrow.sh`, which setup and
  `ship update` run, as a wallet must be its author's: it installs a release
  only once its manifest is signed by Craig Raw's PGP key, pinned by
  fingerprint, and lists the installer's checksum, and the app is signed by his
  Developer ID and notarized, as [Sparrow asks](https://sparrowwallet.com/download/).
  It leaves a running Sparrow alone; `pc/sparrow.sh --check` checks the
  installed one.
- **`cargo-hawk`** comes from Astral's installer, which setup and `ship update`
  run when a newer release is out: Cargo cannot build it, and each release is
  built against one stable Rust, so a Rust update needs its newest.
- **App Store apps** stay out, as Homebrew cannot see them without Spotlight's
  index; setup lists any missing.

Both roles turn the firewall on and Spotlight's index off. On the workstation,
setup pins Mullvad's tunnel MTU to 1380, which Tailscale's packets need, with
IPv6 off, and keeps Time Machine's automatic backups off (see
[Backups](#backups)).

## Layout

- `shared/`: what both roles use: packages, shell and editor dotfiles, setup internals, and `ship`.
- `pc/`: the workstation: development tools, Codex and Claude Code, Rex and Zed settings, desktop setup, `fleet`, the Tailscale SSH commands, and Cloudflare's `cf`, which Bun runs as the workstation has no Node.
- `server/`: headless setup, profile, and the workloads.

Each role's `setup.sh` sources `shared/setup.sh` for what both share. Servers
stay lean: development happens on the workstation.

## Maintenance

Every Mac has `ship`, for itself; the workstation also has `fleet`, for the
servers. Setup links them into `~/.local/bin` and records the Mac's role in
`~/.config/dots/role`. They run the scripts in this repository, so pulling it
updates them. `ship` alone lists this Mac's commands.

```sh
ship update    # Update everything and restart what changed; macOS last.
ship clean     # Free what caches and old builds take; ship update runs it too.
ship status    # On the workstation: what only you can do, while it is missing.
ship save      # On the workstation: save Cargo tools, Rex settings, and macOS settings into dots.
ship backup    # On the workstation: back up with Time Machine, then unmount its disk.
fleet status   # On the workstation: one line per server, and what is due.
fleet update   # On the workstation: ready every server at once, then restart what changed, in turn.
fleet restart  # On the workstation: restart the servers' workloads cleanly, in turn.
fleet tunnels  # On the workstation: give each server a tunnel named after it.
fleet purge    # On the workstation: purge Cloudflare's cache of the servers' hostnames.
fleet auto     # Run hourly by a LaunchAgent: fleet update, when this Mac can.
```

`ship update` pulls this repository and runs the version pulled. It installs
what the Brewfiles and Cargo lists gained, upgrades Homebrew, Rust, and the
listed Cargo tools, and names anything installed that the lists lack, so the
Macs stay alike: add it to one, or uninstall it. On a server it updates Rex and
the workloads within the mini's mode (see the
[server instructions](server/README.md)), in two halves that `fleet` runs
apart: `ship fetch` readies everything while the mini serves, restarting
nothing, then `ship apply` restarts only what runs an older build than the one
installed, for the seconds that takes. On the workstation it backs up whenever
the backup disk is in. It then runs `ship clean`, which keeps what is
in use and frees the rest: Homebrew's downloads, Rust toolchains but the
default and those a project pins, Cargo's caches, builds unused for 30 days,
old releases of Codex's packages, and simulator runtimes but the newest stable
iOS. Last, if macOS has an update, it downloads it, waits 30 seconds for
Ctrl-C, stops a server's workloads cleanly, installs it, and restarts, the
workloads coming back at boot; without one, it installs the newest of the other
updates, such as the Command Line Tools.

### Passwords

`ship update` asks for a password only when a step needs root. With
`/etc/sudoers.d/dots`, which setup installs, it installs Apple's updates and,
on a server, restarts the Rex and Tailscale daemons without one; when that file
lacks a rule, the first such step asks once to add it, and that step and later
runs need none. Installing a daemon still asks, and a macOS update always asks
for the Mac owner's password, so without a terminal `ship update` only
downloads it.

### Backups

The workstation backs up to Time Machine by hand, as automatic backups keep
snapshots on the local disk while the backup disk is away. `ship backup` leaves
out what can be rebuilt or downloaded again, such as Bitcoin Core's and
Bitview's data, toolchains, caches, and builds; unlocks the backup disk with
its password from the login keychain, asked once and checked; backs up; and
unmounts the disk, so the card can stay in for the next backup or come out,
which locks it. Without the disk it fails. `ship update` runs it whenever the
disk is in, and otherwise leaves Time Machine alone, saying only when the last
backup is missing or over a week old.

## Servers

The workstation decides what each server runs. `pc/fleet.conf` lists the
servers by their Tailscale names, each with its mode, prod (crates.io), next
or another branch, or local (the workstation's `~/Developer/mono`), and the
tunnels it shares. Since tunnel tokens go out by name, `fleet update` first
checks that every server is on the tailnet under its `fleet.conf` name and
calls itself that; `fleet status` also names a Mac on the tailnet that
`fleet.conf` lacks.

### Tunnels

A tunnel is named after what it serves: a mode's site (`prod`, `next`,
`local`), `mcp`, or a server, which serves the tunnel named after it too, to
reach that server alone, at a hostname such as `m4-1.bitview.space`. Cloudflare
holds the tokens; `fleet` keeps them at hand in the Git-ignored `pc/.tunnels`,
one `NAME TOKEN` per line, fetching any it lacks with `cf`, so a new
workstation needs only `cf auth login`. Each server gets only its own tunnels'
tokens.

`fleet tunnels SERVER...`, all of them by default, keeps Cloudflare to those
names: it gives every tunnel its `pc/.tunnels` name, and for each server
creates its tunnel, routes the server's hostname alone through it to the site,
makes that hostname the only DNS name pointing at it, and saves its token, each
only where that differs. Run it after adding a server to `fleet.conf`.

### Updates

`fleet update SERVER...`, all of them by default, brings the servers to the
newest version of their mode:

1. It pins one version per mode for the whole run, the newest crates.io release
   in prod and the branch's current commit otherwise, so servers in the same
   mode end on the same version even when the branch moves meanwhile. A
   release counts once it has been out 10 minutes, as crates.io's index can
   lag behind a publish.
2. It readies every server at once, while all keep serving: it writes each
   one's mode and the run's versions, in local mode copies `~/Developer/mono`
   to it, and runs `ship fetch` there at a low priority, which does all of
   `ship update` that restarts nothing: Homebrew, Rust, Cargo, Rex's newest
   build, Bitview and the MCP server, the cleanup, Apple's other updates, and
   macOS's download. Each is a job of the server's own, which finishes however
   this Mac or the connection fares. A group whose version cannot be found or
   whose servers fail to get ready is left as it is while the others update,
   and the run ends failing.
3. Then it updates them in turn, those sharing a tunnel together, so a tunnel
   never serves two versions: each leaves the shared tunnels while it updates,
   the others still serving them, and the updated ones take them back before
   the last one leaves, which overlaps two versions for a few seconds rather
   than leaving the tunnel without a server.
4. For each server it gives it its tunnels and runs `ship apply` there, which
   restarts only what runs another build than the one installed: the Rex
   server, Bitview and the MCP server, the tunnels, for a new cloudflared or
   the tokens just given, and the whole node for a new Bitcoin Core. Then it
   waits until the server serves again, workloads running, tunnels connected,
   and Bitview at the tip, and checks it runs the run's versions. A Bitview
   restart takes about 10 seconds, its load, or as long as it recomputes what
   a new version changed, and a run with nothing new stops nothing.
5. As soon as only servers on the new version serve a tunnel, it purges
   Cloudflare's cache of the hostnames the tunnel routes, so none serves what
   the old version cached: a server's own tunnel once it serves again, and the
   shared tunnels once the last server of their group has left them, as the
   others serve them however long it recomputes. Both come before a macOS
   update. Servers already at the run's versions keep their tunnels
   throughout, and their cache. `fleet purge SERVER...` purges by hand.

Groups not in prod go first, so a bad version shows there before prod, and one
server at a time, so prod never loses two at once. Within a group, the order is
decided when the run starts: servers that do not serve go first, as updating
them costs no service, and before taking down a server that serves, `fleet`
checks that the others of its group serve, stopping otherwise, so it never
leaves a shared tunnel without a server it found serving. It stops if
`ship apply` fails, if a server does not serve again within 12 hours, or at once
when a workload of the server crashed, as it stays down until looked at, and if
it serves another version than the run's: the later servers, prod among them,
could fail the same way, and a shared tunnel would serve two versions.
Selecting a server selects every server it shares a tunnel with, and
`fleet.conf` may not give a shared tunnel two modes.

Whatever moment it stops at, as when this Mac sleeps, every shared tunnel keeps
a server, as a server takes a tunnel back before another leaves it. A step that
stops and starts what a server runs is a job of the server's own, started with
`nohup`, which finishes there however the connection fares, while `fleet`
follows its output and, after a lost connection, takes it up again. From a
terminal, a macOS update that `ship fetch` downloaded then installs in it, to
ask for the password, and restarts the server; without one, it waits.

`fleet auto`, which a LaunchAgent that setup and `ship update` install runs
hourly, runs `fleet update` without a terminal, when this Mac is on power, its
dots is exactly origin's `main`, which the servers pull (not another branch, nor
changes left to commit, push or pull), and a server answers. That one check brings the servers a new crates.io release or
`next` commit within the hour, prod included, and Homebrew, Rust, Rex,
cloudflared, Bitcoin Core, and macOS's downloads; a run with nothing new
restarts nothing. A closed or travelling Mac skips its hours, and the next one
it is open for catches up. It leaves alone a group of which a server does not
serve, as one stopped on purpose or after a crash, to be looked at, while the
other groups update; `fleet update` by hand starts with those servers instead.
One `fleet update` or `fleet restart` runs at a time: another stops at once,
and an hourly run skips its turn. It keeps the Mac awake meanwhile, logs to
`~/Library/Logs/fleet-auto.log`, with why it skipped an hour, and notifies once
when runs start failing, or when none has run for a day; `ship status` says
when none succeeded for over 3 days.

### Status and alerts

`fleet status` prints a line per server and flags a server that differs from
`fleet.conf`, a tunnel that serves more than one version, a mode with a newer
version than its servers have, when an update is due, and a macOS update that
waits for `fleet update` in a terminal to install it.

Cloudflare emails when a tunnel goes down, comes back, or degrades, and each
server's own tunnel says which server: a deliberate restart, a crash, a server
down, or Bitview stuck behind the tip (see the
[server instructions](server/README.md#cloudflare-tunnels)).

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
checks a new one once and skips it unless it accepts your SSH key as `mini` and
runs a Rex server. Each server keeps the port it was first given, in
`~/Library/Application Support/trex/ports`, so its host stays valid; run `trex`
again after adding a server to `fleet.conf`. Each forward runs `tssh` as a
LaunchAgent that starts at login and reconnects on its own. The Rex app only
accepts http(s) hosts and Rex has no login on them, so any process on this Mac
can use the ports to act as the servers' users.

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.
