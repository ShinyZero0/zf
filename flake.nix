{
  description = "A program to extend i3wm functions";

  inputs = { nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable"; };
  outputs = { self, nixpkgs, }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        name = "I3Helper.cs";
        buildInputs = [ pkgs.zig ];
      };
      packages.system.default = nixpkgs.stdenv.mkDerivation {
        
      };
    };
}
