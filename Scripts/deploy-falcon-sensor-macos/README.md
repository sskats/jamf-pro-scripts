# deploy-falcon-sensor-macos

English | [日本語](README.ja.md)

A Jamf Pro script that installs the CrowdStrike Falcon sensor on macOS and keeps it at a specified version.

It uses the CrowdStrike API to find the target sensor version, download the installer, verify its checksum, and install and license it. Depending on what is already on the Mac, it performs a fresh install, upgrade, downgrade or reinstall.

> [!WARNING]
> Always test this script on a small number of Macs before using it in production.

## Contents

- [What the script does](#what-the-script-does)
- [Requirements](#requirements)
- [Setup](#setup)
- [Specifying the target sensor](#specifying-the-target-sensor)
- [Testing locally](#testing-locally)
- [Exit codes](#exit-codes)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)

## What the script does

1. Gets an access token for the CrowdStrike API.
2. Resolves the target (default: `n-1`) to a sensor version such as `7.02.17003`.
3. Compares it with the sensor installed on the Mac and decides what to do:

   | Current state | Action | What happens |
   |---|---|---|
   | Not installed | `install` | Install, license with the CCID, load |
   | Older version installed | `upgrade` | Install over the current sensor. The license is kept. Waits until the new version is running |
   | Newer version installed | `downgrade` | Uninstall with the maintenance token, then install, license and load |
   | Same version, not running | `reinstall` | Same as downgrade |
   | Same version, running | `none` | Nothing. Exits with 0 |

4. Downloads the installer and verifies its SHA-256 checksum.
5. Performs the action above.
6. On exit, deletes the working directory and revokes the access token.

## Requirements

- macOS, and Jamf Pro (or root access for local runs)
- A CrowdStrike Falcon API client (see [Setup](#setup))
- The configuration profile that Falcon needs (system extension, full disk access, and so on), deployed separately. This script does not create it.

## Setup

### 1. Create an API client

In the Falcon console, create an API client under **Support and resources > API clients and keys**. Give it only the permissions you need:

| Permission | When it is needed |
|---|---|
| Sensor Download: **Read** | Always |
| Sensor update policies: **Read** | When the target is a policy ID or `n`, `n-1`, `n-2` (includes the default) |
| Sensor update policies: **Write** | When a downgrade or reinstall may happen. Used to get the maintenance token for uninstalling |

Upgrades are installed over the current sensor and do not need the maintenance token. If you only ever upgrade, you can leave out the Write permission.

Make a note of the **Client ID** and **Client Secret**.

### 2. Find your API base URL

Use the base URL for your CrowdStrike cloud:

| Cloud | Base URL |
|---|---|
| US-1 | `https://api.crowdstrike.com` (default) |
| US-2 | `https://api.us-2.crowdstrike.com` |
| EU-1 | `https://api.eu-1.crowdstrike.com` |
| US-GOV-1 | `https://api.laggar.gcw.crowdstrike.com` |

### 3. Add the script to Jamf Pro

Upload `deploy-falcon-sensor-macos.sh` under **Settings > Computer management > Scripts**, and set the parameter labels:

| Parameter | Suggested label | Required |
|---|---|---|
| 4 | CrowdStrike API Base URL | No (default: US-1) |
| 5 | Client ID | Yes |
| 6 | Client Secret | Yes |
| 7 | Target sensor (policy ID / n / n-1 / n-2 / build / version) | No (default: `n-1`) |

### 4. Create a policy

Create a policy, add the script, fill in the parameter values, and scope it to the target Macs.

## Specifying the target sensor

Set the target with parameter 7 (or `-v` for local runs). It can be one of:

| Format | Example | Meaning |
|---|---|---|
| Sensor update policy ID | `0123456789abcdef0123456789abcdef` (32 hex characters) | The version set in that policy |
| `n`, `n-1`, `n-2` | `n-1` | Latest build, one before latest, two before latest |
| Build number | `17003` | The version with that build number |
| Version number | `7.02`, `7.02.17003` | That version. If you leave out the build, the newest matching build is used |

If you use a policy ID, the policy must have a specific sensor version set.

> [!NOTE]
> The sensor update policy assigned to the host in the Falcon console can also change the sensor version. If it points to a different version from this script, the two will keep changing it. Keep them consistent, for example by giving this script that policy's ID.

## Testing locally

```sh
sudo ./deploy-falcon-sensor-macos.sh -i <client id> [-v <target>] [-u <base url>] [-n]
```

| Option | Description |
|---|---|
| `-u` | API base URL (default: `https://api.crowdstrike.com`) |
| `-i` | API client ID |
| `-s` | API client secret. If omitted, you are prompted for it |
| `-v` | Target sensor (default: `n-1`) |
| `-n` | Download and verify only, and show what would be done. Does not install |
| `-h` | Show help |

Leave out `-s` and type the secret at the prompt. Passing it with `-s` leaves it in your shell history and in the process list.

It is a good idea to run with `-n` first to check which version is chosen and what action would be taken. `-n` does not require root, but without `sudo` the installed version may not be readable.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (including "already up to date") |
| 1 | Invalid arguments |
| 2 | CrowdStrike API error (authentication, permissions, etc.) |
| 3 | Target sensor version not found |
| 4 | Download or checksum verification failed |
| 5 | Uninstall or install failed |
| 6 | License or load failed |

## Security notes

- **The client secret is stored in the Jamf Pro policy.** Anyone who can view the policy can see it. Restrict who can view and edit the policy.
- **Sensor update policies: Write is a powerful permission.** It can reveal the maintenance token, which allows the sensor to be uninstalled. Use an API client just for this script, and give it this permission only if you need downgrades or reinstalls.
- When the maintenance token is revealed, the Falcon audit log records `Jamf Pro: reinstall Falcon sensor on <computer name>`.
- The script passes the credentials to `curl` through stdin so they do not appear in the process list. The access token is revoked when the script exits.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Exit 2 when getting the access token | Base URL, client ID and client secret |
| Exit 2 at other points | The API client permissions (see [Setup](#setup)). The error message in the log shows which API failed |
| Exit 3 | Whether the target is correct. If you use a policy ID, check that the policy has a specific version set |
| Exit 6 | Whether the configuration profile (system extension, full disk access) has been deployed. Check the sensor status with `sudo /Applications/Falcon.app/Contents/Resources/falconctl stats` |
