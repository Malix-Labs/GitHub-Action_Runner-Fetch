{
  description = "GitHub Action to Fetch Information of its Runner";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          treefmt = {
            programs.shfmt.enable = true;
            programs.nixfmt.enable = true;
          };

          pre-commit.settings.hooks = {
            treefmt.enable = true;
            shellcheck.enable = true;
            statix.enable = true;
            deadnix.enable = true;
            markdownlint = {
              enable = true;
              excludes = [
                "^LICENSE\\.md$"
                "^\\.github/.*"
              ];
              settings.configuration = {
                MD013 = false;
                MD026 = false;
                MD034 = false;
                MD041 = false;
                MD012 = false;
              };
            };
          };

          packages.test-runner = pkgs.writeShellApplication {
            name = "test-runner";
            runtimeInputs = [ pkgs.gh ];
            text = ''
              gh workflow run fetch.yml --ref "$(git rev-parse --abbrev-ref HEAD)"
              gh run watch
            '';
          };

          devShells.default = config.pre-commit.devShell;

          checks = {
            formatting = config.treefmt.build.check self;
          };
        };
    };
}
