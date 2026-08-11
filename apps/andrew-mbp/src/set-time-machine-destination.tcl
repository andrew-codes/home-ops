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

spawn /usr/bin/tmutil setdestination -a -p $url

# Match tmutil's exact prompt string, taken from the binary itself, rather than
# a loose /password/ pattern that could also match an unexpected sudo prompt
# and send the NAS password to the wrong reader.
expect {
    "Destination password:" {
        send -- "$password\r"
    }
    timeout {
        puts stderr "error: timed out waiting for tmutil's password prompt"
        exit 1
    }
    eof {
        # tmutil exited before prompting - surface its own error below.
    }
}

# Safe to show tmutil's output from here on: the password is never echoed back,
# and hiding this would hide the actual failure reason.
log_user 1
expect eof

catch wait result
exit [lindex $result 3]
