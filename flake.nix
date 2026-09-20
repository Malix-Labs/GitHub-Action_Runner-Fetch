{
  description = "GitHub Action to Fetch Information of its Runner";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
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
        inputs.git-hooks-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          pre-commit.settings.hooks = {
            shfmt.enable = true;
            nixfmt.enable = true;
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

          # Waiting for https://github.com/cachix/git-hooks.nix/pull/743
          formatter =
            let
              cfg = config.pre-commit.settings;
            in
            pkgs.writeShellScriptBin "pre-commit-fmt" ''
              set -euo pipefail
              export PATH="${
                pkgs.lib.makeBinPath (
                  [
                    cfg.gitPackage
                    cfg.package
                  ]
                  ++ cfg.enabledPackages
                )
              }:$PATH"

              exitcode=0
              if [ "$#" -gt 0 ]; then
                ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --files "$@" || exitcode=$?
              else
                if [ -n "''${PRJ_ROOT:-}" ]; then
                  cd "$PRJ_ROOT"
                fi
                ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --all-files || exitcode=$?
              fi

              # pre-commit returns 1 when files were modified by hooks.
              # For a formatter (`nix fmt`), modifying files is the intended outcome.
              # If exit code was 1, re-run to distinguish between successful formatting changes (clean on 2nd pass)
              # and actual errors/syntax failures (fails again on 2nd pass).
              if [ "$exitcode" -eq 1 ]; then
                if [ "$#" -gt 0 ]; then
                  ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --files "$@"
                else
                  ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --all-files
                fi
              else
                exit "$exitcode"
              fi
            '';

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
            test-suite =
              pkgs.runCommand "test-suite"
                {
                  nativeBuildInputs = [
                    pkgs.nodejs_24
                    pkgs.gawk
                    pkgs.coreutils
                  ];
                }
                ''
                  export HOME=$TMPDIR
                  cp -r ${self}/* .
                  chmod -R +w .
                  ./tests/test_scenarios.sh
                  touch $out
                '';
          };
        };
    };
}
