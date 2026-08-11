# Gaming PC

See [README.md](README.md) for prerequisites, how provisioning runs, and the
transport-sensitive tasks to be careful with when editing `scripts/provision.yml`.

# Connection Configuration

Ansible reaches the machine over the OpenSSH server built into Windows, not
WinRM. Keep the playbook connection-agnostic: transport settings belong in the
inventory that `scripts/provision.ts` generates, never in `scripts/provision.yml`.

Two values must stay in step, or every task fails to connect:

- `ansible_shell_type` in the generated inventory
- the `DefaultShell` registry value the playbook pins to `powershell.exe`

The playbook must not set `ansible_password`. Ansible authenticates with a key,
and setting that variable makes the SSH connection plugin demand `sshpass`. The
Windows account password is a plain play variable, `windows_password`, used for
`become`/`runas` and auto-login.

# Confluence Sync

When making changes to `scripts/provision.yml`, update the Confluence page
[Gaming PC Setup](https://smithsimms.atlassian.net/wiki/spaces/HA/pages/113573889)
in the Home Ops space to reflect those changes. This includes:

- New or removed software packages
- Changes to Windows Update configuration
- Changes to SSH, firewall, or registry settings
- Changes to prerequisites or how provisioning is run
- Any new tasks or removed tasks

# Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
