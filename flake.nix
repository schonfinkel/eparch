{
  description = "Eparch's nix build and development shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };

    treefmt-nix.url = "github:numtide/treefmt-nix";

    nix-gleam = {
      url = "github:arnarg/nix-gleam";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mk-shell-bin.url = "github:rrbutani/nix-mk-shell-bin";
  };

  outputs =
    inputs@{
      self,
      devenv,
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devenv.flakeModule
        inputs.treefmt-nix.flakeModule
      ];
      systems = nixpkgs.lib.systems.flakeExposed;

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          ffiDeps = import ./src/eparch/ffi/rebar-deps.nix {
            inherit (pkgs) fetchFromGitHub fetchgit;
            inherit (pkgs.beamPackages) fetchHex;
          };
          installFfiDeps = pkgs.lib.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList (name: source: ''
              cp -R --no-preserve=mode ${source} "_checkouts/${name}"
            '') ffiDeps
          );
          ffiPackage = pkgs.beamPackages.buildRebar3 {
            name = "eparch_ffi";
            version = "1.0.0";
            src = ./src/eparch/ffi;
            EPARCH_REBAR_BUILD_DIR = "_build";
            preBuild = ''
              mkdir -p _checkouts
              ${installFfiDeps}
            '';
          };
        in
        {
          packages = {
            default = inputs'.nix-gleam.packages.buildGleamApplication {
              src = ./.;
            };
            eparch-ffi = ffiPackage;
          };

          checks = {
            eparch-ffi = ffiPackage;
            eparch-ffi-quality =
              pkgs.runCommand "eparch-ffi-quality"
                {
                  nativeBuildInputs = [ pkgs.beamPackages.rebar3 ];
                }
                ''
                  cp -R --no-preserve=mode ${./src/eparch/ffi} ffi
                  cd ffi
                  export EPARCH_REBAR_BUILD_DIR=_build
                  mkdir -p _checkouts
                  ${installFfiDeps}
                  rebar3 do eunit, dialyzer
                  touch "$out"
                '';
          };

          # nix fmt + nix flake check (auto-wired by flakeModule)
          treefmt = {
            projectRootFile = "flake.nix";
            programs.erlfmt.enable = true;
            programs.gleam.enable = true;
            programs.nixfmt.enable = true;
          };

          devenv.shells.default = {
            # https://devenv.sh/reference/options/
            # builtins.getEnv works in --no-pure-eval (direnv); falls back to
            # the store path for pure-eval (nix flake check) to satisfy the
            # devenv assertion without attempting any filesystem writes.
            devenv.root =
              let
                r = builtins.getEnv "PWD";
              in
              if r != "" then r else builtins.toString ./.;

            packages =
              with pkgs;
              [
                # Erlang tooling
                erlfmt
                erlang-language-platform
                rebar3

                # Extra tooling
                gnumake
              ]
              ++ [ config.packages.default ];

            languages.erlang = {
              enable = true;
            };

            languages.gleam = {
              enable = true;
            };

            enterShell = ''
              echo "Starting Development Environment..."
            '';
          };
        };
    };
}
