{
  description = "windtrap: one library for all your OCaml tests, and ppx_windtrap";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Another flake, for example weft, can use windtrap in three ways:
  #
  # - In its own OCaml scope. This uses the compiler of that scope. Override
  #   the two packages, because nixpkgs has an older windtrap:
  #
  #     ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_5.overrideScope
  #       (final: prev: {
  #         windtrap = final.callPackage windtrap.lib.windtrap { };
  #         ppx_windtrap = final.callPackage windtrap.lib.ppx_windtrap { };
  #       });
  #
  # - With the overlay, which adds windtrap and ppx_windtrap to
  #   ocaml-ng.ocamlPackages_5_5.
  #
  # - As windtrap.packages.${system}.windtrap and
  #   windtrap.packages.${system}.ppx_windtrap, with
  #   inputs.windtrap.inputs.nixpkgs.follows = "nixpkgs".
  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = "0.2.0-dev";

      # The source has only the files of the build of the two packages. The
      # tests take minutes, and they use git and, on Linux, taskset. Thus the
      # packages do not run them. Use the dev shell for the tests.
      src =
        lib:
        lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./dune-project
            ./windtrap.opam
            ./ppx_windtrap.opam
            ./lib
            ./ppx
            ./bin
            ./LICENSE
            ./README.md
          ];
        };

      meta = lib: {
        homepage = "https://github.com/bikallem/windtrap";
        license = lib.licenses.isc;
      };

      # The library windtrap and the command windtrap.
      windtrap =
        { lib, buildDunePackage }:
        buildDunePackage {
          pname = "windtrap";
          inherit version;
          minimalOCamlVersion = "5.0";
          src = src lib;
          doCheck = false;
          meta = meta lib // {
            description = "One library for all your OCaml tests";
            mainProgram = "windtrap";
          };
        };

      # The ppx (inline tests) and the instrumentation backends
      # ppx_windtrap.coverage and ppx_windtrap.mutate.
      ppx_windtrap =
        {
          lib,
          buildDunePackage,
          windtrap,
          ppxlib,
        }:
        buildDunePackage {
          pname = "ppx_windtrap";
          inherit version;
          minimalOCamlVersion = "5.0";
          src = src lib;
          propagatedBuildInputs = [
            windtrap
            ppxlib
          ];
          doCheck = false;
          meta = meta lib // {
            description = "PPX and instrumentation backend for windtrap";
          };
        };
    in
    {
      lib = { inherit windtrap ppx_windtrap; };

      overlays.default = final: prev: {
        ocaml-ng = prev.ocaml-ng // {
          ocamlPackages_5_5 = prev.ocaml-ng.ocamlPackages_5_5.overrideScope (
            ofinal: _: {
              windtrap = ofinal.callPackage windtrap { };
              ppx_windtrap = ofinal.callPackage ppx_windtrap { };
            }
          );
        };
      };

      packages = forAllSystems (
        pkgs:
        let
          ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_5.overrideScope (
            final: _: {
              windtrap = final.callPackage windtrap { };
              ppx_windtrap = final.callPackage ppx_windtrap { };
            }
          );
        in
        {
          inherit (ocamlPackages) windtrap ppx_windtrap;
          default = ocamlPackages.windtrap;
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_5;
        in
        {
          default = pkgs.mkShell {
            packages = [
              # OCaml 5.5, dune and the dependencies of ppx_windtrap.
              ocamlPackages.ocaml
              ocamlPackages.dune_3
              ocamlPackages.findlib
              ocamlPackages.ppxlib
              # The version of .ocamlformat.
              pkgs.ocamlformat_0_29_0
              # The tests use git (--mutate-since) and, on Linux, taskset.
              pkgs.git
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ]
            ++ [
              # Dev tools
              ocamlPackages.ocaml-lsp
              ocamlPackages.utop
              ocamlPackages.odoc
            ];
          };
        }
      );
    };
}
