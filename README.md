# HostDeck

HostDeck checks, wakes and connects to the hosts on your network. It sends Wake-on-LAN packets to hosts that are off, then checks each host until it is ready for RDP, SSH or Screen Sharing. It can open SSH sessions in Terminal, and it can start Screen Sharing or your RDP app. It started as a graphical version of the `wake` command line script, with the extra steps of [wake-linux.sh](https://github.com/edrandall-dev/bash-public/blob/main/wake-linux.sh). The app was called Wake.

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

2. Make a signing certificate. Do this one time on each Mac:

   ```sh
   Tools/make-signing-cert.sh
   ```

   The script adds a self-signed code signing certificate, "HostDeck Local Signing", to your login keychain. It is valid for 10 years. This step is optional, but without it macOS can drop the Local Network permission after each rebuild. See [Signing](#signing).

3. Build and install the app:

   ```sh
   ./build.sh
   ```

   The script compiles the app, makes the icon, signs the app and copies it to `~/Applications/HostDeck.app`. The first time it signs with the certificate, macOS asks to let `codesign` use the key. Click **Always Allow**. To build without the install step, run `./build.sh --no-install`. The app is then in `build/HostDeck.app`.

4. Open HostDeck from `~/Applications` or from Spotlight.

To update the app, pull the latest changes and run `./build.sh` again. Quit HostDeck before you do this. Your hosts and settings stay.

## First run

1. Click **+** in the toolbar to add a host. The app starts with no hosts.
2. Set these fields for each host:

   | Field | Use |
   | --- | --- |
   | Name | The name in the list. |
   | OS | Linux, macOS, Windows or Other. This sets the service tests (SSH, Screen Sharing or RDP), the default ports and the buttons. Use Other for a device that you reach over SSH and that is not a Linux host, for example a router. |
   | Wake-on-LAN | Linux, macOS and Other. Turn it off for a host that is always on or that does not support Wake-on-LAN. The app then hides the MAC address and the Wake buttons. It is on by default for Linux and macOS, and off for Other. Windows hosts always have Wake-on-LAN. |
   | MAC address | When Wake-on-LAN is on. The address of the network adapter on the target host. Any separator is permitted. |
   | Address | The IP address or hostname. The app needs it for the checks and to connect. |
   | Port | Linux, Windows and Other. Leave it empty for the default (3389 for RDP, 22 for SSH). |
   | SSH, SSH port | macOS. Turn SSH on or off. Leave the port empty for 22. |
   | Screen Sharing, Screen Sharing port | macOS. Turn Screen Sharing on or off. Leave the port empty for 5900. You cannot turn off both services. |
   | User | Linux, macOS and Other. The SSH user. Optional. |
   | SSH key | Linux, macOS and Other, when SSH is on. The path to a private key, for example `~/.ssh/id_ed25519`. Optional. The app shows a warning if the file does not exist. |

3. Click **Wake**. macOS asks for permission for the app to find devices on the local network. Click **Allow**. If you do not allow it, the app cannot send packets or test hosts. To change this later, go to System Settings > Privacy & Security > Local Network.

If a packet does not reach a host, open HostDeck > Settings (⌘,) and set the subnet broadcast address, for example `192.168.1.255`.

### Prepare a Windows host

Windows Firewall blocks ping by default, so the ping check never passes. On the Windows host, enable the inbound firewall rule **File and Printer Sharing (Echo Request - ICMPv4-In)**. As administrator, you can also run this command in PowerShell:

```powershell
Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In
```

Remote Desktop must also be on (Settings > System > Remote Desktop).

### Prepare a Mac host

On the Mac that you want to wake and connect to:

1. Turn on Wake for network access. On a desktop Mac, go to System Settings > Energy. On a laptop, go to System Settings > Battery > Options.
2. For SSH, turn on Remote Login in System Settings > General > Sharing.
3. For Screen Sharing, turn on Screen Sharing in System Settings > General > Sharing.
4. If the firewall is on, make sure that stealth mode is off (System Settings > Network > Firewall > Options). In stealth mode, the Mac does not reply to ping, so the ping check never passes.

Wake-on-LAN wakes a Mac from sleep only. It does not start a Mac that is shut down. Ethernet is more reliable than Wi-Fi for a wake packet.

A Mac can go back to sleep soon after a network wake, unless a session keeps it awake. Connect soon after the host is ready. With SSH on, Wake and Connect opens an SSH session as soon as the host is ready.

## Use

| Control | Shortcut | Action |
| --- | --- | --- |
| Wake | ⌘↩ | Send the wake packet, then wait for each check to pass. |
| Wake and Connect | ⇧⌘↩ | Linux, macOS and Other, when Wake-on-LAN is on. As Wake, then open an SSH session when the host is ready. For macOS, SSH must be on. |
| Test | ⌘T | Do each check one time. The app sends no wake packet. |
| Connect | | Linux, macOS and Other, when SSH is ready. Open an SSH session now. |
| Open Screen Sharing | | macOS, when Screen Sharing is ready. HostDeck starts the Screen Sharing app. |
| Open RDP App | | Windows only, when RDP is ready. Choose an RDP app, and HostDeck starts it. |
| Cancel | Esc | Stop the wait. |
| Clear the log (trash icon) | ⌘K | Clear the log of the selected host. Not available while a run is busy. |

The server rack icon in the menu bar gives the same commands for each host when the main window is closed.

For a Linux, macOS or Other host, Connect opens `ssh` in Terminal. HostDeck does not store passwords. If the key does not log you in, `ssh` asks for the password in Terminal.

For a macOS host, Open Screen Sharing starts the Screen Sharing app and does nothing more. Connect to the host from that app.

For a Windows host, the log shows "ready for RDP connections" when the host passes all the checks. Open RDP App shows a menu of the installed apps that open RDP connections, for example [Windows App](https://apps.apple.com/app/windows-app/id1295203466). HostDeck starts the app that you choose and does nothing more. Connect to the host from that app.

### Checks

The app does the checks in this sequence. If ping fails, the app stops. A macOS host can have two services. The app tests each service in turn, and a service that fails does not stop the test of the next service.

1. Ping. The app sends one ICMP echo a second until the host replies.
2. Service port. The app opens a TCP connection to the RDP, SSH or Screen Sharing port.
3. Service test:
   - Windows: the app sends an RDP connection request and waits for the X.224 Connection Confirm. This shows that an RDP service answers, not only that the port is open.
   - Screen Sharing (macOS): the app opens the port and waits for the server to send its banner. The test passes if the banner starts with `RFB `, for example `RFB 003.889`.
   - SSH (Linux, macOS and Other): if the host has an SSH key, the app logs in with `ssh` and that key only. The test passes when `ssh` reports that the login succeeded, so it also works on devices with no shell, for example RouterOS. Without a key, the app does not do this step.

After a wake packet, the app repeats checks 1 and 2 until they pass or the timeout ends. The default timeout is 180 seconds. You can change it in Settings.

### Status

The app checks each host every 15 seconds, and also when you select a host. The list shows a status symbol for each host. Next to the buttons, the app shows the status of the selected host in words, for example "Online: ready for RDP".

While a host is online (it replies to ping), you cannot click Wake or Wake and Connect, because the host is already awake. Each connect button (Connect, Open Screen Sharing, Open RDP App) is available only while the host replies to ping and the port of that service is open. The buttons are not available while a run is busy. If a service fails in a Wake or Test run, for example at the RDP handshake or the SSH login, its button stays unavailable until a later run passes. The buttons of the other services stay available. Test is always available, so you can check the host again. Hold the pointer over a faded button to see why it is not available.

| Symbol | Meaning |
| --- | --- |
| Filled circle with a tick (green) | The host replies to ping and all its service ports are open. |
| Filled circle with "!" (orange) | The host replies to ping, but one or more service ports do not answer. |
| Empty circle with "x" (red) | No reply to ping. |
| Dashed circle (grey) | No address is set, or the app has not tested the host yet. |

Each status has its own shape, so you can read it without the colour.

The bottom of the host list shows a key for these symbols, the number of hosts that are online, and the time of the last check. The ? button opens the HostDeck page on [edrandall.uk](https://www.edrandall.uk/lab-notes/hostdeck/).

## Back up and move hosts

To back up your hosts, choose File > Export Hosts… (⇧⌘E). HostDeck writes one JSON file with the hosts and the Settings values. The file has no passwords and no keys. It has the paths of the SSH keys, and the MAC and IP addresses.

To restore hosts, or to copy them to another Mac, choose File > Import Hosts…. Import merges the file with the current list:

- A host in the file with the same ID as a host in the list replaces that host.
- Other hosts in the file are added to the list.
- Import does not delete hosts.
- Settings values in the file replace the current Settings.

Import also accepts a bare JSON array of hosts, for example the `hosts` value from `defaults export uk.edrandall.hostdeck`. [docs/FILE-FORMAT.md](docs/FILE-FORMAT.md) defines the file format.

## Signing

macOS gives the Local Network permission to an app by its signature. An ad hoc signature contains a hash of the build, so each rebuild looks like a new app to macOS. The permission then stops working. The symptom is that every port shows as "not answering" while ping still works, or that a wake packet fails with "No route to host".

With the certificate from `Tools/make-signing-cert.sh`, the signature names the bundle ID and the certificate, and it stays the same across rebuilds. You allow Local Network access one time, and the permission stays.

`build.sh` uses the certificate if it is in the keychain, and signs ad hoc if it is not. To use a certificate with another name, set `HOSTDECK_SIGN_ID` for both scripts. To check the signature, run:

```sh
codesign -d -r- ~/Applications/HostDeck.app
```

The output must show `certificate leaf`, not `cdhash`. After the first build with the certificate, allow Local Network access once more in System Settings > Privacy & Security > Local Network.

To remove the certificate, delete "HostDeck Local Signing" from the login keychain in Keychain Access.

## Notes

- The SSH login test uses `StrictHostKeyChecking=accept-new`. On the first login, the test adds the host key to `~/.ssh/known_hosts`. If the host key changes, the test fails.
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
| `Tools/make-signing-cert.sh` | Makes the signing certificate. Run it one time on each Mac. |
| `build.sh` | Builds, signs and installs the app. It signs with the certificate if there is one, else ad hoc. |
| `docs/FILE-FORMAT.md` | The JSON format of the saved hosts and of the export file. |
| `CLAUDE.md` | Notes for Claude Code, with the plan for a Windows version. |
| `LICENSE` | The MIT License. |

## Licence

HostDeck is available under the [MIT License](LICENSE).
