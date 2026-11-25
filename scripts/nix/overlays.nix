{ inputs, lib, ... }:
let
  root = ../../.;
  src = lib.fileset.toSource {
    inherit root;
    fileset = (
      lib.fileset.intersection root (
        lib.fileset.difference
          (lib.fileset.unions (
            map (p: root + p) [
              /Cargo.toml
              /Cargo.lock
              /src
              /crates
              /tests
              /assets
              /benches
              /toolkit
              /scripts
            ]
          )) ./.
      )
    );
  };
  # Creates the default toolchains used in later overlays.
  toolchain-overlay = (final: previous: {
    # Override the rustPlatform without forcing a rebuild of _every_ tool as well
    nushellRustToolchain' = previous.rust-bin.fromRustupToolchainFile ../../rust-toolchain.toml;
    nushellRustPlatform' = final.makeRustPlatform {
      cargo = final.nushellRustToolchain';
      rustc = final.nushellRustToolchain';
    };
    # Add a specific rustPlatform with extensions for development/editors
    rustToolchain-devshell = final.nushellRustToolchain'.override ({
      extensions = [
        "rust-src"
        "rust-analyzer"
      ];
    });
    rustPlatform-devshell = final.makeRustPlatform {
      cargo = final.rustToolchain-devshell;
      rustc = final.rustToolchain-devshell;
    };
    rustToolchain-latest-devshell = previous.rust-bin.stable.latest.default.override ({
      extensions = [
        "rust-src"
        "rust-analyzer"
      ];
    });
    rustPlatform-latest-devshell = final.makeRustPlatform {
      cargo = final.rustToolchain-latest-devshell;
      rustc = final.rustToolchain-latest-devshell;
    };
  });
  withPlugins = prog: plugins:
    ''
      touch "$out/plugin.msgpackz"
      ${lib.getExe prog} \
        --plugin-config "$out/plugin.msgpackz" \
        --commands '${
          lib.concatStringsSep "; " (
            map (plugin: "plugin add ${lib.getExe plugin}") plugins
          )
        }'
      wrapProgram $out/bin/nu \
        --add-flag "--plugin-config=$out/plugin.msgpackz"
    '';
  naersk-overlay =
    (final: prev:
      let
        naersk = prev.callPackage inputs.naersk {
          rustc = prev.nushellRustToolchain';
          cargo = prev.nushellRustToolchain';
        };
        defaultArgs = {
          NUSHELL_CARGO_PROFILE = "release";
          NU_TEST_LOCALE_OVERRIDE = "en_US.UTF-8";
          preCheck = "export HOME=$(mktemp -d)";
        };
        localPlugins = builtins.mapAttrs
          (pname: d: naersk.buildPackage (defaultArgs // d // rec {
            name = "nu_plugin_${pname}";
            preBuild = "pushd crates/nu_plugin_${pname}";
            preInstall = "popd";
            meta.mainProgram = name;
            inherit src;
            passthru = {
              tests = lib.genAttrs [ "test" "check" "clippy" ]
                (mode:
                  naersk.buildPackage {
                    name = "${name}-${mode}";
                    inherit (localPlugins.${pname}) src;
                    inherit mode preBuild preInstall;
                  }
                );
            };
          }))
          {
            formats = { };
            gstat = { };
            inc = { };
            polars = {
              cargoTestOptions = d: d ++ [
                "--"
                "--skip=dataframe::command::core::to_repr::test::test_examples"
              ];
            };
            query = { };
          };
      in
      {
        nushell = naersk.buildPackage (defaultArgs // {
          name = "nushell";
          inherit src;
          # doCheck = true;
          # doDoc = true;
          meta.mainProgram = "nu";
          passthru = {
            plugins = localPlugins;
            withPlugins = plugins:
              final.symlinkJoin {
                inherit (final.nushell) version meta;
                pname = "nushell-all";
                nativeBuildInputs = [ final.makeWrapper ];
                paths = [
                  final.nushell
                ] ++ plugins;
                postBuild = withPlugins final.nushell plugins;
              };
            all = final.nushell.withPlugins (builtins.attrValues localPlugins);
            tests = lib.genAttrs [ "test" "check" "clippy" ] (mode:
              naersk.buildPackage {
                inherit (final.nushell) src;
                name = "nushell-${mode}";
                cargoTestCommands = d: [
                  "export HOME=$(mktemp -d)"
                ] ++ d;
                inherit mode;
                cargoTestOptions = d: d ++ [
                  "--"
                  "--skip=integration::cli::ide_flags_accept_values"
                ];
              }
            );
          };
        });
      });
  main-overlay = naersk-overlay;
  all-overlays = lib.composeManyExtensions [
    inputs.rust-overlay.overlays.default
    toolchain-overlay
    main-overlay
    naersk-overlay
  ];
in
{
  inherit
    main-overlay
    toolchain-overlay
    naersk-overlay
    all-overlays;
}
