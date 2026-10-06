# Headless Mac mini setup

Commands below run from the repository root unless stated otherwise.

Setup requires Full Disk Access on the mini. If the startup access check fails:

- **Over SSH:** System Settings > General > Sharing > Remote Login > Info >
  Allow full disk access for remote users, then reconnect over SSH.
- **In a local terminal:** System Settings > Privacy & Security > Full Disk
  Access > enable the terminal app, then quit and reopen it.

From the repository root, run `./server/setup.sh` as the server's user, without `sudo`.
The script uses `sudo` where needed; it does not grant macOS Full Disk Access.
Before making setup changes, it authenticates with `sudo` and checks read access
to a protected system file. If access cannot be verified, it stops with the
instructions above. This is a read-only probe, not a macOS permission-query API.
Connect and verify Ethernet before setup disables Wi-Fi and Bluetooth.

For initial Tailscale setup, run `./server/tailscale.sh` separately and authenticate.
It installs the system daemon so remote access does not require a desktop login.
Keep the server at the login screen and run persistent workloads as LaunchDaemons
under their intended user. Do not enable automatic desktop login.

From your other Mac, use `tssh mini@tailscale-host` in each terminal. Concurrent
connections share one local userspace Tailscale daemon, which stops after the
last SSH session closes. Authentication is saved for next time. Close any
sessions started with the older, single-session `tssh` before using this version.

`tssh` uses `xterm-256color` when connecting from Ghostty, so the mini needs no
extra terminal definition. Reconnect with the updated local `tssh` to apply it.
For an existing session reporting `missing or unsuitable terminal: xterm-ghostty`:

```sh
TERM=xterm-256color tmux
```

Server setup keeps SSH and Screen Sharing enabled. File transfers use `tcopy`
over SSH. It disables File Sharing (SMB), Spotlight indexing on mounted volumes,
Content Caching, printer sharing, and remote Apple Events. It also prevents idle
sleep and enables restart after power loss. Screen Sharing starts on demand
without being restarted on reruns.
Setup also installs the login-aware `audiomxd` suspension workaround below.
Fish is configured as the login shell for future terminal and SSH sessions;
`exec fish -l` is only needed
to switch the terminal that launched setup immediately.

## Finish once in System Settings

For a new Mac, use its desktop or Screen Sharing. Skip items already completed.

In **General > Device Management**, install **Headless Mac mini server** from
[profile.mobileconfig](profile.mobileconfig). Local setup opens the file if
the profile is missing. After SSH setup, open the file on the mini itself.

Then log out of the desktop. Fish applies automatically to new terminal/SSH
sessions. Recheck these settings after a major macOS upgrade.

The profile configures Handoff, AirDrop, AirPlay Receiver, diagnostic submission,
Siri, external AI integrations, and supported Apple Intelligence features off.
It also forces settings that have no restriction off: "Hey Siri", the Siri menu
bar icon, automatic summaries in Mail, Messages, and notifications, inline text
predictions, and Spatial Photos. It adds no background service.
When changing `server/profile.mobileconfig`, replace its top-level `PayloadUUID`
with a new `uuidgen` value. Setup compares it with the installed profile and
asks for a reinstall when they differ. Remove the profile from Device
Management to release its restrictions.

