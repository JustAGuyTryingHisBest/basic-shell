let
  drv = builtins.derivation {
    name = "bs";
    system = builtins.currentSystem;
    builder = "/bin/bash";
    args = [ "-c" "zig build -Doptimize=ReleaseSmall" ]
  };
in
  drv
