# The nix-darwin system base for this machine.
#
# Deliberately small. This is somebody's laptop, not a development machine:
# there is no shell configuration, no dotfiles and no home-manager here. The
# applications live in applications.nix; everything that has to happen per-user
# or needs a credential lives in setup.sh, which explains why in each case.
{ primaryUser, ... }:

{
  # Determinate Nix owns the daemon, its launchd job and /etc/nix/nix.conf.
  # setup.sh installs it, so nix-darwin must not also try to manage it - two
  # managers for one daemon is a broken switch on the first rebuild.
  nix.enable = false;

  # Every application on this machine is a Homebrew cask with a proprietary
  # licence (Office, Zoom, 1Password, ...), and nixpkgs' cask metadata is
  # still evaluated by nix-darwin.
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin";

  # nix-darwin no longer infers the user that `darwin-rebuild` was run as;
  # anything user-scoped, `homebrew` included, is applied to this account.
  # See flake.nix for why the name is read out of primary-user.txt.
  system.primaryUser = primaryUser;

  # nix-darwin's own module-compatibility version, not a macOS version. 6 is
  # what the sibling machine is on; changing it changes option defaults.
  system.stateVersion = 6;

  # Accounts are NOT managed here.
  #
  # nix-darwin can create users (`users.knownUsers`), but it cannot set a
  # password, cannot put an account in the `admin` group, and removing a name
  # from `knownUsers` later *deletes* that account. The second admin account
  # this machine needs has a password that arrives in an environment variable
  # at deploy time, which a pure flake cannot see anyway. setup.sh owns
  # account creation end to end instead, so exactly one thing does.

  # Spotlight indexing off, machine-wide.
  #
  # Two separate switches turn Spotlight off and both are wanted here; this is
  # the indexing half. The hotkey half is per-user and lives in setup.sh.
  #
  # `-i off` stops indexing and `-d` disables Spotlight activity for the
  # volume; `/` is the boot volume, which is where the index that matters
  # lives. Same invocation devtools uses on the sibling machine, so both Macs
  # turn Spotlight off the same way. Re-running is a no-op.
  #
  # This also disables the Finder search bar, Spotlight's own search results
  # and the file-content search Mail and other apps hand off to Spotlight -
  # see README.md, including how to turn it back on.
  #
  # mdutil needs Full Disk Access for the calling process. Activation runs as
  # root out of launchd, which has it, so this half of Spotlight is genuinely
  # automated; the setup.sh half is the part that can need an approval.
  system.activationScripts.postActivation.text = ''
    echo "disabling Spotlight indexing on /"
    mdutil -i off -d / >/dev/null
  '';

  # Homebrew itself, installed and pinned by nix-darwin rather than by the
  # `curl | bash` installer, so a fresh machine needs nothing preinstalled and
  # the brew version is part of this flake's lock file. `autoMigrate` adopts
  # an existing /opt/homebrew instead of failing on it.
  nix-homebrew = {
    enable = true;
    user = primaryUser;
    autoMigrate = true;
  };

  homebrew = {
    enable = true;
    # Leave anything installed out of band alone. Without this, a rebuild
    # uninstalls every Homebrew package not listed in applications.nix -
    # including whatever the machine's owner installed for themselves.
    onActivation.cleanup = "none";
    onActivation.autoUpdate = true;
    # Casks that ship an app already present in /Applications (Office is
    # routinely preinstalled on a new Mac) otherwise abort the switch.
    onActivation.extraFlags = [ "--force" ];
    # No `masApps`. Nothing on this machine's list comes from the App Store -
    # every application is a cask - so the Mac App Store machinery the sibling
    # app needs has no reason to exist here.
  };
}
