# Headless Mac mini setup

Run `./import-server.sh` as the server's administrator, without `sudo`.
The terminal running setup needs Full Disk Access for macOS sharing controls.
Connect and verify Ethernet before setup disables Wi-Fi and Bluetooth.

For initial Tailscale setup, run `./tailscale-cli.sh` separately and authenticate.
It installs the system daemon so remote access does not require a desktop login.
Keep the server at the login screen and run persistent workloads as LaunchDaemons
under their intended user. Do not enable automatic desktop login.

The server import keeps SSH, Screen Sharing, and SMB enabled. It disables
Spotlight indexing on mounted volumes, Content Caching, printer sharing, and
remote Apple Events. It also prevents idle sleep and enables restart after power
loss. Screen Sharing and SMB start on demand without being restarted on reruns.

## Settings to finish in macOS 27

Configure these once for the server's login user, using Screen Sharing if needed,
then log out of the desktop. Recheck them after major macOS upgrades.

- **General > AirDrop & Continuity:** turn off Handoff and AirPlay Receiver;
  set AirDrop receiving to No One.
- **General > Sharing:** turn off Media Sharing and Bluetooth Sharing. Keep
  Remote Login, Screen Sharing, and File Sharing enabled. In Remote Login,
  enable full disk access for remote users; in File Sharing, enable full disk
  access for all users if using the intended full-volume administrator shares.
- **Siri:** turn off Siri. Under **Notifications**, turn off notification
  summaries. If Mail or Messages were configured previously, turn off their
  summaries too. Apple Intelligence controls are feature-specific in macOS 27;
  use **Screen Time > Content & Privacy > Siri** (or **Intelligence & Siri**,
  depending on language and Siri version) to restrict remaining AI features.
- **Privacy & Security > Analytics & Improvements:** turn off optional analytics
  sharing and improvement contributions.
- **General > Login Items & Extensions:** remove unneeded login items and turn
  off unneeded Background App Activity. Preserve services needed by the server.

These settings use Apple's supported UI because this setup does not have a
verified macOS 27 command-line equivalent for them. Turning off a feature does
not necessarily remove its process from the process list.

Apple references: [sharing](https://support.apple.com/en-lk/guide/mac-help/mchl26e04309/mac),
[AirDrop and Continuity](https://support.apple.com/en-me/guide/mac-help/mchl6a407f99/mac),
[Siri and Apple Intelligence](https://support.apple.com/en-az/guide/mac-help/mchlb2e44f94/mac),
[background app activity](https://support.apple.com/en-me/125671),
[analytics](https://support.apple.com/en-za/guide/mac-help/mchl211c911f/mac).

## Audit and verify

Run `./server-audit.sh` on each mini before and after cleanup. It reports service
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
