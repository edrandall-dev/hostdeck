# CLAUDE.md

Guidance for Claude Code in this repository.

## The project

HostDeck is a macOS app that checks, wakes and connects to the hosts on a local network. The whole app is one SwiftUI file, `Sources/HostDeck.swift`. `build.sh` compiles it with `swiftc`, with no Xcode project. The README is the user documentation. The page at https://www.edrandall.uk/lab-notes/hostdeck/ describes the app for readers of the site.

To build and install, run `./build.sh`. To build only, run `./build.sh --no-install`.

`build.sh` signs with the "HostDeck Local Signing" certificate from `Tools/make-signing-cert.sh` if it is in the keychain. Keep it that way. An ad hoc signature changes with each build, and macOS then drops the Local Network permission, so every port check fails. The README section "Signing" gives the details.

## The file format

`docs/FILE-FORMAT.md` defines the JSON of the saved hosts and of File > Export Hosts. It is a contract between platforms.

- Do not rename or remove a key. The key names are pinned with explicit `CodingKeys` on `Host` and `HostsFile`, and the `OSType` raw values are pinned too.
- When you add a field to `Host`, make it optional on decode (`decodeIfPresent` with a default), and add it to `docs/FILE-FORMAT.md`.
- For any other change to the format, increase `version` and keep the reader for the old version.

## A Windows version

A Windows version of HostDeck is planned. It will be a separate app, built on a Windows machine, and it must read and write the same file format.

These are the known points for that work:

- `sshKey` holds a path on the Mac. On import, show the key as missing if the file does not exist, and let the user set a new path.
- A `macos` host has Screen Sharing (VNC). The Windows version must decide what Open Screen Sharing does, for example start a VNC viewer. On the Mac, the app starts the viewer and does not connect, because the viewer handles the credentials.
- Open RDP App on the Mac starts an RDP app and does not connect, for the same reason. On Windows, `mstsc /v:host` can connect directly.
- The checks are ping, then a TCP connection to each service port, then a test for each service: X.224 Connection Confirm for RDP, an `RFB ` banner for Screen Sharing, and an SSH login with the key (`ssh -o BatchMode=yes`). The README gives the details.
- The wake packet is the standard magic packet (6 bytes of 0xFF, then the MAC address 16 times), sent 5 times to the broadcast address. The default UDP port is 9. Settings can change the address and the port.
- HostDeck stores no passwords. Keep it that way.

## Writing

Write the README and code comments in plain, short sentences, in British English. Do not use dashes as punctuation.