macOS requires approval in System Settings to install local configuration
profiles. The profile does not modify Full Disk Access; the initial setup check
covers the process running setup.
No TCC database edits are used. The forced settings and model download block use
undocumented preference keys, mapped by
[RemoveMacAI](https://github.com/omlahore/RemoveMacAI) and
[pared](https://github.com/4evy/pared); recheck them after a macOS upgrade.
Turning a feature off does not guarantee its process disappears.

Apple references: [profile installation](https://support.apple.com/guide/mac-help/mh35561/mac),
[profile restrictions](https://developer.apple.com/documentation/devicemanagement/restrictions),
[managed privacy permissions](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol).

### Apple Intelligence models

The profile stops macOS downloading the Apple Intelligence models again, but it
does not delete models already on disk. To delete them once, on the mini's
desktop or through Screen Sharing:

```sh
brew install omlahore/tap/removemacai
removemacai off
```

RemoveMacAI installs its own profile before deleting the models. Check the
result with `removemacai status`, then remove the **RemoveMacAI** profile in
**General > Device Management** and run `brew uninstall removemacai`. The server
profile keeps the downloads blocked. macOS deletes the model files on its own
schedule, so Storage settings can count them for a while.

## Optional cleanup

These settings are not applied by the profile. On a fresh headless Mac, review
them only if enabled during setup:

- **General > Sharing:** turn off Media Sharing and Bluetooth Sharing.
- **Privacy & Security > Analytics & Improvements:** turn off other optional
  contributions. The profile blocks automatic diagnostic submission only.

## audiomxd workaround

macOS's `audiomxd` loops on the CPU while no one is logged in. Server setup
installs `com.local.suspend-audiomxd` under `/Library/LaunchDaemons`, a small
guard that replaces earlier versions of this workaround. Every two seconds it
checks who owns the console:

- At the login screen, it suspends `audiomxd` with `SIGSTOP`, including a
  daemon that restarted since the last check.
- Once a user logs in, locally or through Screen Sharing, it resumes the
  daemon with `SIGCONT`.

macOS does not restart a suspended daemon, so every app that touches audio
waits on it indefinitely. Suspending it during a desktop session makes apps,
Safari, and the menu bar hang, which is why the guard applies only at the
login screen. Audio may take up to two seconds to resume after logging in.

`server/locate.sh` keeps the daemon running during playback by refreshing
`/var/run/com.local.audiomxd-hold`. The guard ignores a hold older than one
minute, so an interrupted script cannot leave the workaround off for long.
This is a workaround for the macOS bug and does not change SIP.

At the login screen, verify that the daemon's state contains `T` and check
whether `configd` CPU falls; in a desktop session the state should not
contain `T`:

```sh
ps -axo pid,state,pcpu,comm | rg 'PID|audiomxd|configd'
sudo launchctl print system/com.local.suspend-audiomxd
```

The guard should be listed as running. If a desktop session is frozen by an
earlier version of the workaround, run `sudo killall -CONT audiomxd`, then
rerun server setup.

To remove the workaround and resume audio, run in this order:

```sh
sudo launchctl bootout system/com.local.suspend-audiomxd
sudo rm /Library/LaunchDaemons/com.local.suspend-audiomxd.plist
sudo killall -CONT audiomxd
```

Running server setup again reinstalls the workaround.

## Workloads

Run each workload in its own terminal or tmux pane:

| Script | Purpose |
| --- | --- |
| `server/bitcoin.sh` | Run Bitcoin Core with data in `/Volumes/External/bitcoin`. |
| `server/bitview.sh` | Update Rust, install Bitview, and run the indexer/server. |
| `server/bench.sh` | Update Rust, install `bitviewd_bench`, and run the bootstrap benchmark. |
| `server/mcp.sh` | Install and run the Bitview MCP server. |
| `server/tunnels.sh` | Run and monitor all configured Cloudflare tunnels together. |

The Bitcoin launcher requires the external volume to be mounted and creates
its data directory if needed. Extra Bitcoin Core arguments are forwarded; for
the initial sync with the larger cache:

```sh
./server/bitcoin.sh -dbcache=8192
```

The launchers preserve the caller's working directory. Bitview and the benchmark
set `RUSTFLAGS="-C target-cpu=native"` explicitly for installation. MCP uses the
shared native-CPU settings in `shared/home/.cargo/config.toml`, linked during setup.
These are foreground launchers; use LaunchDaemons for automatic startup at boot.

Bitview and the benchmark install from crates.io by default. Each accepts one
optional argument: a branch of the official `bitcoinresearchkit/mono` repository.
They do not require a local checkout or forward runtime arguments:

```sh
./server/bitview.sh        # crates.io
./server/bitview.sh main   # official repository's main branch
./server/bench.sh          # crates.io
./server/bench.sh main     # official repository's main branch
```

Bitview passes `--bitcoindir /Volumes/External/bitcoin`,
`--bitviewdir /Volumes/External/bitview`, and `--cdn true` directly, so those
settings do not require a config file. An existing config file still supplies
other settings.

Both launchers create `/Volumes/External/bitview` if it does not exist.

The benchmark uses `/Volumes/External/bitcoin` and
`/Volumes/External/bitview`. Existing data is reused; change the
script's `--bitviewdir` to an empty directory for a full rebuild. Bitcoin Core
must be running and synced. The benchmark exits after bootstrap without starting
the HTTP server. Results are stored under
`/Volumes/External/bitview/benches/bitviewd/run-<timestamp>/`, following
`--bitviewdir`. It prints that path before bootstrap starts and after completion.

## Cloudflare tunnels

Place all raw tunnel tokens in `server/.tokens`, one per line. Blank lines
and lines starting with `#` are ignored; surrounding whitespace is trimmed:

```text
# Shared bitview.space domain
PASTE_SHARED_TOKEN_HERE

# This server's euX.bitview.space domain
PASTE_NODE_TOKEN_HERE

# MCP endpoint
PASTE_MCP_TOKEN_HERE
```

The launcher runs every token, regardless of its comment or position in the list.
Move tokens from the old `shared.token`, `node.token`, and `mcp.token` files into
this list if upgrading an existing setup.

The token file is ignored by Git and resolved relative to `tunnels.sh`, so
the launcher works from any directory. Start Bitcoin Core, Bitview, and the MCP
server first, then run:

```sh
./server/tunnels.sh
```

All tunnels log to the same terminal. Ctrl-C stops the tunnels started by
this launcher. If Bitcoin Core, Bitview, the MCP server, or any tunnel exits, the
launcher stops its remaining tunnels and exits; rerun it once the problem is resolved.

## Locate a mini

Run `./server/locate.sh` on the mini to loop a short sound, or start it remotely:

```sh
ssh -t mini@192.168.1.130 '~/Developer/dots/server/locate.sh'
```

The script downloads nothing. It unmutes the current output and sets its volume
to 100%. If `SwitchAudioSource` is already installed, it prefers the built-in
speaker; otherwise, select it in **System Settings > Sound > Output** if needed.
Ctrl-C stops playback and restores the previous output, volume, and mute state.
At the login screen, the script uses `sudo` to hold `audiomxd` running before
touching audio settings and releases the hold after restoring them; the guard
then suspends it again within two seconds. It also cleans up on termination,
SSH disconnection, or command failure.

## Verification

After attaching a new data disk, check `mdutil -as`. Disable indexing for that
specific volume if needed with `sudo mdutil -i off "/Volumes/your-data-disk"`.
An idle `mds` process does not by itself indicate that indexing is enabled.

After a planned reboot, verify from another machine that Tailscale, SSH, `tcopy`,
and Screen Sharing work while the mini remains at the login screen. Also verify
that data volumes mount and workloads resume without a desktop login.
