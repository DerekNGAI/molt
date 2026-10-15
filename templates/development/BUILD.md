# Build and activate the development environment

The builder is the platform-specific Nix 2.32.4 OCI digest in `development-tools.lock.json`. Resolve it with `development-tools artifact`, then use `image@digest`, never a tag alone. The environment adapter uses devenv 2.4.0 at commit `b904dcb51fe48c30db250038241507f60752f222` and its documented container build/copy API. Required container inputs are pinned to nix2container `4e83e6724dcb9eb1b3e855426fa4c8cd19f5ce5a` and nix-mk-shell-bin `ff5d8bd4d68a347be5042e2f16caee391cd75887` when they are missing. Preserve and reuse already declared inputs.

Use only a designated disposable native ARM64 Docker daemon for acceptance. Create a job-owned builder volume for `/nix`, plus checked snapshot/output/cache directories. Do not mount a shared system Nix store, provider credentials, production data, or the Docker socket into the builder. Container/volume names and labels include the job/task. Runtime preparation later uses installation/project/role labels and the VM's UID/GID.

Create a disposable snapshot containing the required public source/config with unchanged relative paths. Preserve original file identities and exclude secrets, credentials, `.env` contents, synchronized caches, device/database data, and generated outputs. In the snapshot only:

1. Copy the original `devenv.nix` to `devenv.original.nix` in the same directory, without changing its bytes.
2. Copy `molt.nix` and `menu.mjs` alongside it.
3. Replace the snapshot's `devenv.nix` with `{ imports = [ ./devenv.original.nix ./molt.nix ]; }`. Preserve its original `devenv.yaml`, `devenv.lock`, and relative imports.
4. Create `molt-build.json` containing the checked `image` name (`molt-` plus lowercase letters/digits/hyphens) and the full 64-hex prepared `revision`. Production revisions include profile, toolchain/locks, template, architecture, and OpenCode version identities.
5. Add only missing container inputs to the snapshot, using `devenv inputs add nix2container github:nlewo/nix2container/4e83e6724dcb9eb1b3e855426fa4c8cd19f5ce5a --follows nixpkgs` and `devenv inputs add mk-shell-bin github:rrbutani/nix-mk-shell-bin/ff5d8bd4d68a347be5042e2f16caee391cd75887`. Capture the resolved snapshot lock. Never promote these wrapper/input/lock changes to the original source.

Inside the isolated builder, with the snapshot at `/workspace`, owned cache at `/molt-cache/development`, and output at `/output`, set `NIX_CONFIG` to add exactly the substituter `https://devenv.cachix.org` with public key `devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=`. Do not use `--accept-flake-config`. Without this pinned cache the devenv CLI compiles from source and exceeds the bounded build time.

```sh
set -eu
DEVELOPMENT_DEVENV='github:cachix/devenv/b904dcb51fe48c30db250038241507f60752f222#devenv'
nix --extra-experimental-features 'nix-command flakes' run "$DEVELOPMENT_DEVENV" -- container build molt
nix --extra-experimental-features 'nix-command flakes' run "$DEVELOPMENT_DEVENV" -- container copy --registry 'docker-archive:/output/environment.tar:' molt
```

This exports the real shell closure, package environment, and declared scripts into an OCI archive. `docker load --input <owned-output>/environment.tar` imports it into the designated daemon. No Dockerfile interprets Nix. Any subsequent Molt layer copies its checked OpenCode/runtime runner into this already exported environment; task 02 supplies `/opt/molt/development.mjs`.

The OCI entrypoint sources the exported environment and executes its argv directly. `/opt/molt/entrypoint <argv...>` also activates it for Docker exec commands and PTYs. `/opt/molt/activate` is available for controlled shell initialization. `/opt/molt/node` is Molt's private Node 24 runtime; repository toolchain choices are preserved. Source is mounted at `/workspace`, and runtime state lives outside synchronization under `/molt-cache/development`.

Before promotion, require the native smoke procedure in `tests/fixtures/development-contract/export-smoke.sh`. It checks Node/architecture, imported environment variables, declared scripts, relative-definition preservation, and menu packaging with a disclosed runner stub. The stub checks list/run arguments and exit codes only; task 99 must verify real persistent services. Record image IDs/digests, input/exported trees, lock identities, commands, and cleanup. Missing/failed native checks mean BLOCKED, even when helper unit tests pass.

The locked Android candidate is Redroid `14.0.0_64only-240527`, Android 14/API 34, on ARM64. Registry platform metadata is not boot/Flutter proof. Its host needs 4 KB pages, usable Binder/binderfs devices, and memfd (with `androidboot.use_memfd=1`) or the applicable ashmem support, plus privileged-container capability. Only Android needs that elevation. Never replace a production kernel, load modules, or use standard Linux ARM AVD tools as a test workaround. Real Android/Flutter and private macOS viewer acceptance belong to the designated hardware gates.
