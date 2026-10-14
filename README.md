# Local Windows group management
This repo contains a PowerShell-based Detect/Remediate script pair for Microsoft Intune's **Proactive Remediations** feature. It manages membership of Windows local groups (Administrators, Remote Desktop Users, Remote Management Users) by adding Microsoft Entra ID (Azure AD) security groups to them, based on group display names derived from the device name and a product bundle name read from the registry.

## How it works

Both scripts authenticate to Microsoft Graph using an app registration (client credentials flow) and look up the `securityIdentifier` (SID) of specific Entra ID groups by display name. They then check/add those SIDs as members of local Windows groups using the well-known group SIDs:

| Local group | SID | Purpose |
|---|---|---|
| Administrators | `S-1-5-32-544` | Local admin rights |
| Remote Desktop Users | `S-1-5-32-555` | RDP access |
| Remote Management Users | `S-1-5-32-580` | WinRM access |

The Entra ID groups expected are named using these patterns (where `<ComputerName>` is `$ENV:COMPUTERNAME` and `<ProductName>` is read from the registry value `HKLM:\SOFTWARE\COMPANY\DigitalWorkplace\ProductName`):

- `Admin-<ComputerName>` — device-specific admin group → added to **Administrators**
- `Admin-Windows-<ProductName>` — product bundle admin group → added to **Administrators**
- `Admin-Intune-RemoteAccess-<ProductName>` — remote support group → added to **Remote Desktop Users** and **Remote Management Users**

If the `ProductName` registry value isn't found, product-bundle-related groups (admin + remote access) are skipped and only the device-specific admin group is processed.

## detect.ps1

Read-only detection script, intended to run first in an Intune Proactive Remediation:

1. Reads `ProductName` from the registry (if present).
2. Looks up each expected Entra ID group's SID via Microsoft Graph.
3. Checks whether each SID is already a member of the corresponding local group.
4. Writes a summary line and exits:
   - `exit 0` — all expected groups are already configured correctly (compliant, no remediation needed).
   - `exit 1` — one or more groups are missing from their local group (triggers `remediate.ps1`).

An `$autoCreateGroups` flag (default `$false`) can be set to `$true` to auto-create missing Entra ID groups in a DEV tenant and switch the naming prefix to `DEV-Admin-...`. This also enables transcript logging to `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AdminGroupRemediation-Detect.log`.

## remediate.ps1

Runs only when `detect.ps1` exits with code `1`. For each expected group it:

1. Looks up the Entra ID group's SID via Microsoft Graph.
2. Adds the SID to the relevant local group with `Add-LocalGroupMember` if it isn't already a member.
3. Records the applied group's `DisplayName`, `ObjectID`, and `SID` under `HKLM:\SOFTWARE\COMPANY\WindowsGroupManagement\<GroupKey>` for auditing (e.g. `Administrators`, `PBAdministrators`, `Remote Desktop Users`, `Remote Management Users`).
4. Exits `0` on success (or if nothing needed changing), `1` if any `Add-LocalGroupMember` operation fails.

Like `detect.ps1`, it supports `$autoCreateGroups` for DEV-tenant naming/logging behavior.

## Configuration

Before deploying, set the following values at the top of **both** scripts:

- `$tenantId` — Entra ID tenant ID
- `$clientId` — App registration (client) ID
- `$clientSecret` — App registration client secret

The app registration requires the Microsoft Graph application permission `Group.Read.All` (or higher, e.g. `Group.ReadWrite.All` if `$autoCreateGroups` is used) with admin consent granted.

Additionally, each device must have the registry value `HKEY_LOCAL_MACHINE\SOFTWARE\COMPANY\DigitalWorkplace\ProductName` set. This value identifies the product bundle (e.g. `default-office-client`, `frontline-worker-client`) and is used to build/match the corresponding `Admin-Windows-<ProductName>` and `Admin-Intune-RemoteAccess-<ProductName>` Entra ID group names, allowing granular, per-bundle admin groups instead of a single tenant-wide admin group. If this value is missing, product-bundle group management is skipped (see [How it works](#how-it-works)).

> **Security note:** The client secret is stored in plain text in the script. When deploying via Intune, treat the script content as sensitive, restrict access to the Intune policy, and rotate the secret periodically. Consider using a certificate-based app registration or managed identity-backed approach instead of a client secret where possible.

## Deployment (Intune Proactive Remediation)

1. Create/upload an app registration with the Graph permission above.
2. Fill in `$tenantId`, `$clientId`, and `$clientSecret` in both scripts.
3. In Intune, create a new **Remediation** (Devices > Scripts and remediations) using `detect.ps1` as the detection script and `remediate.ps1` as the remediation script.
4. Run the remediation under the **System** context on a schedule, and assign it to the target device group(s).
