# CLAUDE.md

Guidance for Claude Code in this repository.

## The project

HostDeck is a macOS app that checks, wakes and connects to the hosts on a local network. The whole app is one SwiftUI file, `Sources/HostDeck.swift`. `build.sh` compiles it with `swiftc`, with no Xcode project. The README is the user documentation. The page at https://www.edrandall.uk/lab-notes/hostdeck/ describes the app for readers of the site. A Windows version is in `windows/`. See "The Windows version" below.

To build and install, run `./build.sh`. To build only, run `./build.sh --no-install`.

`build.sh` signs with the "HostDeck Local Signing" certificate from `Tools/make-signing-cert.sh` if it is in the keychain. Keep it that way. An ad hoc signature changes with each build, and macOS then drops the Local Network permission, so every port check fails. The README section "Signing" gives the details.

## The file format

`docs/FILE-FORMAT.md` defines the JSON of the saved hosts and of File > Export Hosts. It is a contract between platforms.

- Do not rename or remove a key. The key names are pinned with explicit `CodingKeys` on `Host` and `HostsFile`, and the `OSType` raw values are pinned too.
- When you add a field to `Host`, make it optional on decode (`decodeIfPresent` with a default), and add it to `docs/FILE-FORMAT.md`.
- For any other change to the format, increase `version` and keep the reader for the old version.

## The Windows version

`windows/HostDeck.ps1` is HostDeck for Windows. It is one PowerShell script with a WPF window, for Windows PowerShell 5.1, so that it needs no install of other software. Keep it compatible with PowerShell 5.1: no `??`, no ternary operator, no `&&`. `windows/README.md` is its user documentation. `windows/Install.ps1` installs it for the current user. `windows/Test-HostDeck.ps1` tests the file format, the model rules and the network code. Run the tests after a change:

    powershell -NoProfile -ExecutionPolicy Bypass -File windows\Test-HostDeck.ps1

The script has these parts:

- `$EngineBlock`: the model rules and the network code. The window runs it in background runspaces, so it must not use the window or script variables. Each run sends messages to a queue, and a timer on the window thread handles them.
- The file format functions (`Read-HDFile`, `New-HDFileText`, `Merge-HDHosts`).
- The window, after `if ($NoGui) { return }`. The tests and the install script load the script with `-NoGui`.

To check a change to the layout, take a screenshot with sample hosts in another data folder, then look at the PNG:

    powershell -NoProfile -ExecutionPolicy Bypass -STA -File windows\HostDeck.ps1 -DataDir <folder> -Screenshot shot.png -Select <name> -Action test

A function that returns an array must return it with a leading comma (`, $list`) if the caller needs an array, for example an empty one. Otherwise PowerShell unrolls it.

## Keep the two versions the same

A change to the behaviour of one version must go to the other version too, or the README of each version must say what is different. These points are the same in both versions:

- The checks are ping, then a TCP connection to each service port, then a test for each service: X.224 Connection Confirm for RDP, an `RFB ` banner for Screen Sharing, and an SSH login with the key (`ssh -o BatchMode=yes`). The README gives the details.
- The wake packet is the standard magic packet (6 bytes of 0xFF, then the MAC address 16 times), sent 5 times to the broadcast address. The default UDP port is 9. Settings can change the address and the port. On Windows, HostDeck also sends the packet from each network adapter that is up, because Windows sends a broadcast out of one adapter only.
- `sshKey` holds a path on the machine that wrote the file. On import, show the key as missing if the file does not exist, and let the user set a new path.
- HostDeck stores no passwords. Keep it that way.
- An imported file can come from anyone. Reject an `address` or `user` that starts with `-`, and pass `--` before the address to `ssh` and `ping`, so that a value cannot become an option such as `-oProxyCommand=`.

These points are different, because of the platform:

- On the Mac, Open RDP App and Open Screen Sharing start an app and do not connect, because the app handles the credentials. On Windows, Remote Desktop runs `mstsc /v:host`, which connects and asks for the credentials. Screen Sharing starts a VNC viewer with `host::port`.
- On Windows, Wake and Connect also works for a Windows host: it opens Remote Desktop.
- The Mac keeps its hosts in its preferences as a bare JSON array. Windows keeps them in `%APPDATA%\HostDeck\hostdeck.json`, in the export format.

## Writing

Write the README and code comments in plain, short sentences, in British English. Do not use dashes as punctuation.
