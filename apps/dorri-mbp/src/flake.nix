{
  description = "dorri-mbp - a second MacBook Pro as a nix-darwin configuration";

  # Deliberately NOT built on devtools, unlike the sibling apps/andrew-mbp.
  #
  # devtools (https://github.com/andrew-codes/devtools) hardcodes
  # `user = "andrew"` and layers the captain's own shell, dotfiles, git
  # identity, CLI toolchain and agent harness onto whatever machine it is
  # applied to. That is exactly right for the captain's laptop and exactly
  # wrong for somebody else's, so this machine gets its own nix-darwin system
  # rather than extending devtools'.
  #
  # The inputs below are pinned to the same release branches devtools uses, so
  # both machines track one macOS/nixpkgs generation and there is only one set
  # of release notes to read at upgrade time.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs =
    { nixpkgs, nix-darwin, nix-homebrew, ... }:
    let
      # The macOS short name of the account that owns this machine - the one
      # that runs the setup, and the one nix-darwin runs Homebrew as.
      #
      # It is read from a file rather than written inline so that setup.sh can
      # read the very same value with `cat`, before Nix is installed, and
      # refuse to run when it does not match the account invoking it. A flake
      # cannot read the environment without `--impure`, and making the whole
      # system configuration impure to learn one username is a bad trade; a
      # one-line committed file keeps evaluation pure and keeps the two
      # readers honest about disagreeing.
      #
      # `trim` rather than `readFile` directly: the file ends in a newline,
      # and a username with a trailing newline silently produces a Homebrew
      # user that does not exist.
      primaryUser = nixpkgs.lib.trim (builtins.readFile ./primary-user.txt);
    in
    {
      darwinConfigurations."dorri-mbp" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit primaryUser; };
        modules = [
          ./configuration.nix
          ./applications.nix
          nix-homebrew.darwinModules.nix-homebrew
        ];
      };
    };
}
