# Headless Mac mini setup

Commands below run from the repository root unless stated otherwise.

Setup requires Full Disk Access on the mini. If the startup access check fails:

- **Over SSH:** System Settings > General > Sharing > Remote Login > Info >
  Allow full disk access for remote users, then reconnect over SSH.
- **In a local terminal:** System Settings > Privacy & Security > Full Disk
  Access > enable the terminal app, then quit and reopen it.

From the repository root, run `./server/setup.sh` as the server's administrator, without `sudo`.
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

Server setup keeps SSH, Screen Sharing, and SMB enabled. It disables
Spotlight indexing on mounted volumes, Content Caching, printer sharing, and
remote Apple Events. It also prevents idle sleep and enables restart after power
loss. Screen Sharing and SMB start on demand without being restarted on reruns.
Setup also installs the once-per-boot `audiomxd` suspension workaround below.
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
It adds no background service. Its Mail summary restriction covers manually
requested summaries, not automatic summaries; Mail and Messages need no setup
on a fresh server without those accounts configured.
Reinstall the profile after changing `server/profile.mobileconfig`; setup checks whether
its identifier is installed, not whether its contents have changed. Remove it
from Device Management to release its restrictions.

macOS requires approval in System Settings to install local configuration
profiles. The profile does not modify Full Disk Access; the initial setup check
covers the process running setup, not File Sharing.
No TCC database edits or undocumented preference writes are used for these
settings. Turning a feature off does not guarantee its process disappears.

Apple references: [profile installation](https://support.apple.com/guide/mac-help/mh35561/mac),
[profile restrictions](https://developer.apple.com/documentation/devicemanagement/restrictions),
[managed privacy permissions](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol).

## Optional cleanup

These settings are not applied by the profile. On a fresh headless Mac, review
them only if enabled during setup:

- **General > Sharing:** turn off Media Sharing and Bluetooth Sharing.
- **Notifications:** turn off notification summaries.
- **Privacy & Security > Analytics & Improvements:** turn off other optional
  contributions. The profile blocks automatic diagnostic submission only.

## audiomxd workaround

Server setup installs the suspension workaround for the logged-out
`audiomxd` CPU loop directly. It installs `com.local.suspend-audiomxd` under
`/Library/LaunchDaemons` and replaces the earlier periodic job if present.
It runs immediately and at each boot, waits up to two minutes to successfully
send `SIGSTOP` to `audiomxd`, then exits. It does not terminate the daemon or
retry after a successful suspension.
If `audiomxd` restarts later in the same boot, it is left running.

Audio/media operations may stall while the daemon is suspended, including the
sound used by `server/locate.sh`. This is a workaround for the macOS bug and does
not change SIP.

Verify that the daemon's state contains `T` and check whether `configd` CPU falls:

```sh
ps -axo pid,state,pcpu,comm | rg 'PID|audiomxd|configd'
sudo launchctl print system/com.local.suspend-audiomxd
```

After the helper exits, its `last exit code` should be `0`. If it cannot suspend
the daemon within the startup wait, it exits with an error and is not retried.

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
| `server/tunnels.sh` | Run and monitor the three Cloudflare tunnels together. |

The Bitcoin launcher requires the external volume to be mounted and creates
its data directory if needed. Extra Bitcoin Core arguments are forwarded; for
the initial sync with the larger cache:

```sh
./server/bitcoin.sh -dbcache=8196
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

The benchmark uses `/Volumes/External/bitcoin` and
`/Volumes/External/bitview-bench`. Existing benchmark data is reused; change the
script's `--bitviewdir` to an empty directory for a full rebuild. Bitcoin Core
must be running and synced. The benchmark exits after bootstrap without starting
the HTTP server and prints its results directory. Results are stored under
`benches/bitviewd/run-<timestamp>/` in the source workspace used to build it;
with a Git installation, that workspace is in Cargo's Git checkout cache.

## Cloudflare tunnels

Place the raw token for each tunnel in its corresponding local file:

| File | Route |
| --- | --- |
| `server/shared.token` | Shared `bitview.space` domain. |
| `server/node.token` | This server's `euX.bitview.space` domain. |
| `server/mcp.token` | MCP endpoint. |

Token files are ignored by Git. They are resolved relative to `tunnels.sh`, so
the launcher works from any directory. Start Bitcoin Core and Bitview first,
then run:

```sh
./server/tunnels.sh
```

All three tunnels log to the same terminal. Ctrl-C stops the tunnels started by
this launcher. If Bitcoin Core, Bitview, or any tunnel exits, the launcher stops
its remaining tunnels and exits; rerun it once the problem is resolved.

## Locate a mini

Run `./server/locate.sh` on the mini to loop a short sound, or start it remotely:

```sh
ssh -t mini@192.168.1.130 '~/Developer/dots/server/locate.sh'
```

The script downloads nothing. It unmutes the current output and sets its volume
to 100%. If `SwitchAudioSource` is already installed, it prefers the built-in
speaker; otherwise, select it in **System Settings > Sound > Output** if needed.
Ctrl-C stops playback and restores the previous output, volume, and mute state.

## Verification

After attaching a new data disk, check `mdutil -as`. Disable indexing for that
specific volume if needed with `sudo mdutil -i off "/Volumes/your-data-disk"`.
An idle `mds` process does not by itself indicate that indexing is enabled.

After a planned reboot, verify from another machine that Tailscale, SSH, SMB,
and Screen Sharing work while the mini remains at the login screen. Also verify
that data volumes mount and workloads resume without a desktop login.
