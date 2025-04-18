{
  description = "A Nix-flake-based Zig development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          zig
          zls
          lldb
          pkg-config

          vulkan-loader
          vulkan-validation-layers
          vulkan-tools

          wayland
          wayland-protocols
          wayland-scanner
          xorg.libX11
          xorg.libXrandr
          xorg.libXinerama
          xorg.libXcursor
          xorg.xinput
          xorg.libXi

          # libdecor
          libxkbcommon
          glfw
        ];
      };
    };
}
