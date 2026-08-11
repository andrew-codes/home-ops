#!/usr/bin/env expect
#
# Creates a local administrator account without ever putting its password on a
# command line.
#
# `sysadminctl -addUser` takes `-password <plaintext>`, and its own usage text
# says of the sibling flag: "'-adminPassword' used mostly for scripted
# operation. Use '-' or 'interactive' to get the authentication string
# interactively. This preferred for security reasons." The reason is that all
# arguments to a program are visible to every user on the system via `ps`.
#
# `-password -` asks for the password at a prompt instead. That prompt is
# getpass(3) - confirmed: /usr/sbin/sysadminctl imports _getpass - and getpass
# reads from /dev/tty rather than stdin, so a plain pipe cannot feed it. This
# script exists to give sysadminctl a pty to prompt on. It is the same
# mechanism, for the same reason, as the sibling apps/andrew-mbp uses to hand
# tmutil the NAS password.
#
# Usage:
#   printf '%s\n' "$password" \
#     | expect -f create-admin-user.tcl <username> <full name>
#
# The password arrives on stdin and is read before sysadminctl is spawned. It
# is never a command-line argument here either, never written to disk, and
# never echoed - log_user stays off until after it has been sent.
#
# Must be run as root (`sysadminctl should be run as root, or in interactive
# mode!`); the caller does that with sudo.

log_user 0
set timeout 120

if {[llength $argv] != 2} {
    puts stderr "usage: expect -f create-admin-user.tcl <username> <full name>"
    exit 2
}
set username [lindex $argv 0]
set fullname [lindex $argv 1]

# Read the password from stdin before spawning anything.
if {[gets stdin password] < 0} {
    puts stderr "error: no password on stdin"
    exit 2
}
if {[string length $password] == 0} {
    # sysadminctl refuses an empty password on a FileVault machine and
    # silently creates a passwordless account on one without it. Neither is
    # wanted, and the caller cannot tell the two apart afterwards.
    puts stderr "error: empty password on stdin"
    exit 2
}

# -admin is what puts the account in the macOS `admin` group, which is what
# grants sudo. It is emphatically not the root account: root stays disabled.
#
# The caller only ever reaches this script when the account does not exist, so
# there is no branch here that could reset an existing account's password.
spawn /usr/sbin/sysadminctl -addUser $username -fullName $fullname -password - -admin

# Match sysadminctl's own prompt strings, taken from the binary itself, rather
# than a loose /password/ pattern that could also match some other reader and
# send the account password to the wrong place.
expect {
    "User password:" {
        send -- "$password\r"
    }
    "New password:" {
        send -- "$password\r"
    }
    timeout {
        puts stderr "error: timed out waiting for sysadminctl's password prompt"
        exit 1
    }
    eof {
        # sysadminctl exited before prompting - surface its own error below.
    }
}

# Safe to show sysadminctl's output from here on: the password is never echoed
# back, and hiding this would hide the actual failure reason.
log_user 1
expect eof

catch wait result
exit [lindex $result 3]
