{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  outputs = inputs @ {
    nixpkgs,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["aarch64-darwin" "x86_64-darwin"];
      perSystem = {
        system,
        pkgs,
        lib,
        ...
      }: let
        arch = lib.head (lib.splitString "-" system);
      in {
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [
          ];
        };
        devShells = let
          shell = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              swiftlint
              swift-format
              swiftpm
            ];
            name = "build";
            shellHook = ''
              export PATH="''${HOME}/.mint/bin:/bin:/usr/bin:''${PATH}"
              export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
              export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
            '';
          };
        in {
          default = shell;
        };
      };
    };
}
