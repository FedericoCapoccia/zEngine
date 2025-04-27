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
          vulkan-loader
          vulkan-tools
          vulkan-tools-lunarg
          vulkan-validation-layers
          shaderc

          wayland
          wayland-protocols
          wayland-scanner
          libxkbcommon
        ];

        VK_LAYER_PATH = "/home/fede/VulkanSDK/1.4.309.0/x86_64/share/vulkan/explicit_layer.d";
        LD_LIBRARY_PATH = "${
          pkgs.lib.makeLibraryPath [
            pkgs.vulkan-loader
            pkgs.shaderc
          ]
        }:/home/fede/VulkanSDK/1.4.309.0/x86_64/lib";
      };

      # VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
    };
}
