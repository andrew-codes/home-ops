# The applications this machine gets, as Homebrew casks.
#
# Every token below was verified against the live Homebrew cask index
# (https://formulae.brew.sh/api/cask/<token>.json) rather than guessed -- a
# wrong token is a silent no-op on a real machine, not an error.
#
# All of these install into /Applications, /Library or via a system pkg
# receipt, so every one of them is available to *both* accounts on this
# machine. None of them is a per-user install. What is per-user is each app's
# own first-run state - login items, sign-in, and the permission prompts macOS
# raises the first time an app asks for accessibility, screen recording or a
# system extension. README.md lists those.
_:

{
  homebrew.casks = [
    "1password"
    # OpenAI's desktop app.
    "chatgpt"
    # Dia, from The Browser Company. Nothing here makes it the default
    # browser: no default-browser requirement was stated for this machine, and
    # setting one is a per-user LaunchServices change that cannot happen
    # during activation anyway.
    "thebrowsercompany-dia"
    # Logitech's mouse and keyboard software. Cask token is `logi-options+`;
    # `logitech-options` is the discontinued predecessor.
    "logi-options+"
    "loom" # Atlassian Loom
    # Office is installed per app on purpose. The `microsoft-office` cask is a
    # single bundle installer that also lays down OneNote and Teams with no
    # supported way to exclude them. The individual casks are the only way to
    # get exactly the four applications wanted here - note that Outlook IS
    # wanted on this machine, unlike the sibling apps/andrew-mbp - and to
    # leave OneNote off.
    "microsoft-excel"
    "microsoft-outlook"
    "microsoft-powerpoint"
    "microsoft-word"
    # Raycast. setup.sh binds it to cmd+space, which is why configuration.nix
    # turns Spotlight off.
    "raycast"
    # `tailscale` is now the CLI-only formula; `tailscale-app` is the GUI app.
    "tailscale-app"
    # Zed is wanted for the second account only. A cask installs into
    # /Applications, which is shared, so this puts it on the machine for both
    # accounts; see README.md for why there is no clean per-user alternative
    # given how everything else here is installed.
    "zed"
    "zoom"
  ];
}
