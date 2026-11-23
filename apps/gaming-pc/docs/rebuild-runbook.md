# Gaming PC rebuild runbook

Jira: HO-343. Part of [apps/gaming-pc](../README.md).

Follow this top to bottom to take the gaming PC from "three NVMe drives striped
in the BIOS" (or any broken Windows install) to a fully configured machine whose
two spare NVMe drives are one 4 TB games drive, `G:`. You need nothing else.

**What you end up with**

- Windows 11 on one 2 TB NVMe drive (`C:`).
- The other two 2 TB NVMe drives striped by Windows Storage Spaces into one
  4 TB `G:` drive. This is RAID 0: no redundancy, if one drive dies everything on
  `G:` is gone. That is intended: it holds re-downloadable games only.
- `G:\SteamLibrary` registered as a Steam library.
- Everything else the deploy sets up (software, metrics, SSH, UPS client).

**What it costs you:** an evening, mostly waiting for game downloads. Steps 2 and
3 erase drives. Do step 1 first.

Contents: [1 Back up](#1-back-up-before-wiping) |
[2 BIOS](#2-leave-bios-raid-for-plain-nvme-mode) |
[3 Install Windows](#3-install-windows-11-on-one-drive) |
[4 First boot](#4-first-boot-prerequisites-for-the-playbook) |
[5 Deploy](#5-run-the-deploy) |
[6 Verify](#6-verification-checklist) |
[7 Troubleshooting](#7-troubleshooting)

## 1. Back up before wiping

Turning BIOS RAID off erases the array, and installing Windows erases the drive
you choose. Everything on the old striped drive is lost.

### What the backup script covers

[`src/manually-backup.ps1`](../src/manually-backup.ps1) mirrors two places to the
network share mapped as `Z:` (the script hard-codes `Z:\`), using rsync:

| Source                                  | What is kept                                                                                                                                                                                                                                                  |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `C:\Program Files (x86)\Steam\userdata` | Steam's per-account local data (controller configs, screenshots index, some local game settings).                                                                                                                                                             |
| Your user profile (`$env:USERPROFILE`)  | Documents, Desktop, Downloads, Pictures, Videos (captures), `.ssh`, `developer`, and every other folder in the profile **except** `AppData`. From `AppData` only: `Roaming\SEGA`, `LocalLow\RedCandleGames`, `Local\MGSDelta*`, `Local\Steam\userdata`, `Local\Ubisoft`. |

It runs with `--delete`, so `Z:` becomes an exact mirror of the source. Running it
again after you have deleted something removes it from the backup too. Do not run
it after the wipe.

### What it does not cover - check these by hand

| Thing                                | What to do                                                                                                                                                                  |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Steam saves in the cloud             | Nothing to copy. Open Steam > Settings > Cloud and confirm Steam Cloud is on. For games without cloud saves, copy their save folders (often under `Documents` - covered - or `AppData\Roaming` / `AppData\Local` - **not** covered) yourself. |
| Game configs outside the list above  | Anything else in `AppData` (for example `AppData\Local\<game>`, `AppData\Roaming\<launcher>`) is not backed up. Copy the ones you care about to `Z:`.                       |
| Captures and clips                   | Covered if they are in `Videos` or `Pictures`. NVIDIA or Steam capture folders on another drive are not: look at their settings.                                           |
| Browser data                         | Not covered (it lives in `AppData`). Sign in to the browser's sync, or export bookmarks and passwords from the browser.                                                    |
| SSH keys                             | `.ssh` in the profile is covered. The Mac's key that the deploy authorises comes from 1Password (`dev/ssh-key/public`), not from this PC.                                  |
| 1Password                            | Nothing on this PC to back up if you use the account sign-in. Make sure you have your Secret Key / emergency kit for the new install.                                      |
| License keys and non-Steam launchers | Not covered. Note keys for any software bought outside Steam and winget (Epic, Ubisoft, GOG, DLC, emulator BIOS files).                                                    |
| `G:` / games                         | Deliberately not backed up. Steam re-downloads them.                                                                                                                       |

### Run the backup

On the gaming PC, in PowerShell (the script is on `PATH` after a deploy, in
`C:\Users\<user>\developer\tools`). `Z:` must be mapped and rsync installed (the
deploy installs it with Chocolatey).

```powershell
Test-Path Z:\            # must print True
pwsh -NoProfile -File "$env:USERPROFILE\developer\tools\manually-backup.ps1"
Get-Content "$env:USERPROFILE\developer\tools\backup.log" -Tail 20
```

The log must end with `All backups complete.` and no `ERROR:` line. Open `Z:` and
check a few folders you care about are really there.

Do the manual items in the table now, then continue.

## 2. Leave BIOS RAID for plain NVMe mode

Windows cannot see the three drives separately while AMD RAID is on: it shows
one logical drive, and the drive health collector (which reads each NVMe drive
with smartctl) sees nothing. **This step erases the array.**

The menu names differ by motherboard and BIOS version. Look for the words below.

1. Power off, then boot into the UEFI setup (usually repeatedly pressing `Del`).
2. Go to the RAID tool: **Advanced > AMD RAIDXpert2 Configuration Utility** (or
   "RAID Mode" / "Array Management"). Select the array and **Delete Array**. Confirm
   that you accept losing the data.
3. Turn RAID off: **Advanced > NVMe / Storage Configuration > NVMe RAID mode >
   Disabled** (on some boards the setting is "SATA/NVMe mode" or "RAID mode"
   switched from `RAID` to `AHCI`/`NVMe`).
4. Save and exit (`F10`).

**Verify before going on:** boot the Windows installer (step 3) and, at the "Where
do you want to install Windows?" screen, you must see **three separate 2 TB
drives**, not one 6 TB drive. If you see one 6 TB drive, RAID is still on: reboot
into the UEFI setup and repeat steps 2-3. Alternatively in the UEFI's storage
page, three NVMe drives with their model and serial numbers are listed.

## 3. Install Windows 11 on one drive

1. Boot the Windows 11 installer USB (boot menu key, often `F11` or `F8`). Make a
   fresh USB with Microsoft's Media Creation Tool on another PC if you do not
   have one.
2. At "Where do you want to install Windows?" you see three 2 TB drives
   (`Drive 0`, `Drive 1`, `Drive 2`), all "Unallocated Space". They are identical,
   so **choose `Drive 0`** and click Next. Windows creates its own partitions on that drive.
3. **Do not create, delete or format anything on the other two drives.** The
   deploy builds the array on them. Windows Setup showing partitions on the other
   two means old data is there: see [the wipe opt-in](#a-refusing-to-wipe-message).
4. Finish Setup. When it asks for a network or account, use a local account
   (see the next section).

Why `Drive 0`: any one will do, they are the same model. Pick the first so
the choice is unambiguous. The playbook never relies on which drive
you picked: it excludes the boot and system disk by itself.

## 4. First-boot prerequisites for the playbook

The deploy runs from the Mac over SSH. Windows needs a few things before it can.
All of these are documented, with the reasons, in [the README](../README.md#prerequisites);
this is the order to do them in.

1. **Create the local admin account.** README: [First-time setup](../README.md#first-time-setup-create-the-local-admin-account).
   Name it exactly the value of `gaming-pc/username` in 1Password, make it an
   Administrator, and sign in once so `C:\Users\<name>` exists. The folder name
   must match `gaming-pc/user` in 1Password. A mismatch stops the deploy before
   it changes anything.
2. **Network.** Plug in the wired network. Give the PC the IP in `gaming-pc/ip`
   in 1Password (a DHCP reservation on the router, or a static IP in Windows).
   If the IP changed, update that 1Password field.
3. **Enable SSH.** On the Mac, from the repo root:

   ```bash
   yarn nx pre-deploy gaming-pc
   ```

   It installs Ansible on the Mac, then prints a PowerShell block with the Mac's
   public key already filled in. Paste that block into an **Administrator
   PowerShell** on the gaming PC (the block is also in the README under
   [On the Windows machine](../README.md#on-the-windows-machine-once-from-an-administrator-powershell)).
   Re-run `pre-deploy`; it must exit 0.
4. **Turn off Defender Tamper Protection** (Windows Security > Virus & threat
   protection > Manage settings > Tamper Protection > Off). `pre-deploy` checks it.
   The Chocolatey install fails otherwise. See the README for why.
5. **The inputs the deploy reads.** `scripts/deploy.ts` reads these through
   `configurationApi` from the 1Password vault (key `<item>/<field>`), so the Mac
   must be signed in to 1Password:

   | 1Password entry                                          | Used for                                              |
   | -------------------------------------------------------- | ----------------------------------------------------- |
   | `gaming-pc/ip`, `gaming-pc/username`, `gaming-pc/user`   | The SSH inventory (`.secrets/hosts.yml`)              |
   | `gaming-pc/password`, `gaming-pc/andrew-password`        | Elevation (`runas`), auto-login, the `andrew` account |
   | `dev/ssh-key/public`, `home-assistant/ssh-key-public`    | `authorized_keys` on the PC                           |
   | `nut/monitor-username`, `nut/monitor-password`           | The UPS client (WinNUT)                               |
   | `k8s/ip`                                                 | Firewall rules that let the cluster scrape metrics    |

   `deploy.ts` writes the derived files into `apps/gaming-pc/.secrets/` (git-ignored)
   every run. The Mac's private key must be loaded in the SSH agent.

## 5. Run the deploy

From the repo root, on the Mac:

```bash
yarn nx deploy gaming-pc
```

It never needs the PC to be sitting at a prompt. Expect 20-40 minutes the first
time. What it does, in order (the full list is in [the README](../README.md)):

1. Windows settings: time zone, update schedule, sleep off, auto-login, UI tweaks,
   UAC, unwanted apps removed.
2. Chocolatey, PowerShell 7, rsync, small tools; SSH server config and keys; the
   `andrew` account; Remote Desktop.
3. Copies `apps/gaming-pc/src` to `C:\Users\<user>\developer\tools`.
4. **Build the games drive** (`storage.ps1`). On the rebuilt machine it finds
   exactly two empty NVMe drives, creates the pool `GamesPool`, a Simple (striped,
   no redundancy) virtual disk `Games` with 2 columns, and formats it NTFS as `G:`.
5. Installs software with winget (Steam, Apollo, Tailscale, Zed, smartmontools,
   and the rest), the NVIDIA app, Logi Options+ and MoonDeck Buddy.
6. **Register the Steam library** (`steam-library.ps1`): creates `G:\SteamLibrary` and
   adds it to Steam's `libraryfolders.vdf`, keeping a backup of that file.
7. Installs the metrics exporters and the drive health collector.
8. Configures WinNUT-Client (UPS monitoring). **This last task is expected to
   fail** until the NAS's NUT server and allow-list are set up (see
   [NUT UPS monitoring](../README.md#nut-ups-monitoring)). A failure there with
   everything above green is the known state, not a problem with the rebuild.

Read the end of the output: the `Show the games drive output` and `Show the Steam
library output` tasks print only when there is a warning, and they say what to
do about it.

### Re-running safely

The deploy is idempotent. Re-run it any time (`yarn nx deploy gaming-pc`):

- When the pool, the virtual disk and `G:` already exist, `storage.ps1` changes
  nothing.
- After a Windows reinstall that leaves the two drives untouched, Windows
  re-detects the pool on its own. The deploy then **reattaches** the existing
  virtual disk, brings it online and gives it the letter `G:`. It never recreates
  the pool, so the games on it survive a Windows reinstall.
- The Steam step does nothing once the library is registered. If Steam is
  running when a change is needed, it warns and waits; exit Steam from the tray
  icon and re-run.
- A dry run of the storage step, from the PC in an Administrator PowerShell,
  lists the disks it would use without changing anything:

  ```powershell
  pwsh -NoProfile -File C:\Users\<user>\developer\tools\storage.ps1 -WhatIf
  ```

Two switches, set on the Mac for one run only (neither is stored anywhere):

```bash
GAMING_PC_STORAGE_REQUIRED=true yarn nx deploy gaming-pc   # fail the deploy if G: is not there
GAMING_PC_STORAGE_WIPE=true     yarn nx deploy gaming-pc   # allow wiping old partitions on the two spare drives
```

### Steam: one step you do once, by hand

The deploy cannot make `G:` Steam's **default** install location: Steam picks the
library in each game's install dialog. After the deploy, open Steam once and
either choose `G:\SteamLibrary` in the install dialog for each game, or make it
the default: **Steam > Settings > Storage**, open the drive dropdown, pick
`G:\SteamLibrary`, then the "..." menu > **Make Default**. Doing this once is
remembered.

## 6. Verification checklist

On the gaming PC, in PowerShell unless noted:

- [ ] **Two NVMe drives pooled, one 4 TB drive `G:`.**

  ```powershell
  Get-StoragePool -IsPrimordial $false | Format-Table FriendlyName, HealthStatus, Size
  Get-VirtualDisk Games | Format-List FriendlyName, ResiliencySettingName, NumberOfColumns, Interleave, Size, HealthStatus
  Get-PhysicalDisk | Format-Table DeviceId, FriendlyName, BusType, Usage, Size
  Get-Volume -DriveLetter G | Format-Table DriveLetter, FileSystem, Size, SizeRemaining
  ```

  Expect `ResiliencySettingName` Simple, `NumberOfColumns` 2, a `G:` volume of
  about 3.6 TiB (shown as 3.64 TB or about 4 TB in decimal units), and two NVMe
  disks with `Usage` AutoSelect in the pool.
- [ ] **Steam library registered.** Open Steam > Settings > Storage: `G:\SteamLibrary`
  is listed. Make it the default (see above). Install any small game to `G:` and
  confirm it appears in `G:\SteamLibrary\steamapps`.
- [ ] **Drive health per member drive.** The collector reads physical NVMe drives,
  which stay NVMe under Storage Spaces, so each of the three drives is read
  separately:

  ```powershell
  & "$env:ProgramFiles\smartmontools\bin\smartctl.exe" --scan --json
  pwsh -NoProfile -File C:\ProgramData\gaming-pc\monitoring\drive-health.ps1 -Print
  ```

  Then in Grafana, **Hardware health**, machine `gaming-pc`: three NVMe drives
  (boot plus the two pool members), each with wear, spare, temperature and data written.
- [ ] **Metrics scrape.** From the Mac or Grafana, `up{job="gaming-pc"}` is 1 while the
  PC is on (see [Metrics and sensors](../README.md#metrics-and-sensors) and its
  checks on the first deploy).
- [ ] **UPS client.** WinNUT-Client is running in the tray and shows the UPS, if the
  NAS side is set up. If not, the WinNUT task failure is the known state.
- [ ] **Re-run is clean.** `yarn nx deploy gaming-pc` a second time reports `changed=0`
  for the games drive and Steam library tasks.

## 7. Troubleshooting

### The deploy prints a warning about the games drive

The storage step never fails the deploy by itself. The warning text gives the
reason and the remedy; the common ones:

- **"expected exactly 2 spare NVMe drives ... found 0"** and the PC is still on BIOS RAID
  (or the drives are not visible): go back to [step 2](#2-leave-bios-raid-for-plain-nvme-mode).
  Confirm `Get-PhysicalDisk` lists three NVMe drives.
- **"found 1" or "found 3"**: there must be exactly two spare NVMe drives besides
  the Windows drive. Remove an extra drive or install Windows on the right one.
  The script never guesses which two to use.
- **"drive letter G: is already used"**: something else holds `G:` (a USB stick,
  a DVD drive). Free it in Disk Management, or pick another letter by setting
  `gaming_pc_storage_drive_letter` in the `vars:` block at the top of `scripts/deploy.yml`.

### The pool is not recreated after a Windows reinstall

Windows re-detects an existing pool from metadata on the drives. Check:

```powershell
Get-StoragePool -IsPrimordial $false
Get-VirtualDisk
Get-PhysicalDisk | Format-Table DeviceId, FriendlyName, BusType, Usage, CannotPoolReason
```

- Pool `GamesPool` is listed: re-run the deploy; it reattaches the virtual disk,
  brings it online and assigns `G:`. Nothing is recreated and the games are kept.
  If it warns "no virtual disk named", the disk has a different name: set
  `gaming_pc_storage_virtual_disk_name` in the `vars:` block of `scripts/deploy.yml` to what `Get-VirtualDisk` shows.
- The pool has a different name (warning "already in a storage pool"): set
  `gaming_pc_storage_pool_name` (same place) to it. Do **not** delete it unless you mean to
  lose the games.
- No pool and the drives show as RAW or with partitions: the pool metadata is
  gone. Treat it as a fresh build (the games are gone; Steam re-downloads them).
  If the drives have partitions, see the next item.

### A "REFUSING to wipe" message

The drives hold old partitions, so the deploy will not erase them on its own. The
warning names each disk (number, model and serial). If you are sure that data is
disposable - the typical case is the old BIOS RAID data - re-run once with:

```bash
GAMING_PC_STORAGE_WIPE=true yarn nx deploy gaming-pc
```

It wipes only the two disks that the warning would name (never the boot disk, USB
or a drive in a pool), builds the array, and the setting is not remembered. If
the named disks include anything you recognise as valuable, stop and back it up.

### The Steam library does not appear

- Steam must be closed when the deploy edits `libraryfolders.vdf`. If the output
  says "Steam is running", exit Steam from the tray icon and re-run.
- Check the file: `C:\Program Files (x86)\Steam\config\libraryfolders.vdf` should list
  `G:\\SteamLibrary`. A `libraryfolders.vdf.gaming-pc-<time>.bak` next to it is the
  previous version; copy it back over the file (Steam closed) to undo.
- If the output says the file "could not be read", it was left untouched. Add
  the folder by hand: Steam > Settings > Storage > the drive dropdown > **Add Drive**
  > `G:\SteamLibrary`.
- If `G:` is not present, the Steam step skips with a warning. Fix the drive first.
- If Steam shows the library but marks it unusable, create the library from Steam
  itself once (Settings > Storage > Add Drive); Steam then writes its own files.
