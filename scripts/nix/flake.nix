{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, ... }@inputs:
    let
      inherit (inputs.nixpkgs) lib;
      # systems = lib.systems.flakeExposed;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "powerpc64le-linux"
        "aarch64-darwin"
        "riscv64-linux"
        "armv6l-linux"
        "armv7l-linux"
        "i686-linux"
        ## Broken in `nix flake check`
        # "x86_64-freebsd"
      ];
      overlays = import ./overlays.nix { inherit inputs lib; };
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                overlays.all-overlays
              ];
            };
          }
        );
    in
    {
      overlays = {
        default = lib.composeManyExtensions [ overlays.toolchain-overlay overlays.main-overlay ];
        naersk = lib.composeManyExtensions [ overlays.toolchain-overlay overlays.naersk-overlay ];
        all = overlays.all-overlays;
      };
      packages = forEachSupportedSystem (
        { pkgs, ... }:
        {
          inherit (pkgs) nushell;
          dev = pkgs.nushell.override {
            buildType = "debug";
          };
          default = pkgs.nushell;
          all-dev = pkgs.symlinkJoin {
            inherit (pkgs.nushell) version;
            pname = "nushellAll";
            paths = [ self.packages.${pkgs.stdenv.hostPlatform.system}.dev ]
              ++ (builtins.attrValues self.legacyPackages.${pkgs.stdenv.hostPlatform.system}.nushellPluginsDev);
          };
          all = pkgs.symlinkJoin {
            inherit (pkgs.nushell) version;
            pname = "nushellAll";
            paths = [ pkgs.nushell ]
              ++ (builtins.attrValues self.legacyPackages.${pkgs.stdenv.hostPlatform.system}.nushellPlugins);
          };
        }
      );
      legacyPackages = forEachSupportedSystem
        (
          { pkgs, ... }:
          {
            nushellPlugins = {
              # Only getting a subset of these so we don't have _all_ of the
              # plugins that are in `nixpkgs`
              inherit (pkgs.nushellPlugins)
                formats
                gstat
                inc
                polars
                query
                ;
            };
            nushellPluginsDev = (lib.mapAttrs
              (_: plugin: plugin.override { buildType = "debug"; })
              self.legacyPackages.${pkgs.stdenv.hostPlatform.system}.nushellPlugins
            );
          }
        );
      devShells = forEachSupportedSystem (
        { pkgs, ... }:
        let
          basepkgs =
            with pkgs;
            (
              [
                curlMinimal
                openssl
                pkg-config
                zstd
                zlib
                libgit2
              ]
              ++ (lib.optionals stdenv.hostPlatform.isLinux [
                python3
                libX11
              ])
              ++ (lib.optionals stdenv.hostPlatform.isDarwin [
                nghttp2
              ])
            );
        in
        {
          # devshell with build/check deps from nushell and plugins, with some
          # separation for linux/darwin.
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                rustToolchain-devshell
                rustPlatform-devshell.bindgenHook
              ]
              ++ basepkgs;
          };
          latest = pkgs.mkShell {
            packages =
              with pkgs;
              [
                rustToolchain-latest-devshell
                rustPlatform-latest-devshell.bindgenHook
              ]
              ++ basepkgs;
          };
        }
      );
    };
}
