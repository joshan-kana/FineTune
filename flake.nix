{
  description = "FineTune fork: per-application volume, Audio Unit chains, and multichannel macOS audio";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      git-hooks,
      ...
    }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        isDarwin = pkgs.stdenv.isDarwin;
        sourceFilter =
          path: type:
          let
            rel = lib.removePrefix ((toString ./.) + "/") (toString path);
          in
          !(lib.hasPrefix ".git/" rel)
          && !(lib.hasPrefix ".direnv/" rel)
          && !(lib.hasPrefix ".build/" rel)
          && !(lib.hasPrefix "DerivedData/" rel)
          && !(lib.hasPrefix "result/" rel)
          && !(lib.hasPrefix "dist/" rel)
          && !(lib.hasSuffix ".xcresult" rel)
          && !(lib.hasSuffix ".dmg" rel)
          && !(lib.hasSuffix ".zip" rel);
        cleanSource = lib.cleanSourceWith {
          src = ./.;
          filter = sourceFilter;
        };
        script =
          name:
          pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = with pkgs; [
              bash
              coreutils
              findutils
              git
              jq
              nix
            ];
            text = ''
              set -euo pipefail
              export FINETUNE_SCRIPT_ROOT="''${FINETUNE_SCRIPT_ROOT:-$PWD/scripts}"
              exec ${pkgs.bash}/bin/bash ${./scripts/${name}} "$@"
            '';
          };
        doctor = script "doctor";
        build = script "build";
        test = script "test";
        run = script "run";
        install = script "install";
        update-install = script "update-install";
        uninstall = script "uninstall";
        package = script "package";
        clean = script "clean";
        lint = script "lint";
        fix = script "fix";
        check = script "check";
        format = script "format";
        logs = script "logs";
        benchmark-latency = script "benchmark-latency";
        audio-probe = script "audio-probe";
        sync-upstream = script "sync-upstream";
        legacy-audio-check = script "legacy-audio-check";
        legacy-audio-fix = script "legacy-audio-fix";
        toolSet = pkgs.symlinkJoin {
          name = "finetune-tools";
          paths = [
            doctor
            build
            test
            lint
            check
            format
            package
          ];
        };
        app = program: description: {
          type = "app";
          inherit program;
          meta.description = description;
        };
        xcodeBuild = lib.optionalAttrs isDarwin (
          pkgs.stdenv.mkDerivation {
            pname = "FineTune";
            version = "1.9.0-jk.1";
            src = cleanSource;
            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
              git
              jq
            ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/finetune-home"
              mkdir -p "$HOME"
              developer_dir="''${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
              if [ -z "$developer_dir" ] || [[ "$developer_dir" == */CommandLineTools* ]]; then
                echo "FineTune requires full Xcode; select it with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
                exit 1
              fi
              export DEVELOPER_DIR="$developer_dir"
              sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
              xcode_version="$(/usr/bin/xcodebuild -version | head -1)"
              echo "Building with $xcode_version"
              echo "SDK: $sdk"
              /usr/bin/xcodebuild -project FineTune.xcodeproj -scheme FineTune -configuration Release \
                -derivedDataPath "$TMPDIR/finetune-derived-data" \
                -sdk macosx CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
                build
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/Applications"
              /usr/bin/ditto "$TMPDIR/finetune-derived-data/Build/Products/Release/FineTune.app" "$out/Applications/FineTune.app"
              /usr/bin/codesign --force --deep --sign - "$out/Applications/FineTune.app"
              /usr/bin/codesign --verify --deep --strict "$out/Applications/FineTune.app"
              /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$out/Applications/FineTune.app/Contents/Info.plist"
              runHook postInstall
            '';
            meta = {
              description = "FineTune macOS application; host Xcode is a verified input";
              mainProgram = "FineTune";
            };
          }
        );
        universal = lib.optionalAttrs isDarwin (
          pkgs.stdenv.mkDerivation {
            pname = "FineTune-universal";
            version = "1.9.0-jk.1";
            src = cleanSource;
            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
              git
              jq
            ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME="$TMPDIR/finetune-home"
              mkdir -p "$HOME"
              developer_dir="''${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || true)}"
              [[ "$developer_dir" != */CommandLineTools* ]] || { echo "Full Xcode is required" >&2; exit 1; }
              export DEVELOPER_DIR="$developer_dir"
              /usr/bin/xcodebuild -project FineTune.xcodeproj -scheme FineTune -configuration Release \
                -derivedDataPath "$TMPDIR/finetune-derived-data" \
                -sdk macosx ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
                CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
            '';
            installPhase = ''
              mkdir -p "$out/Applications"
              /usr/bin/ditto "$TMPDIR/finetune-derived-data/Build/Products/Release/FineTune.app" "$out/Applications/FineTune.app"
              /usr/bin/codesign --force --deep --sign - "$out/Applications/FineTune.app"
              /usr/bin/codesign --verify --deep --strict "$out/Applications/FineTune.app"
            '';
          }
        );
        checkScript = pkgs.writeShellApplication {
          name = "check-all";
          runtimeInputs = with pkgs; [
            bash
            git
            nix
          ];
          text = ''
            set -euo pipefail
            exec ${check}/bin/check "$@"
          '';
        };
        treefmt = treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix { inherit pkgs; });
      in
      {
        packages = {
          default = if isDarwin then xcodeBuild else lint;
          FineTune = xcodeBuild;
          FineTune-universal = universal;
          tools = toolSet;
        };
        apps = {
          doctor = app "${doctor}/bin/doctor" "Read-only environment and repository diagnostics";
          build = app "${build}/bin/build" "Build the Xcode app in disposable repository output";
          test = app "${test}/bin/test" "Run Xcode tests and preserve xcresult output";
          run = app "${run}/bin/run" "Build and launch FineTune without installing it";
          install = app "${install}/bin/install" "Back up and atomically install the validated fork";
          update-install = app "${update-install}/bin/update-install" "Update and install the fork from GitHub";
          uninstall = app "${uninstall}/bin/uninstall" "Remove only the installed fork app";
          package = app "${package}/bin/package" "Build DMG, ZIP, checksums, and metadata";
          clean = app "${clean}/bin/clean" "Remove generated repository build output";
          lint = app "${lint}/bin/lint" "Run read-only static validation";
          fix = app "${fix}/bin/fix" "Apply repository formatter fixes";
          format = app "${format}/bin/format" "Format Nix and shell sources";
          check = app "${check}/bin/check" "Run the complete local validation";
          logs = app "${logs}/bin/logs" "Inspect FineTune unified logs";
          benchmark-latency = app "${benchmark-latency}/bin/benchmark-latency" "Report callback and Audio Unit latency data";
          audio-probe = app "${audio-probe}/bin/audio-probe" "Generate a deterministic multichannel probe description";
          sync-upstream = app "${sync-upstream}/bin/sync-upstream" "Safely synchronize the fork with upstream";
          legacy-audio-check = app "${legacy-audio-check}/bin/legacy-audio-check" "Inspect legacy virtual audio dependencies";
          legacy-audio-fix = app "${legacy-audio-fix}/bin/legacy-audio-fix" "Remove only explicitly obsolete legacy audio state";
        };
        formatter = treefmt.config.build.wrapper;
        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              git
              gh
              jq
              nixd
              nil
              nixfmt
              statix
              deadnix
              shellcheck
              shfmt
              actionlint
              swift-format
              swiftlint
              xcbeautify
              pre-commit
            ]
            ++ lib.optional isDarwin pkgs.create-dmg;
          shellHook = ''
            set -euo pipefail
            if [ "$(uname -s)" = Darwin ]; then
              selected="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
              if [[ "$selected" == */CommandLineTools* || -z "$selected" ]]; then
                echo "warning: full Xcode is not selected; set DEVELOPER_DIR before building FineTune" >&2
              else
                echo "Xcode: $(DEVELOPER_DIR="$selected" /usr/bin/xcodebuild -version | head -1)"
                echo "SDK: $(DEVELOPER_DIR="$selected" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
              fi
            fi
            echo "FineTune commands: bld tst rn inst pkg fmt lt fix chk doc logs syncup"
          '';
        };
        checks = {
          formatting = treefmt.config.build.check self;
          nix =
            pkgs.runCommand "finetune-nix-check" { nativeBuildInputs = [ pkgs.nix ]; }
              ''export HOME="$TMPDIR/finetune-nix-home"; mkdir -p "$HOME"; export XDG_CACHE_HOME="$HOME/.cache"; nix flake check --no-build ${self}; touch $out'';
          shell =
            pkgs.runCommand "finetune-shell-check"
              {
                nativeBuildInputs = [
                  pkgs.shellcheck
                  pkgs.shfmt
                ];
              }
              "cd ${cleanSource}; find scripts -type f ! -name '*.swift' -print0 | xargs -0 shellcheck -x -e SC1091; shfmt -d scripts; touch $out";
          project-integrity =
            pkgs.runCommand "finetune-project-integrity" { nativeBuildInputs = [ pkgs.ripgrep ]; }
              "cd ${cleanSource}; test -f FineTune.xcodeproj/project.pbxproj; rg -q 'PBXFileSystemSynchronizedRootGroup' FineTune.xcodeproj/project.pbxproj; touch $out";
          xcode-build = lib.optionalAttrs isDarwin (
            pkgs.runCommand "finetune-xcode-build-check" {
              nativeBuildInputs = [ build ];
            } "${build}/bin/build --configuration Debug; touch $out"
          );
          unit-tests = lib.optionalAttrs isDarwin (
            pkgs.runCommand "finetune-unit-tests" {
              nativeBuildInputs = [ test ];
            } "${test}/bin/test; touch $out"
          );
          multichannel-tests =
            pkgs.runCommand "finetune-multichannel-tests" { }
              "cd ${cleanSource}; find FineTuneTests -name '*Multichannel*Tests.swift' -print -quit | grep -q .; touch $out";
          github-actions = pkgs.runCommand "finetune-github-actions" {
            nativeBuildInputs = [ pkgs.actionlint ];
          } "cd ${cleanSource}; actionlint .github/workflows/*.yml; touch $out";
          swift-format = pkgs.runCommand "finetune-swift-format" {
            nativeBuildInputs = [ pkgs.swift-format ];
          } "cd ${cleanSource}; swift-format lint --recursive FineTune FineTuneTests; touch $out";
          swift-lint = pkgs.runCommand "finetune-swift-lint" {
            nativeBuildInputs = [ pkgs.swiftlint ];
          } "cd ${cleanSource}; swiftlint lint --strict; touch $out";
        };
      }
    );
}
