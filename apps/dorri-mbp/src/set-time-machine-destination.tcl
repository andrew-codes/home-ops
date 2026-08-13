#!/usr/bin/env expect
#
# Sets the Time Machine network destination without ever putting the NAS
# password on a command line.
#
# `tmutil setdestination` accepts the password inside the URL, but its own man
# page warns against it: "all arguments provided to a program are visible by
# all users on the system via the ps tool". The documented alternative is the
# -p flag, which reads the password from a non-echoing prompt instead.
#
# That prompt is getpass(3) (confirmed: /usr/bin/tmutil imports _getpass), and
# getpass reads from /dev/tty rather than stdin, so a plain pipe cannot feed
# it. This script exists to give tmutil a pty to prompt on.
#
# Usage:  printf '%s\n' "$password" | expect -f this-script.tcl <destination-url>
#
# The password arrives on stdin and is read before tmutil is spawned. It is
# never a command-line argument here either, never written to disk, and never
# echoed - log_user stays off until after it has been sent.
#
# tmutil stores the password in the system keychain itself, which is what lets
# backupd remount the share unattended after a reboot or a network drop.
#
# Deliberately a copy of the sibling apps/andrew-mbp's script of the same name
# rather than a shared file. setup.sh's contract is that every file it reads
# sits next to it, which is what lets `./src/setup.sh` run straight out of a
# fresh clone with no build, packaging or path resolution step; reaching across
# app directories would break that for both machines. Change one and change the
# other - each app's tests assert this file's behaviour independently.

log_user 0
set timeout 120

if {[llength $argv] != 1} {
    puts stderr "usage: expect -f set-time-machine-destination.tcl <destination-url>"
    exit 2
}
set url [lindex $argv 0]

# Read the password from stdin before spawning anything.
if {[gets stdin password] < 0} {
    puts stderr "error: no password on stdin"
    exit 2
}

# No -a. Per `man tmutil`, without -a the current destination list is REPLACED
# by this URL rather than appended to, so the NAS becomes the one and only
# Time Machine destination. Appending would leave a superseded destination in
# the list for Time Machine to keep choosing from, which is the stale-backup
# failure the caller's idempotency check exists to prevent. The cost is that
# any other destination configured on this machine, a local backup disk
# included, is dropped; that is deliberate and documented in the README.
spawn /usr/bin/tmutil setdestination -p $url

# Match tmutil's exact prompt string, taken from the binary itself, rather than
# a loose /password/ pattern that could also match an unexpected sudo prompt
# and send the NAS password to the wrong reader.
set saw_eof 0
expect {
    "Destination password:" {
        send -- "$password\r"
    }
    timeout {
        # Whatever tmutil printed instead of the expected prompt is the only
        # evidence of why, and it is buffered rather than shown because
        # log_user is still off, so emit it alongside the error.
        puts stderr "error: timed out waiting for tmutil's password prompt"
        # A timeout leaves what arrived in the input buffer without setting
        # expect_out, so take it with a non-blocking catch-all match.
        catch {expect -timeout 0 -re "(?s).+"}
        if {[info exists expect_out(buffer)]} {
            puts -nonewline stderr $expect_out(buffer)
            flush stderr
        }
        exit 1
    }
    eof {
        # tmutil exited before prompting - most often because the calling
        # terminal lacks Full Disk Access. Its own message was buffered while
        # log_user was off and `expect eof` below will not reprint it, so it
        # has to be emitted here or the failure has no diagnostic at all.
        set saw_eof 1
        if {[info exists expect_out(buffer)]} {
            puts -nonewline stderr $expect_out(buffer)
            flush stderr
        }
    }
}

# Safe to show tmutil's output from here on: the password is never echoed back,
# and hiding this would hide the actual failure reason.
log_user 1
# Waiting for an EOF that has already arrived raises "spawn id not open", which
# would abort with expect's own exit status and lose tmutil's.
if {!$saw_eof} {
    expect eof
}

catch wait result
exit [lindex $result 3]
