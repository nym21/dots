# dots

Shared macOS dotfiles and setup for a workstation and headless Mac minis.
The workstation is an agents' Mac: it runs T3 Code, Claude Code, and Codex,
controls the minis with `fleet`, and reaches them over Tailscale. It installs
what that work needs and nothing personal.
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
such as logins, while it is missing; run it again to check. T3 Code and the Rex
app are installed by hand.

Setup installs the shared packages and the role's, from the `Brewfile` and
`cargo.txt` in `shared/` and in the role's directory. It links `shared/home/`
and the role's dotfiles into your home directory, keeping existing files as
`.backup`; edit the repository's files to change them. On the workstation, it
also has dots push over SSH, as the workstation makes every Git write.

Codex and Claude Code write machine state into their settings, such as
trusted projects, hooks, and auto mode, so their settings cannot be linked:
setup and `ship update` merge `shared/home/.codex/config.toml` and
`shared/home/.claude/settings.json` into each machine's own file. Shared keys
overwrite the machine's values and the rest is kept; removing a key from a
shared file does not remove it from machines that have it.

Some apps cannot come from the Brewfile:

- **Mullvad VPN** updates itself, and Homebrew cannot adopt an existing copy
  without App Management access, so setup installs it from its cask only when
  missing.
- **`cargo-hawk`** comes from Astral's installer, which setup and `ship update`
  run when a newer release is out: Cargo cannot build it, and each release is
  built against one stable Rust, so a Rust update needs its newest.

