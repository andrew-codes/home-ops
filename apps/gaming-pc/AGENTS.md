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
