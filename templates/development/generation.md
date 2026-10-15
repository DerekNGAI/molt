# Generate only missing development configuration

Run using the repository's configured OpenCode model/provider. Inspect manifests, lockfiles, CI workflows, existing devenv definitions/imports, and scripts before proposing commands. Follow the menu guideline supplied below. If the repository does not provide enough information to choose a supported native toolchain, return a precise blocked reason.

Write candidates only into Molt's owned staging directory. Eligible new repository files are `.molt/development.json`, `devenv.nix`, `devenv.yaml`, `devenv.lock`, and the missing repository menu launcher. Preserve every existing file byte-for-byte. Do not edit source, replace an existing definition, commit, or regenerate on each launch. Exclude credentials, provider settings, private keys, environment secrets, and persistent data from candidates, logs, and container images.

The profile is strict JSON version 1 with only name/actions/ports/android metadata. Actions have IDs matching `^[a-z][a-z0-9-]{0,31}$`, nonempty labels up to 80 characters, kind task or service, 1–64 nonempty argv elements up to 4096 bytes without NUL/CR/LF, and cwd defaulting to `.` inside the repository. At most 32 actions and 16 ports. Names/labels/paths cannot contain control characters. Reject duplicate IDs and duplicate app container ports. Ports reference service actions, use http/https, container ports 1–65535 except 4096, and local preferences 1024–65535. Android.enabled defaults false. Unknown fields, null fields, invalid versions, and escaping paths are errors.

Use declared commands and the existing toolchain version. Do not invent a build/test command or enable Android without an explicit request. Android is an ARM64 Redroid candidate; standard Linux ARM AVD binaries are unsupported. Choose toolchains compatible with the supplied target VM architecture; Molt verifies them during the build.

Your task is to inspect repository files and write only eligible missing candidates. Shell execution is unavailable. Molt records and compares file identities, validates the candidate profile with `molt-tui development-tools validate`, and rejects symlink redirection, unexpected files, concurrent source changes, and failed/cancelled generation or builds. You do not need to execute these checks to generate candidates.

For an existing devenv definition, preserve it and its relative paths and YAML/lock inputs. Molt creates the disposable build wrapper and adapter and runs its build/export procedure. Do not create `devenv.original.nix`, `molt.nix`, or build metadata.

Molt promotes only validated, missing files after identity checks. A prepared revision includes the checked profile, toolchain/lock inputs, template version, architecture, and OpenCode version. Subsequent unchanged launches reuse it and do not invoke AI again.
