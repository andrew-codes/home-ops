# Applications this machine gets on top of the devtools baseline.
#
# `homebrew.casks` is a list option, so these merge with the casks devtools
# already declares rather than replacing them. devtools sets
# `homebrew.onActivation.cleanup = "none"`, so anything installed out of band
# is left alone here too.
#
# Every token below was verified against the live Homebrew cask index
# (https://formulae.brew.sh/api/cask/<token>.json) rather than guessed -- a
# wrong token is a silent no-op on a real machine.
#
# Deliberately NOT listed:
#   lens  - devtools already installs it in its own `homebrew.casks`.
#           Adding it here would declare the same cask twice.
#
# Mac App Store apps are not here either; see mas-apps.nix for why they
# cannot be installed from inside activation.
_:

{
  homebrew.casks = [
    "discord"
    "loom" # Atlassian Loom
    # Office is installed per-app on purpose. The `microsoft-office` cask is a
    # single bundle installer that also lays down OneNote, Outlook and Teams
    # with no supported way to exclude them; the individual casks are the only
    # way to get Word/Excel/PowerPoint alone.
    "microsoft-excel"
    "microsoft-powerpoint"
    "microsoft-word"
    "moonlight"
    "onedrive"
    "snagit"
    "steam"
    # `tailscale` is now the CLI-only formula; `tailscale-app` is the GUI app.
    "tailscale-app"
    # Dia browser, from The Browser Company. setup.sh makes it the default
    # http/https handler after activation -- that cannot happen here, because
    # LaunchServices defaults are per-user and activation does not run inside
    # the user's launchd session.
    "thebrowsercompany-dia"
    "zed"
    "zoom"
  ];
}
