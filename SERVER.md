# Headless Mac mini setup

Before running setup, grant Full Disk Access on the mini:

- **Over SSH:** System Settings > General > Sharing > Remote Login > Info >
  Allow full disk access for remote users, then reconnect over SSH.
- **In a local terminal:** System Settings > Privacy & Security > Full Disk
  Access > enable the terminal app, then quit and reopen it.

Run `./import-server.sh` as the server's administrator, without `sudo`.
The script uses `sudo` where needed; it does not grant macOS Full Disk Access.
Before making setup changes, it authenticates with `sudo` and checks read access
to a protected system file. If access cannot be verified, it stops with the
instructions above. This is a read-only probe, not a macOS permission-query API.
Connect and verify Ethernet before setup disables Wi-Fi and Bluetooth.

For initial Tailscale setup, run `./tailscale-cli.sh` separately and authenticate.
It installs the system daemon so remote access does not require a desktop login.
Keep the server at the login screen and run persistent workloads as LaunchDaemons
under their intended user. Do not enable automatic desktop login.

The server import keeps SSH, Screen Sharing, and SMB enabled. It disables
Spotlight indexing on mounted volumes, Content Caching, printer sharing, and
remote Apple Events. It also prevents idle sleep and enables restart after power
loss. Screen Sharing and SMB start on demand without being restarted on reruns.
The import runs the read-only server audit at the end. Fish is configured as the
login shell for future terminal and SSH sessions; `exec fish -l` is only needed
to switch the terminal that launched the import immediately.

## Finish once in System Settings

Use the mini's desktop or Screen Sharing. Skip items already completed.

1. **General > Device Management:** install **Headless Mac mini server** from
   [server.mobileconfig](server.mobileconfig). Local setup opens the file if
   the profile is missing. After SSH setup, open the file on the mini itself.
2. **General > Sharing:** enable File Sharing's **Allow full disk access for all
   users**, and Remote Login's **Allow full disk access for remote users** if
   setup was run locally. Turn off **Media Sharing** and **Bluetooth Sharing**.
3. **Notifications:** turn off notification summaries. If Mail or Messages was
   previously configured, turn off automatic summaries there too.
4. **Privacy & Security > Analytics & Improvements:** turn off any remaining
   optional improvement contributions.
5. **General > Login Items & Extensions:** disable unused third-party login
   items and Background App Activity. Keep the server's workload services.

Then log out of the desktop. Fish applies automatically to new terminal/SSH
sessions. Recheck these settings after a major macOS upgrade.

The profile configures Handoff, AirDrop, AirPlay Receiver, diagnostic submission,
Siri, external AI integrations, and supported Apple Intelligence features off.
It adds no background service. Its Mail summary restriction covers manually
requested summaries, not automatic summaries, which remain in the list above.
Reinstall the profile after changing `server.mobileconfig`; setup checks whether
its identifier is installed, not whether its contents have changed. Remove it
from Device Management to release its restrictions.

macOS requires approval in System Settings to install local configuration
profiles. Full Disk Access requires separate consent on these unmanaged Macs;
the initial setup check covers the process running setup, not File Sharing.
No TCC database edits or undocumented preference writes are used for these
settings. Turning a feature off does not guarantee its process disappears.

Apple references: [profile installation](https://support.apple.com/guide/mac-help/mh35561/mac),
[profile restrictions](https://developer.apple.com/documentation/devicemanagement/restrictions),
[managed privacy permissions](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol),
[background app activity](https://support.apple.com/en-me/125671).

## Audit and verify

The import runs `./server-audit.sh` automatically; run it separately whenever
you want another snapshot, including before cleanup. It reports service
registrations, launchd jobs, indexing status, and a process snapshot; it does not
stop services or uninstall software. A registered job is not necessarily a
running process, and a process snapshot alone does not establish sustained load.

Remove confirmed unused third-party services through their owning application
or service manager. Keep required Tailscale, tunnel, and workload services. Do
not disable Apple daemons indiscriminately: DNS, logging, security, and update
services remain necessary. Use CPU activity, disk activity, and memory pressure
to decide whether further cleanup is useful.

After attaching a new data disk, check `mdutil -as`. Disable indexing for that
specific volume if needed with `sudo mdutil -i off "/Volumes/your-data-disk"`.
An idle `mds` process does not by itself indicate that indexing is enabled.

After a planned reboot, verify from another machine that Tailscale, SSH, SMB,
and Screen Sharing work while the mini remains at the login screen. Also verify
that data volumes mount and workloads resume without a desktop login.
