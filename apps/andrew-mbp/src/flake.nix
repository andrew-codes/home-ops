{
  description = "andrew-mbp - the captain's MacBook Pro as a nix-darwin configuration";

  # Deliberately a single input.
  #
  # devtools (https://github.com/andrew-codes/devtools, `zsh` branch) already
  # evaluates a complete nix-darwin system for this machine: nixpkgs,
  # nix-darwin, home-manager and nix-homebrew are all pinned by *its*
  # flake.lock. Taking only devtools as an input means this machine can never
  # drift from the toolchain devtools was built against, and there is no second
  # copy of that wiring to keep in sync.
  #
  # setup.sh overrides this input with the working checkout at ~/.dotfiles, so
  # the modules evaluated here and the dotfiles devtools symlinks out of
  # ~/.dotfiles always come from the same tree. The pin below is the fallback
  # used when the flake is evaluated on its own (`nix flake check`).
  inputs.devtools.url = "github:andrew-codes/devtools/zsh";

  outputs =
    { self, devtools }:
    {
      # macOS activates exactly one nix-darwin system generation at a time, so
      # this is not a second configuration running alongside devtools' -- it is
      # devtools' own configuration with an extra module layered on top.
      #
      # `extendModules` re-evaluates devtools' `darwinConfigurations."mac"`
      # with additional modules, rather than re-deriving devtools' module list
      # here. Changes to how devtools wires itself together are picked up for
      # free, and nothing devtools declares is dropped.
      darwinConfigurations."andrew-mbp" = devtools.darwinConfigurations."mac".extendModules {
        modules = [ ./applications.nix ];
      };
    };
}
