{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    nixfmt.enable = true;
    # Shellcheck runs in the dedicated Nix check with repository-specific
    # source-path handling; treefmt should remain a formatter here.
    shellcheck.enable = false;
    shfmt.enable = true;
    taplo.enable = true;
  };
  settings.global.excludes = [
    ".build/**"
    ".direnv/**"
    "DerivedData/**"
    "result/**"
    "dist/**"
    "*.xcresult/**"
  ];
}
