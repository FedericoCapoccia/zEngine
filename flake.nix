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
          shaderc

          wayland
          wayland-protocols
          wayland-scanner
          libxkbcommon
        ];
      };

      VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
    };
}
