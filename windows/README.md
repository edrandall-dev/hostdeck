# HostDeck for Windows

HostDeck for Windows checks, wakes and connects to the hosts on your network. It is the Windows version of the macOS app in this repository. It sends Wake-on-LAN packets to hosts that are off, then checks each host until it is ready for RDP, SSH or Screen Sharing. It can open SSH sessions, Remote Desktop Connection and a VNC viewer.

The two versions use the same file format, so you can export your hosts on a Mac and import them on a PC, or the other way round. [docs/FILE-FORMAT.md](../docs/FILE-FORMAT.md) defines the format.

HostDeck for Windows is one PowerShell script with a WPF window. It runs on Windows PowerShell 5.1, which every Windows 10 and 11 PC has. You do not need to install other software.

## Requirements

- Windows 10 or 11.
- The OpenSSH Client, for the SSH test and Connect. Windows 10 (1809 and later) and Windows 11 have it. If `ssh` is not found, add it in Settings > System > Optional features.
- For Screen Sharing to a Mac: a VNC viewer, for example [TigerVNC](https://tigervnc.org/), [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/), TightVNC or UltraVNC.
- Each target host must support Wake-on-LAN, with the feature enabled in the firmware and in the network adapter settings.

## Install

1. Clone the repository:

   ```powershell
   git clone https://github.com/edrandall-dev/hostdeck.git
   cd hostdeck
   ```

2. Run the install script:

   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\Install.ps1
   ```

   The script copies `HostDeck.ps1` to `%LOCALAPPDATA%\Programs\HostDeck` and adds HostDeck to the Start menu. It needs no administrator rights. To also start HostDeck when you sign in, add `-StartAtLogin`.

3. Open HostDeck from the Start menu.

To update the app, pull the latest changes and run `Install.ps1` again. Exit HostDeck first. Your hosts and settings stay.

To run HostDeck without the install, run `powershell -ExecutionPolicy Bypass -STA -File windows\HostDeck.ps1`. The console window stays open while HostDeck runs.

## First run

1. Click **+** above the host list to add a host (Ctrl+N). The app starts with no hosts. To copy your hosts from a Mac, export them there with File > Export Hosts, then choose File > Import Hosts on the PC.
2. Set these fields for each host:

   | Field | Use |
   | --- | --- |
   | Name | The name in the list. |
   | OS | Linux, macOS, Windows or Other. This sets the service tests (SSH, Screen Sharing or RDP), the default ports and the buttons. Use Other for a device that you reach over SSH and that is not a Linux host, for example a router. |
   | Wake-on-LAN | Linux, macOS and Other. Turn it off for a host that is always on or that does not support Wake-on-LAN. The app then hides the MAC address and the Wake buttons. Windows hosts always have Wake-on-LAN. |
   | MAC address | When Wake-on-LAN is on. The address of the network adapter on the target host. Any separator is permitted. |
   | Address | The IP address or hostname. The app needs it for the checks and to connect. It cannot start with `-`. |
   | Port | Linux, Windows and Other. Leave it empty for the default (3389 for RDP, 22 for SSH). |
   | SSH, SSH port | macOS. Turn SSH on or off. Leave the port empty for 22. |
   | Screen Sharing, Screen Sharing port | macOS. Turn Screen Sharing on or off. Leave the port empty for 5900. You cannot turn off both services. |
   | User | Linux, macOS and Other. The SSH user. Optional. It cannot start with `-`. |
   | SSH key | Linux, macOS and Other, when SSH is on. The path to a private key, for example `~\.ssh\id_ed25519`. Optional. A leading `~` means your user folder. The app shows a warning if the file does not exist. |

   HostDeck saves each change at once.

3. Click **Wake**, or **Test** for a host that is on.

If a packet does not reach a host, open File > Settings (Ctrl+,) and set the subnet broadcast address, for example `192.168.1.255`.

## Use

| Control | Shortcut | Action |
| --- | --- | --- |
| Wake | Ctrl+Enter | Send the wake packet, then wait for each check to pass. |
| Wake and Connect | Ctrl+Shift+Enter | As Wake, then connect when the host is ready: SSH for Linux, macOS and Other, Remote Desktop for Windows. For macOS, SSH must be on. |
| Test | Ctrl+T | Do each check one time. The app sends no wake packet. |
| Connect | | Linux, macOS and Other, when SSH is ready. Open an SSH session now. |
| Remote Desktop | | Windows, when RDP is ready. Open Remote Desktop Connection to the host. |
| Screen Sharing | | macOS, when Screen Sharing is ready. Start your VNC viewer with the host. |
| Cancel | Esc | Stop the run. |
| Clear the log (bin icon) | Ctrl+K | Clear the log of the selected host. Not available while a run is busy. |
| Add Host | Ctrl+N | Add a host. |
| Delete Host | Del | Delete the selected host, when the list has the focus. HostDeck asks first. |
| Move Up, Move Down | Alt+Up, Alt+Down | Change the order of the list. |
| Export Hosts | Ctrl+Shift+E | Write the hosts and settings to a JSON file. |
| Settings | Ctrl+, | The broadcast address, the UDP port and the wait timeout. |

Right-click a host in the list for Wake, Test, Move and Delete.

### The notification area

HostDeck has an icon in the notification area, as the Mac app has an icon in the menu bar. Right-click it for the same commands for each host, and to exit HostDeck. Click it to open the window.

When you close the window, HostDeck keeps running in the notification area, and it keeps checking the hosts. To stop HostDeck, choose File > Exit HostDeck, or right-click the icon and choose Exit HostDeck. If you start HostDeck when it is already running, the window of the running HostDeck opens.

### Connect

- **SSH** opens `ssh` in a new terminal window. If the key does not log you in, `ssh` asks for the password there. If `ssh` stops with an error, the window stays open so that you can read the error.
- **Remote Desktop** opens Remote Desktop Connection (`mstsc`) to the host. It asks for the user and password, and it can save them in Windows. HostDeck does not store them.
- **Screen Sharing** starts the first VNC viewer that HostDeck finds: TigerVNC, RealVNC Viewer, TightVNC or UltraVNC, with the host and port. The viewer asks for the credentials. To connect to a Mac with a viewer other than RealVNC, turn on "VNC viewers may control screen with password" in the Screen Sharing settings of the Mac.

HostDeck does not store passwords.

### Checks

The app does the checks in this sequence. If ping fails, the app stops. A macOS host can have two services. The app tests each service in turn, and a service that fails does not stop the test of the next service.

1. Ping. The app sends one ICMP echo a second until the host replies.
2. Service port. The app opens a TCP connection to the RDP, SSH or Screen Sharing port.
3. Service test:
   - Windows: the app sends an RDP connection request and waits for the X.224 Connection Confirm. This shows that an RDP service answers, not only that the port is open.
   - Screen Sharing (macOS): the app waits for the server to send its banner. The test passes if the banner starts with `RFB `.
   - SSH (Linux, macOS and Other): if the host has an SSH key, the app logs in with `ssh` and that key only. The test passes when `ssh` reports that the login succeeded. Without a key, the app does not do this step.

After a wake packet, the app repeats checks 1 and 2 until they pass or the timeout ends. The default timeout is 180 seconds.

The app checks each host every 15 seconds, and also when you select a host or change its address or ports. The status symbols are the same as on the Mac:

| Symbol | Meaning |
| --- | --- |
| Filled circle with a tick (green) | The host replies to ping and all its service ports are open. |
| Filled circle with "!" (orange) | The host replies to ping, but one or more service ports do not answer. |
| Empty circle with "x" (red) | No reply to ping. |
| Dashed circle (grey) | No address is set, or the app has not tested the host yet. |
| Turning arc (blue) | A Wake or Test run is busy. |

While a host replies to ping, Wake and Wake and Connect are not available, because the host is already awake. Each connect button is available only while the host replies to ping and the port of that service is open. If a service fails in a Wake or Test run, its button stays unavailable until a later run passes. Hold the pointer over a faded button to see why it is not available.

### The wake packet on Windows

Windows sends a broadcast to 255.255.255.255 out of one network adapter only. On a PC with more than one adapter, for example a VPN or a VirtualBox or Hyper-V adapter, that can be the wrong one. So HostDeck sends the packet from each adapter that is up, to the address in Settings and to the subnet broadcast address of that adapter. The log lists the addresses.

### Prepare a Windows host

Windows Firewall blocks ping by default, so the ping check never passes. On the Windows host, enable the inbound firewall rule **File and Printer Sharing (Echo Request - ICMPv4-In)**. As administrator, you can also run this command in PowerShell:

```powershell
Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In
```

Remote Desktop must also be on (Settings > System > Remote Desktop).

For a Mac host, see "Prepare a Mac host" in the [main README](../README.md#prepare-a-mac-host).

## Start from a shortcut or the command line

`HostDeck.ps1` takes these parameters:

| Parameter | Use |
| --- | --- |
| `-Select <name>` | Start with this host selected. |
| `-Action wake`, `wakeconnect` or `test` | With `-Select`, do Wake, Wake and Connect or Test for that host when HostDeck starts. |
| `-DataDir <folder>` | Keep the hosts in another folder. |

For example, a desktop shortcut can wake one host. Copy the Start menu shortcut, and add `-Select nas -Action wake` to the end of its target. If HostDeck is already running, the shortcut opens its window and does not do the action.

## Back up and move hosts

HostDeck keeps its hosts and settings in `%APPDATA%\HostDeck\hostdeck.json`, in the export format. Help > Open the Data Folder opens the folder.

To back up your hosts, choose File > Export Hosts. To restore hosts, or to copy them from a Mac, choose File > Import Hosts. Import merges the file with the current list, as on the Mac:

- A host in the file with the same ID as a host in the list replaces that host.
- Other hosts in the file are added to the list.
- Import does not delete hosts.
- Settings values in the file replace the current Settings.

Import imports nothing if the file comes from a newer version of HostDeck with a different format, or if an address or user starts with `-`. A file from a Mac has Mac paths for the SSH keys. After the import, HostDeck tells you which keys are not on this PC. Set a new path for them.

## Notes

- The SSH login test uses `StrictHostKeyChecking=accept-new`. On the first login, the test adds the host key to `%USERPROFILE%\.ssh\known_hosts`. If the host key changes, the test fails.
- Windows OpenSSH refuses a private key that other users can read. If the log shows "bad permissions", give only your user access to the key file.
- If your organisation sets the PowerShell execution policy with Group Policy, `-ExecutionPolicy Bypass` has no effect, and HostDeck cannot start. Ask your administrator.
- If HostDeck has a problem that it cannot show, it writes it to `%APPDATA%\HostDeck\errors.log`.
- The window has a light theme only.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File windows\Install.ps1 -Uninstall
```

This removes the app and its shortcuts. To also remove your hosts, delete `%APPDATA%\HostDeck`.

## Files

| File | Purpose |
| --- | --- |
| `HostDeck.ps1` | The app. |
| `Install.ps1` | Installs, updates and removes the app for the current user. |
| `Test-HostDeck.ps1` | Tests for the file format, the model rules and the network code. Run it after a change: `powershell -ExecutionPolicy Bypass -File windows\Test-HostDeck.ps1`. |
