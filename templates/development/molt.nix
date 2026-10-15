{ pkgs, config, lib, ... }:
let
  metadata = builtins.fromJSON (builtins.readFile ./molt-build.json);
  shellInputs = config.lib.getInputs [
    {
      name = "mk-shell-bin";
      url = "github:rrbutani/nix-mk-shell-bin";
      attribute = "containers";
    }
  ];
  shell = shellInputs.mk-shell-bin.lib.mkShellBin { drv = config.shell; nixpkgs = pkgs; };
  activation = pkgs.writeText "molt-activate" ''
    source ${shell.envScript}
    export DEVENV_ROOT=/workspace
    export DEVENV_DOTFILE=/molt-cache/development/devenv
    export DEVENV_RUNTIME=/molt-cache/development/runtime
  '';
  entrypoint = pkgs.writeShellScript "molt-entrypoint" ''
    set -e
    source /opt/molt/activate
    cd /workspace
    exec "$@"
  '';
  menu = pkgs.writeShellScriptBin "menu" ''
    exec ${pkgs.nodejs_24}/bin/node ${./menu.mjs} "$@"
  '';
  assets = pkgs.runCommand "molt-runtime-activation" { } ''
    mkdir -p $out/opt/molt
    cp ${entrypoint} $out/opt/molt/entrypoint
    chmod 755 $out/opt/molt/entrypoint
    ln -s ${activation} $out/opt/molt/activate
    ln -s ${pkgs.nodejs_24}/bin/node $out/opt/molt/node
  '';
in
assert builtins.match "molt-[a-z0-9-]+" metadata.image != null;
assert builtins.match "[a-f0-9]{64}" metadata.revision != null;
{
  packages = [ menu ];
  # devenv's container module fixes its root to /env; all Molt repository mounts use /workspace.
  devenv.root = lib.mkOverride 0 "/workspace";
  devenv.dotfile = lib.mkOverride 0 "/molt-cache/development/devenv";
  devenv.runtime = lib.mkOverride 0 "/molt-cache/development/runtime";
  containers.molt = {
    name = metadata.image;
    version = metadata.revision;
    copyToRoot = [ ];
    workingDir = "/workspace";
    entrypoint = [ "/opt/molt/entrypoint" ];
    startupCommand = [ "${pkgs.bashInteractive}/bin/bash" ];
    layers = [{ copyToRoot = [ assets ]; }];
  };
}
