# HostDeck

HostDeck checks, wakes and connects to the hosts on your network. It sends Wake-on-LAN packets to hosts that are off, then checks each host until it is ready for RDP or SSH. It can open SSH sessions in Terminal, and it can start your RDP app. It started as a graphical version of the `wake` command line script, with the extra steps of [wake-linux.sh](https://github.com/edrandall-dev/bash-public/blob/main/wake-linux.sh). The app was called Wake.

On the first start, HostDeck copies the hosts and settings of the old Wake app.

## Requirements

- macOS 14 (Sonoma) or later, on Apple silicon or Intel.
- Xcode, or the Xcode command line tools. To install the tools, run `xcode-select --install`.
- Each target host must support Wake-on-LAN, with the feature enabled in the firmware and in the network adapter settings.

## Install

1. Clone the repository and go to its directory:

   ```sh
   git clone https://github.com/edrandall-dev/hostdeck.git
   cd hostdeck
   ```

2. Build and install the app:

   ```sh
   ./build.sh
   ```

   The script compiles the app, makes the icon, signs the app ad hoc and copies it to `~/Applications/HostDeck.app`. To build without the install step, run `./build.sh --no-install`. The app is then in `build/HostDeck.app`.

3. Open HostDeck from `~/Applications` or from Spotlight.

To update the app, pull the latest changes and run `./build.sh` again. Quit HostDeck before you do this. Your hosts and settings stay.

## First run

1. Click **+** in the toolbar to add a host. The app starts with no hosts.
2. Set these fields for each host:

   | Field | Use |
   | --- | --- |
   | Name | The name in the list. |
   | OS | Linux, Windows or Other. This sets the service test (SSH or RDP), the default port and the buttons. Use Other for a device that you reach over SSH and that is not a Linux host, for example a router. |
   | Wake-on-LAN | Linux and Other. Turn it off for a host that is always on or that does not support Wake-on-LAN. The app then hides the MAC address and the Wake buttons. It is on by default for Linux and off for Other. Windows hosts always have Wake-on-LAN. |
   | MAC address | When Wake-on-LAN is on. The address of the network adapter on the target host. Any separator is permitted. |
   | Address | The IP address or hostname. The app needs it for the checks and to connect. |
   | Port | Leave it empty for the default (3389 for RDP, 22 for SSH). |
   | User | Linux and Other. The SSH user. Optional. |
   | SSH key | Linux and Other. The path to a private key, for example `~/.ssh/id_ed25519`. Optional. The app shows a warning if the file does not exist. |

3. Click **Wake**. macOS asks for permission for the app to find devices on the local network. Click **Allow**. If you do not allow it, the app cannot send packets or test hosts. To change this later, go to System Settings > Privacy & Security > Local Network.

If a packet does not reach a host, open HostDeck > Settings (⌘,) and set the subnet broadcast address, for example `192.168.1.255`.

### Prepare a Windows host

Windows Firewall blocks ping by default, so the ping check never passes. On the Windows host, enable the inbound firewall rule **File and Printer Sharing (Echo Request - ICMPv4-In)**. As administrator, you can also run this command in PowerShell:

```powershell
Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In
```

Remote Desktop must also be on (Settings > System > Remote Desktop).

## Use

| Control | Shortcut | Action |
| --- | --- | --- |
| Wake | ⌘↩ | Send the wake packet, then wait for each check to pass. |
| Wake and Connect | ⇧⌘↩ | Linux and Other, when Wake-on-LAN is on. As Wake, then open an SSH session when the host is ready. |
| Test | ⌘T | Do each check one time. The app sends no wake packet. |
| Connect | | Linux and Other, when the host is ready. Open an SSH session now. |
| Open RDP App | | Windows only, when the host is ready. Choose an RDP app, and HostDeck starts it. |
| Cancel | Esc | Stop the wait. |

The server rack icon in the menu bar gives the same commands for each host when the main window is closed.

For a Linux or Other host, Connect opens `ssh` in Terminal. HostDeck does not store passwords. If the key does not log you in, `ssh` asks for the password in Terminal.

For a Windows host, the log shows "ready for RDP connections" when the host passes all the checks. Open RDP App shows a menu of the installed apps that open RDP connections, for example [Windows App](https://apps.apple.com/app/windows-app/id1295203466). HostDeck starts the app that you choose and does nothing more. Connect to the host from that app.

### Checks

The app does the checks in this sequence, and stops at the first check that fails.

1. Ping. The app sends one ICMP echo a second until the host replies.
2. Service port. The app opens a TCP connection to the RDP or SSH port.
3. Service test:
   - Windows: the app sends an RDP connection request and waits for the X.224 Connection Confirm. This shows that an RDP service answers, not only that the port is open.
   - Linux and Other: if the host has an SSH key, the app logs in with `ssh` and that key only. The test passes when `ssh` reports that the login succeeded, so it also works on devices with no shell, for example RouterOS. Without a key, the app does not do this step.

After a wake packet, the app repeats checks 1 and 2 until they pass or the timeout ends. The default timeout is 180 seconds. You can change it in Settings.

### Status

The app checks each host every 15 seconds, and also when you select a host. The list shows a status symbol for each host. Next to the buttons, the app shows the status of the selected host in words, for example "Online: ready for RDP".

While a host is online (it replies to ping), you cannot click Wake or Wake and Connect, because the host is already awake. Connect and Open RDP App are available only while the host is ready (it replies to ping and its service port is open). They are not available while a run is busy. If a Wake or Test run fails, for example at the RDP handshake or the SSH login, they stay unavailable until a later run passes. Test is always available, so you can check the host again. Hold the pointer over a faded Connect or Open RDP App button to see why it is not available.

| Symbol | Meaning |
| --- | --- |
| Filled circle with a tick (green) | The host replies to ping and the service port is open. |
| Filled circle with "!" (orange) | The host replies to ping, but the service port does not answer. |
| Empty circle with "x" (red) | No reply to ping. |
| Dashed circle (grey) | No address is set, or the app has not tested the host yet. |

Each status has its own shape, so you can read it without the colour.

The bottom of the host list shows a key for these symbols, the number of hosts that are online, and the time of the last check. The ? button opens the HostDeck page on [edrandall.uk](https://www.edrandall.uk/lab-notes/hostdeck/).

## Notes

- The SSH login test uses `StrictHostKeyChecking=accept-new`. On the first login, the test adds the host key to `~/.ssh/known_hosts`. If the host key changes, the test fails.
- The build signs the app ad hoc. After a rebuild, macOS can ask again for Local Network permission.
- The app keeps its hosts in its own preferences. It does not read or change the `HOSTS` list of the `wake` command line script.
- To open HostDeck when you log in, add it in System Settings > General > Login Items.

## Uninstall

1. Quit HostDeck.
2. Remove the app and its preferences:

   ```sh
   rm -rf ~/Applications/HostDeck.app
   defaults delete uk.edrandall.hostdeck
   ```

## Files

| File | Purpose |
| --- | --- |
| `Sources/HostDeck.swift` | The source of the app. |
| `Resources/Info.plist` | The bundle information, with the Local Network usage text. |
| `Tools/make-icon.swift` | Draws the app icon. `build.sh` runs it. |
| `build.sh` | Builds, signs and installs the app. |
| `LICENSE` | The MIT License. |

## Licence

HostDeck is available under the [MIT License](LICENSE).
