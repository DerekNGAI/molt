{ pkgs, ... }: {
  packages = [ pkgs.nodejs_24 ];
  env.MOLT_FIXTURE = "existing-definition";
  scripts.fixture-check.exec = ''
    ${pkgs.nodejs_24}/bin/node -e 'const assert = require("node:assert/strict"); assert.equal(process.env.MOLT_FIXTURE, "existing-definition"); assert.equal(process.env.DEVENV_ROOT, "/workspace");'
  '';
}
