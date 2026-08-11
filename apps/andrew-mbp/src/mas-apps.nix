# Mac App Store apps for this machine, as { "App Name" = <numeric app id>; }.
#
# Same shape, and the same reason, as devtools' own mas-apps.nix: these are
# deliberately NOT wired into nix-darwin's `homebrew.masApps`. nix-darwin runs
# brew bundle under plain `sudo --user=<you>` with no `launchctl asuser`, so it
# lands outside the per-user launchd session. `mas` reaches the App Store
# through StoreAgent, which lives in that session, so `mas list` comes back
# empty there, brew bundle concludes the app is missing, and the `mas install`
# it then runs fails for want of a TTY to sudo against -- on every rebuild,
# however the app is really installed.
#
# setup.sh reads this file directly and runs `mas get` as the real user, in the
# real session, where mas works. `get` (not `install`) because mas only
# installs apps already in the signed-in Apple ID's library; `get` is what adds
# one, is permanent per Apple ID, and exits 0 with "Already got" on re-runs.
#
# Find an app's id with: mas search "App Name"
{
  # https://apps.apple.com/us/app/pdf-expert-edit-sign-pdfs/id1055273043
  # Readdle Technologies Limited, bundle id com.readdle.PDFExpert-Mac
  "PDF Expert" = 1055273043;

  # https://apps.apple.com/us/app/windows-app/id1295203466
  # Microsoft's RDP client, renamed from Microsoft Remote Desktop.
  # Microsoft Corporation, bundle id com.microsoft.rdc.macos
  "Windows App" = 1295203466;
}
