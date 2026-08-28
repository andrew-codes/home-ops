# Gaming PC

See [README.md](README.md) for prerequisites, the target list, and the
transport-sensitive tasks to be careful with when editing `scripts/deploy.yml`.

`nx deploy gaming-pc` and `nx pre-deploy gaming-pc` both act on the real machine
the captain uses. Never run either, and never run `ansible-playbook` against it
without `--check`.

# Connection Configuration

The deploy reaches the machine over the OpenSSH server built into Windows, not
WinRM. Keep the playbook connection-agnostic: transport settings belong in the
inventory that `scripts/deploy.ts` generates, never in `scripts/deploy.yml`.

WinRM is still enabled on the machine: it is a backup target, and `apps/backups`
deploys to the Windows hosts it targets over WinRM on port 5986. Only this
app's prerequisite dropped WinRM. That WinRM path is also the recovery
route if an SSH change locks the deploy out - see "Why that risk was accepted,
and when it expires" in [README.md](README.md), including the condition under
which a live test against a throwaway Windows host becomes required.

Two values must stay in step, or every task fails to connect:

- `ansible_shell_type` in the generated inventory
- the `DefaultShell` registry value the playbook pins to `powershell.exe`

The playbook must not set `ansible_password`. Ansible authenticates with a key,
and setting that variable makes the SSH connection plugin demand `sshpass`. The
Windows account password is a plain play variable, `windows_password`, used for
`become`/`runas` and auto-login.

# Software and Windows settings

The software list is [src/software.ps1](src/software.ps1), not the playbook.
Add and remove packages there. Prefer winget; the three exceptions and why they
are exceptions are in [README.md](README.md).

`software.ps1` runs twice, `-Phase Machine` elevated and `-Phase User` not.
Elevation is per-process, so a package goes in the phase that matches where it
must install - machine-scope installers elevated, MSIX and per-user installers
not. Putting one in the wrong phase installs it into the wrong hive.

Every step must be idempotent, and `win_shell` is the usual way that breaks:
it reports `changed` on every run. Where a setting has no naturally idempotent
module, use `ansible.windows.win_powershell` and set `$Ansible.Changed` from a
real comparison, as `Disable sleep and hibernation` and `Auto-hide taskbar` do.

# Validating without the machine

Nothing here can be run against the real gaming PC (see above), so validate
statically. From the repo root:

```bash
# Playbook parses and every module name resolves.
ansible-playbook apps/gaming-pc/scripts/deploy.yml -i <inventory> --syntax-check

# Every PowerShell file parses. Needs pwsh; there is none on the Mac by
# default, and a standalone build unpacked into a temp directory is enough.
pwsh -NoProfile -Command '
  Get-ChildItem apps/gaming-pc/src -Filter *.ps1 | ForEach-Object {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e.Count) { $_.Name; $e | ForEach-Object { $_.Message } }
  }'
```

The PowerShell embedded in `deploy.yml` is not covered by either: it is only
parsed on the target host at run time, so extract the `script:` blocks and parse
them the same way before trusting a change to them.

# Configuring a Windows app with no CLI or plain config file

`src/nut-client.ps1` (WinNUT-Client) is the precedent: when a target app's only
settings store is a per-user .NET `ClientSettingsSection` at a path derived from a
hash of the install location, don't try to reproduce that path or hash. Instead load
the app's own compiled assembly by reflection (`[System.Reflection.Assembly]::LoadFrom`)
and call its own generated Settings class and `Save()` - the same mechanism its own
Preferences UI uses. Reuse this pattern before inventing a new one for the next
installed-but-unscriptable Windows app.

# Confluence Sync

When making changes to `scripts/deploy.yml`, update the Confluence page
[Gaming PC Setup](https://smithsimms.atlassian.net/wiki/spaces/HA/pages/113573889)
in the Home Ops space to reflect those changes. This includes:

- New or removed software packages
- Changes to Windows Update configuration
- Changes to SSH, firewall, or registry settings
- Changes to prerequisites or how the deploy is run
- Any new tasks or removed tasks

# Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