Both roles turn the firewall on and Spotlight's index off. On the workstation,
setup keeps it from ever sleeping, on battery or with its lid closed too, and
its display on with no screen saver, so nothing locks it, which iPhone
Mirroring's automatic sign-in needs; with the lid closed, a display must stay
attached (an HDMI dummy does). It leaves Mullvad at its defaults but for what
something needs: its tunnel MTU at 1380, which Tailscale's packets need; the
local network shared; connecting at login; and split tunneling on, with
cloudflared, tssh's tailscaled, bitcoind and the agents (`claude`, `codex`)
excluded, `pc/split-tunnel.sh` saying why (see [Updates](#updates)). Its DNS
blocking stays off, as each of its lists blocks T3 Connect's relay. Its
account is logged in by hand. Setup also runs this Mac's Bitcoin Core node
(`pc/bitcoin.sh`, a LaunchAgent whose first sync runs fast, then plain) and
installs the private `stream` repo, the home video server.

## Layout

- `shared/`: what both roles use: packages, shell dotfiles, setup internals, and `ship`; also the servers' Helix config.
- `pc/`: the workstation: development tools, Codex and Claude Code, Chromium for screenshots and checks, `ffmpeg`, `ios-webkit-debug-proxy` for Mobile Safari on a real iPhone, Mullvad, `fleet`, the Tailscale SSH commands, and Cloudflare's `cf`, which Bun runs as the workstation has no Node.
- `server/`: headless setup, profile, Helix and difftastic, and the workloads.
- `tests/`: stand-in tests of `fleet` and the scripts it runs on the servers,
  each run on this Mac alone with fakes for whatever it would change or reach:
  `tests/run.sh` runs them all, in about 20 seconds, and fails when any check
  does. `tests/tunnels.sh` builds a stand-in `cloudflared`, so it needs Xcode's
  Command Line Tools.

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
fleet init     # On the workstation: what fleet needs from you, once: logins, tunnels, passwords, Rex.
fleet status   # On the workstation: one line per server, and what is due.
fleet update   # On the workstation: ready every server at once, then restart what changed, in turn.
fleet restart  # On the workstation: restart the servers' workloads cleanly, in turn.
fleet reboot   # On the workstation: restart the servers themselves, cleanly, in turn.
fleet shutdown # On the workstation: turn the servers off, cleanly, in turn.
fleet tunnels  # On the workstation: give the servers fleet.conf's tunnels at once, updating nothing.
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
installed, for the seconds that takes. It then runs `ship clean`, which keeps
what is in use and frees the rest: Homebrew's downloads, Rust toolchains but the
default and those a project pins, Cargo's caches, builds unused for 30 days,
old releases of Codex's packages, and simulator runtimes but the newest stable
iOS. Last, if macOS has an update, it downloads it, waits 30 seconds for
Ctrl-C, stops a server's workloads cleanly, installs it, and restarts, the
workloads coming back at boot, or at once if the install fails or does not
restart the Mac within 10 minutes; without one, it installs the newest of the
other updates, such as the Command Line Tools. On a server, `ship update` in a
terminal then moves the Tailscale daemon onto Homebrew's newest tailscaled
(see [Passwords](#passwords)).

### Passwords

`ship update` asks for a password only when a step needs root. With
`/etc/sudoers.d/dots`, which setup installs, it installs Apple's updates and,
on a server, restarts the Rex server without one; when that file lacks a rule,
the first such step asks once to add it, and that step and later runs need
none, and a rule dots no longer makes goes once a password is at hand.
Installing a daemon still asks, and macOS asks for its owner's password to
download an update as well as to install it, so without a terminal
`ship update` leaves it.

On a server, Tailscale's daemon runs as root from `/usr/local/libexec/tailscaled`,
a copy of Homebrew's that only root can change: Homebrew's own belongs to
`mini`, so root running it would let anything running as `mini` become root.
`server/tailscale.sh --update` brings the copy and the daemon onto Homebrew's
newest, which needs root, restarting the daemon only when that changes it,
and puts back what it ran should the daemon not come back within two minutes.

`fleet` holds the servers' password for the two jobs that need it there,
macOS's updates and the Tailscale daemon's. `fleet init` asks for `mini`'s
password on each server, trying the one just typed before asking for another,
checks it there, and keeps it in this Mac's login keychain; run again, it asks
only for one missing or no longer right, as after a change. `fleet update`
never asks: it checks each server's first, and one missing or no longer right
goes without those two jobs, saying to run `fleet init`, a refused one not
tried again until `fleet init` keeps another, so a changed password costs the
server one failed attempt rather than one an hour, and the run ends
failing, which `fleet auto` notifies; `ship status` lists `fleet init` while
one is not kept. Just before such a job, `fleet` writes the password to the
server's `~/.config/dots/password`, readable by `mini` alone, and the job,
through `shared/lent.sh`, reads it and deletes it at once, so it is on disk for
seconds, then only in that script's memory, never its environment; `sudo` and
`softwareupdate` get it on their input. One no job read, as when a restart
came first, goes at the server's next boot, at the next run's check, or at the
end of the run.

## Servers

The workstation decides what each server runs. `pc/fleet.conf` lists the
servers by their Tailscale names, each with its mode, release (crates.io),
prod, next or another branch, or local (the workstation's `~/Developer/mono`),
and the tunnels it shares. Mono's branches are tiers, each a prefix of the one
before it and promoted by fast-forward: `main` the releases, `prod` what
bitview.space runs, `next` the work in progress next.bitview.space shows, and
feature branches off `next`. Since tunnel tokens go out by name, `fleet update` first
checks that every server is on the tailnet under its `fleet.conf` name and
calls itself that; `fleet status` also names a Mac on the tailnet that
`fleet.conf` lacks.

### Tunnels

A tunnel is named after what it serves: a mode's site (`prod`, `next`,
`local`), `mcp`, or a server, which serves the tunnel named after it too, to
reach that server alone, at a hostname such as `m4-1.bitview.space`. Cloudflare
holds the tokens; `fleet` keeps them at hand in the Git-ignored `pc/.tunnels`,
one `NAME TOKEN` per line, fetching any it lacks with `cf`, so a new
workstation needs only Cloudflare's login. Each server gets only its own
tunnels' tokens.

`fleet tunnels [SERVER...]`, all of them by default, gives the servers the
tunnels `fleet.conf` gives them now and updates nothing, as when a tunnel moves
to other servers in an outage: first each takes those it gains, keeping those
it had, then each leaves those it no longer has, so a tunnel moved keeps a
server throughout, serving both versions meanwhile if it moves to another. A
server whose tunnels serve waits until each is connected; one whose tunnels
don't run, stopped or benching, only gets the token file, which they take when
they start, as reloading them would start its workloads. It refuses a shared
tunnel given two modes, or served in two versions by the servers that serve it
from now on, and purges the cache of the tunnels that changed servers.

### Borrowing a server

A mini borrowed for a benchmark or a long computation leaves `fleet.conf` while
it is lent, in commits like any other change, so dots stays clean and equal to
origin and `fleet auto` keeps updating the others, knowing nothing of it. Its
shared tunnels go first to every prod mini, which serve them on prod's version
meanwhile, through prod's own hand-over: on all of them, as a hand-over joins
only what the first half's servers are given. Every fleet run then notes the
mini as on the tailnet but not in `fleet.conf`, which says it is still lent.
For m6-2 and `next`, from `~/Developer/dots`, with m6-2 serving:

1. In `fleet.conf`, add `next` to every prod mini's line, and leave m6-2's line
   without tunnels, as `m6-2 next`: `fleet tunnels` changes only the servers
   `fleet.conf` names, so m6-2 dropped here would keep serving `next` on its
   own version beside prod's. Commit that alone and don't push yet: `fleet
   auto` skips while main differs from origin, where pushed first it could
   make the switch itself, in its own order.
2. `pc/fleet tunnels`: the prod minis take `next`, each waiting until it is
   connected, then m6-2 leaves it. `pc/fleet status` shows the prod minis with
   `prod mcp next` and m6-2 with its own tunnel alone. Push.
3. For a benchmark from a fresh boot, `pc/fleet reboot m6-2` now, as `fleet`
   acts only on a server `fleet.conf` names.
4. Remove m6-2's line, commit alone, push. m6-2 is the borrower's.

Another fresh boot during the borrow: put `m6-2 next` back in `fleet.conf`
without committing, so `fleet auto` skips, `pc/fleet reboot m6-2`, and
`git checkout pc/fleet.conf`.

To give it back:

1. Put `m6-2 next` back, without tunnels, commit alone, push, and
   `pc/fleet update m6-2`, which brings it to `next`'s newest version, however
   long Bitview takes on the data the borrow left, touching nothing else.
2. Once it serves, in `fleet.conf` give `next` back to m6-2 alone,
   `m6-2 next next`, and remove it from the prod minis. Commit alone, don't push
   yet, and `pc/fleet tunnels`: m6-2 takes `next`, waiting until it is
   connected, then the prod minis leave it, and its cache is purged. Push.

A prod mini is lent the same way, its line removed, but not while three serve
prod: the two left would update in halves of one, each alone in turn.

### Setting up

`fleet init [SERVER...]`, all of them by default, is what `fleet` needs from
you, once for a new workstation and again after adding a server to
`fleet.conf`, each part only where it is missing, so a rerun changes nothing.
In a terminal, in turn:

1. The tailnet's login: `tssh` prints the link to open on first use.
2. Cloudflare's: `cf auth login`, when `cf` is not logged in.
3. Each server's own tunnel, keeping Cloudflare to the names: it gives every
   tunnel its `pc/.tunnels` name, and for each server creates its tunnel,
   routes the server's hostname alone through it to the site, makes that
   hostname the only DNS name pointing at it, and saves its token, each only
   where that differs.
4. `mini`'s password on each server (see [Passwords](#passwords)).
5. The Rex app's forwards to the servers, with `trex`.

`ship status` says to run it, and which part is missing.

### Updates

`fleet update SERVER...`, all of them by default, brings the servers to the
newest version of their mode:

1. It pins one version per mode for the whole run, the newest crates.io release
   in release and the branch's current commit otherwise, so servers in the same
   mode end on the same version even when the branch moves meanwhile. A
   release counts once it has been out 10 minutes, as crates.io's index can
   lag behind a publish.
2. It readies every server at once, while all keep serving: it writes each
   one's mode and the run's versions, in local mode copies `~/Developer/mono`
   to it, and runs `ship fetch` there at a low priority, which does all of
   `ship update` that restarts nothing: Homebrew, Rust, Cargo, Rex's newest
   build, Bitview and the MCP server, the cleanup, and Apple's other updates
   while no macOS update waits; then macOS's download, as a job of its own,
   with the password `fleet` lends it (see [Passwords](#passwords)). Each is a
   job of the server's own, which finishes however
   this Mac or the connection fares. A group whose version cannot be found or
   whose servers fail to get ready is left as it is while the others update,
   and the run ends failing.
3. Then it updates those sharing a tunnel together, in two halves, each at
   once, so a tunnel never serves two versions and half the group keeps
   serving throughout: the first half, half the group rounded down, updates
   without the shared tunnels while the second still serves them, and takes
   them back before the second leaves and updates, which overlaps two versions
   for about a second rather than leaving the tunnel without a server: once
   the second half's token files drop them, each server of the first joins
   them, and the moment all say they are connected, the word to leave goes to
   each of the second over a connection opened beforehand, where its tunnels
   drop them and keep its own connected. Their cache is purged once its last
   requests on them end.
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
   shared tunnels once the second half of their group has left them, as the
   first serves them however long it recomputes. Both come before a macOS
   update. Servers already at the run's versions keep their tunnels
   throughout, and their cache. `fleet purge SERVER...` purges by hand.

Groups not in prod go first, so a bad version shows there before prod, and one
server at a time, so prod never loses two at once. Within a group, the order is
decided when the run starts: servers that do not serve go first, as updating
them costs no service, and before taking down a server that serves, `fleet`
checks that the others of its group serve, stopping otherwise, so it never
leaves a shared tunnel without a server it found serving; a macOS update
checks again just before its restart, and waits for a later run otherwise.
Every connection to a server has keepalives, so one that goes away mid-step
ends rather than waits, and one that stops answering while it readies, which
restarts nothing, is left out after an hour, its group with it, rather than
holding the others' update. It stops if `ship apply` fails, if a server does not
answer or serve again within 12 hours, or at once
when a workload of the server crashed, as it stays down until looked at, and if
it serves another version than the run's: the later servers, prod among them,
could fail the same way, and a shared tunnel would serve two versions.
Selecting a server selects every server it shares a tunnel with, and
`fleet.conf` may not give a shared tunnel two modes.

Whatever moment it stops at, as when this Mac sleeps, every shared tunnel keeps
a server, as a server takes a tunnel back before another leaves it. A step that
stops and starts what a server runs is a job of the server's own, started with
`nohup`, which finishes there however the connection fares, while `fleet`
follows its output and, after a lost connection, takes it up again, one job
at a time on each server, a later one waiting for an earlier one, as of a run
cut short. Last for each server, its Tailscale daemon moves onto Homebrew's
newest tailscaled, when that changes it, a failure stopping the run; then a
macOS update that the fetch found installs, with the lent password, as a job
of its own, and restarts the server, which must then serve again on the new
macOS before the next goes; the run ends failing when it did not update.

`fleet auto`, which a LaunchAgent that setup and `ship update` install runs
hourly, runs `fleet update` without a terminal, when this Mac is on power, its
dots is exactly origin's `main`, which the servers pull (not another branch, nor
changes left to commit, push or pull), and a server answers. That one check brings the servers a new crates.io release or
`next` commit within the hour, prod included, and Homebrew, Rust, Rex,
cloudflared, Bitcoin Core, Tailscale, and macOS's updates, major upgrades
included; a run with nothing new
restarts nothing. A closed or travelling Mac skips its hours, and the next one
it is open for catches up. It leaves alone a group of which a server does not
serve, as one stopped on purpose or after a crash, to be looked at, while the
other groups update; `fleet update` by hand starts with those servers instead.
`fleet reboot [SERVER...]` and `fleet shutdown [SERVER...]` restart or turn
off the Macs themselves, one at a time, each as a job with its password lent:
`server/power.sh`, which is `ship reboot` and `ship shutdown` there, stops the
workloads cleanly first, as shutting down would end Bitcoin Core mid-write, and
the boot daemon starts them again. A server that serves goes only while the
others of its group serve; rebooted, the next goes once it serves again, or,
one that wasn't serving, as a mini benching, once it answers on a new boot. A
fresh boot before a benchmark keeps runs comparable.

One `fleet update`, `restart`, `reboot` or `shutdown` runs at a time: another stops at once,
and an hourly run skips its turn, which a day without a completed run
notifies, as when one hangs. It keeps the Mac awake meanwhile, logs to
`~/Library/Logs/fleet-auto.log`, each line of a run with its time, and why it
skipped an hour, and notifies once when runs start failing, when one has run for a day, as when it hangs, or
when none has run for a day; `ship status` says
when none succeeded for over 3 days.

Being this Mac's one hourly job, `fleet auto` also runs `pc/tunnel.sh` every
hour, even one it skips, as `ship update` does after upgrading. It keeps this
Mac's own tunnel, `local`, which serves its Bitview at `local.bitview.space`,
as a LaunchAgent that starts it at login and again whenever it exits, logging
to `~/Library/Logs/local-tunnel.log`, and moves it onto a new cloudflared on
its own. First `pc/split-tunnel.sh`: Mullvad's split tunneling excludes
cloudflared by its versioned Cellar path, which an upgrade replaces, and
Cloudflare's tunnel servers are unreachable through Mullvad, so it excludes
the current binary, as setup has it do first, keeping the old one's while a tunnel
started before the upgrade still runs it, as dropping it would cut that tunnel
off until it restarts. Then the tunnel restarts onto the new binary, and its
start, as every start of it, moves the exclusion again, dropping the old one's.
The tunnel stops when `pc/.tunnels` lacks its token, which `fleet init`
fetches, or when `fleet.conf` gives `local` to a server, as two machines on
one tunnel would serve two versions.

### Status and alerts

`fleet status` prints a line per server and flags a server that differs from
`fleet.conf`, a tunnel that serves more than one version, a mode with a newer
version than its servers have, when an update is due, and a macOS update
downloaded for `fleet update` to install.

Cloudflare emails when a tunnel goes down, comes back, or degrades, and each
server's own tunnel says which server: a deliberate restart, a crash, a server
down, or Bitview stuck behind the tip (see the
[server instructions](server/README.md#cloudflare-tunnels)).

## SSH over Tailscale

PC setup makes `tssh`, `tcopy`, `tscreen`, and `trex` available on your PATH,
and `rex`, the Rex app's command-line tool, which the app keeps inside its
bundle:

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
`~/Library/Application Support/trex/ports`, so its host stays valid; `fleet init`
runs `trex` after adding a server to `fleet.conf`. Each forward runs `tssh` as a
LaunchAgent that starts at login and reconnects on its own. The Rex app only
accepts http(s) hosts and Rex has no login on them, so any process on this Mac
can use the ports to act as the servers' users.

Concurrent sessions share one local Tailscale daemon. It stops when the last
session closes, while authentication is retained for the next connection.
Without a terminal, as for `fleet auto`, it waits a minute at most for a login
no one can give, rather than forever once it expires. Its socket and lock
live beside its login, in `~/Library/Application Support/tailscale-userspace-ssh`,
rather than in a cache a cleaner may empty, and a daemon left running without
them, which would take the node's connection from a new one, is stopped
before the new one starts.
