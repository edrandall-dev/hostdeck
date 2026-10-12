# HostDeck hosts file format

This document defines the JSON file that File > Export Hosts writes and File > Import Hosts reads. The macOS app keeps its saved hosts in the same `Host` format. Every version of HostDeck, on any platform, must read and write this format.

The current format version is 1.

## Encoding

- The file is UTF-8 JSON.
- Dates are ISO 8601 strings in UTC, for example `2026-10-05T14:30:55Z`. A writer leaves out fractional seconds. A reader accepts them, for example `2026-10-05T14:30:55.1234567Z`, because some platforms write them by default.
- IDs are UUID strings in upper case, for example `C10C8A0E-416A-4DFC-93AA-1DE87EC6C0D1`. Compare IDs without regard to case.
- A writer leaves out an optional key that has no value. It does not write `null`. A reader accepts both.
- A reader ignores keys that it does not know. This lets an older reader import a file from a newer writer.

## Top level

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `app` | string | yes | Always `"HostDeck"`. |
| `version` | integer | yes | The format version. This document defines version 1. |
| `exported` | date string | yes | The time of the export. |
| `hosts` | array of Host | yes | The hosts, in the order of the list in the app. |
| `settings` | Settings | no | The app settings. |

An importer also accepts a file that is only a JSON array of Host objects, with no top-level object. The macOS app stores its hosts in this form, so the `hosts` value from `defaults export uk.edrandall.hostdeck` imports directly.

## Host

| Key | Type | Required | Default when missing | Meaning |
| --- | --- | --- | --- | --- |
| `id` | UUID string | yes | | The identity of the host. Import uses it to merge. |
| `name` | string | yes | | The name in the list. |
| `mac` | string | yes | | The MAC address for Wake-on-LAN. Any separator. A valid value has 12 hex digits. Can be empty. |
| `os` | string | no | `"linux"` | One of `linux`, `macos`, `windows`, `other`. Read `network` as `other` (an early name). Read any other value as `linux`. |
| `address` | string | no | `""` | The IP address or hostname. |
| `port` | integer | no | 22, or 3389 for `windows` | The SSH port, or the RDP port for a Windows host. |
| `user` | string | no | `""` | The SSH user. |
| `sshKey` | string | no | `""` | The path to the private key on the machine that wrote the file. See [Paths](#paths). |
| `wakeEnabled` | boolean | no | `false` for `other`, else `true` | Wake-on-LAN on or off. A `windows` host always has Wake-on-LAN, whatever the value. |
| `sshEnabled` | boolean | no | `true` | `macos` only. SSH is a service of the host. |
| `vncEnabled` | boolean | no | `true` | `macos` only. Screen Sharing is a service of the host. |
| `vncPort` | integer | no | 5900 | `macos` only. The Screen Sharing (VNC) port. |

If `sshEnabled` and `vncEnabled` are both `false`, the host has SSH only.

The services of a host follow from `os`:

| `os` | Services | Service test |
| --- | --- | --- |
| `windows` | RDP | X.224 Connection Confirm |
| `linux`, `other` | SSH | SSH login with `sshKey`, if set |
| `macos` | SSH and Screen Sharing, as `sshEnabled` and `vncEnabled` set | SSH login, and a banner that starts with `RFB ` |

## Settings

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `broadcast` | string | `"255.255.255.255"` | The IPv4 address for the wake packet. |
| `port` | integer | 9 | The UDP port for the wake packet. |
| `timeout` | integer | 180 | The number of seconds to wait for a host after a wake packet. |

All the keys are optional. An importer changes only the settings that the file contains.

## Import

Import merges the file with the current list. It does not delete hosts.

Before it merges, an importer checks the file. If a check fails, it imports nothing and tells the user why.

- `app` is `"HostDeck"`.
- `version` is a version that the importer reads. A file from a newer version can mean something different, so the importer does not guess.
- No `address` or `user` starts with `-`. `ssh` and `ping` read such a value as an option, and an option such as `-oProxyCommand=` runs a command. An app must also pass `--` before the address when it runs these tools.

Then:

1. For each host in the file, find a host in the list with the same `id`.
2. If there is one, replace it with the host from the file.
3. If there is none, add the host from the file to the end of the list.
4. Apply each setting that the file contains.

## Paths

`sshKey` is a path on the machine that wrote the file, for example `~/.ssh/id_ed25519` on a Mac. The key file is not in the export. An importer on another platform must not trust the path. It shows the key as missing if the file does not exist, and the user sets a new path. An app can expand a leading `~` to the home folder of the user.

## Change the format

- Do not rename or remove a key in version 1. The macOS app pins the key names with explicit `CodingKeys` in `Sources/HostDeck.swift`.
- To add an optional key, give it a default and add it to this document. The version stays 1.
- For any other change, increase `version`. Keep the reader for the old version.

## Example

```json
{
  "app" : "HostDeck",
  "exported" : "2026-10-05T14:30:55Z",
  "hosts" : [
    {
      "address" : "192.168.1.20",
      "id" : "8D1C7C51-2B7E-4D51-9C51-0F2A1E3B4C5D",
      "mac" : "00:11:22:33:44:55",
      "name" : "studio",
      "os" : "macos",
      "sshEnabled" : true,
      "sshKey" : "~/.ssh/id_ed25519",
      "user" : "ed",
      "vncEnabled" : true,
      "wakeEnabled" : true
    }
  ],
  "settings" : {
    "broadcast" : "192.168.1.255",
    "port" : 9,
    "timeout" : 180
  },
  "version" : 1
}
```
