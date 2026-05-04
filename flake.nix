{
  description = "NixOS module for Shlink — the self-hosted URL shortener";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.shlink  = import ./modules/shlink.nix;
    nixosModules.default = self.nixosModules.shlink;

    packages = nixpkgs.lib.genAttrs
      [ "x86_64-linux" "aarch64-linux" ]
      (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          shlink = pkgs.callPackage ./pkgs/shlink.nix { };
          default = pkgs.callPackage ./pkgs/shlink.nix { };
        });
  };
}
