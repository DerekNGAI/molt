# molt

Remote project environments for macOS.

molt keeps your checkout and everyday tools on your Mac while running project
dependencies and processes inside isolated Docker containers on a remote
Ubuntu or Debian VM.

```text
Mac checkout ── Mutagen ──▶ VM mirror ── bind mount ──▶ Docker container
Mac shell    ── SSH and port forwarding ─────────────▶ VM
```

## What it does

- Detects Node, Rust, Go, and Python projects.
- Generates a small remote `devenv.nix` when a project does not have one.
- Creates one Mutagen mirror and Docker container per project.
- Runs supported development commands in the remote container through local
  shims.
- Starts an OpenCode server for each active project and forwards project ports
  to `localhost`.

## Requirements

### Mac

- macOS with Bash and Zsh
- Git
- SSH access to the VM
- `curl`, `tar`, `unzip`, and `shasum` for private dependency downloads
- [Mutagen](https://mutagen.io/) 0.18.1 and [OpenCode](https://opencode.ai/)
  can be supplied externally; otherwise the installer downloads private copies

### Remote VM

- Ubuntu or Debian
- Bash, GNU `realpath`, SSH, and Docker usable by the SSH user without `sudo`
- Install Docker and configure user access separately before running `molt setup`
- Enough disk for Docker images, Nix packages, and project caches

## Quick start

1. Configure an SSH host using [macos/ssh_config.snippet](macos/ssh_config.snippet).
   Replace `HostName`, `User`, and `IdentityFile` for your VM.
2. Install molt from this checkout:

   ```bash
   ./install.sh
    source ~/.molt/activate.zsh
   ```

3. Edit `~/.molt/config` if the defaults do not match your setup.
4. Check the connection and prepare the VM:

   ```bash
    molt setup
    molt doctor
   ```

5. Open the project picker:

   ```bash
   molt
   ```

Choose a project and select **start**. molt will sync the checkout, build its
environment, start the container, and forward its ports.

Activation applies to the current Zsh session. Source `activate.zsh` again in a
new terminal, or invoke `~/.molt/bin/molt` directly. Installation never modifies
`.zshrc`, SSH configuration, Homebrew, or system services.

To choose a different local folder:

```bash
MOLT_HOME="$HOME/Tools/molt" ./install.sh
source "$HOME/Tools/molt/activate.zsh"
```

## Configuration

`install.sh` creates `~/.molt/config` from [config.example](config.example):

```bash
MOLT_HOST=oci-dev
MOLT_ROOT="$HOME/src"
MOLT_REMOTE_HOME='$HOME/molt'
MOLT_OPENCODE_BASE_PORT=4100
```

The remote root uses `$HOME` on the VM. All child directories derive from it.
Each project receives a stable directory and an OpenCode port derived from its
repository path. An optional `MOLT_SSH_CONFIG` can point to an SSH configuration
file stored inside the local installation; an existing `~/.ssh/config` is also
usable as an external prerequisite.

Hosts and actual remote paths are recorded when resources are created. Cleanup
uses these records even if you edit the configuration afterward. Clean up a
recorded remote root before choosing another root on the same SSH host.

OpenCode uses installation-specific configuration and authentication. Configure
the remote server in `~/molt/config/opencode`; local client data lives under
`~/.molt/state`. Existing global OpenCode settings are not imported automatically.

## Daily use

Once a project is running, work from its Mac checkout as usual:

```bash
cd ~/Documents/Github/app
pnpm dev
pnpm test
opencode
git status
nvim .
```

The shims route supported development commands to the active project
container. Git, editors, search tools, and ordinary shell commands remain
local. Run one command locally with:

```bash
MOLT_LOCAL=1 pnpm test
```

Use `molt status` to see active containers, synchronization, and forwarded
ports. Use `molt stop` or `molt down` when you are finished.

## Commands

| Command | Description |
| --- | --- |
| `molt` | Open the project TUI |
| `molt scan [root]` | List Git repositories |
| `molt inspect [repo]` | Inspect runtime and project files |
| `molt generate-env [repo]` | Create a minimal `devenv.nix` |
| `molt setup` | Prepare the VM |
| `molt register [repo]` | Register a repository |
| `molt start [repo]` | Sync, build, and start a project |
| `molt stop [repo]` | Stop one project |
| `molt up` | Start all registered projects |
| `molt down` | Stop all active projects |
| `molt local-down` | Stop owned local helpers, Mutagen daemon, and SSH connections |
| `molt status` | Show SSH, project, container, and port state |
| `molt doctor` | Check local and VM prerequisites |
| `molt run <command> [args]` | Run a command in the active container |
| `molt ssh [args]` | Open an SSH session to the VM |
| `molt oc [args]` | Attach the local OpenCode client remotely |
| `molt logs [repo]` | Show the remote OpenCode log |
| `molt review-env [repo]` | Review generated `devenv.nix` |
| `molt reset [repo]` | Remove one project's remote and local state |
| `molt reset --all` | Remove all project state |

## Project configuration

Most repositories need no molt file. To declare ports that should always be
forwarded, add an optional `.molt.yml` to the repository:

```yaml
ports:
  - 3000
  - 4173
```

The file is read locally and can be committed with the project. While a
remote command is attached, molt also detects newly opened ports and forwards
them automatically.

## One folder per machine

```text
Mac ~/.molt/
  .install-manifest       ownership, installation ID, and tool locations
  activate.zsh            explicit session activation
  bin/, shims/, tools/    links to the current release
  current, releases/      verified releases and atomic upgrade switch
  config, opencode.password
  projects/<id>/          registry and cleanup records
  state/                 configuration, authentication, caches, temporary files,
                         Mutagen daemon, SSH sockets, and known hosts

VM ~/molt/
  .install-manifest       matching installation ID
  projects/<id>/          Mutagen mirror; dependencies and build output
  meta/<id>/              Dockerfile, password, logs; generated environment in env/
  config/opencode/        installation-specific server/provider configuration
  cache/<id>/             container HOME, package caches, and tool state
  state/                 Mutagen agents, sync state, and temporary uploads
```

Docker's own storage is the exception: containers, images, base images, and build
cache are stored by the existing Docker daemon. Project caches use bind-mounted
directories in the remote root. Containers and project images carry
`io.molt.installation` and `io.molt.project` labels for targeted cleanup.

Mutagen synchronizes the checkout one way from the Mac to the VM. Git data and
common dependencies/build caches stay out of synchronization. Starting a project
does not write or commit files on the Mac. Use `molt generate-env` and
`molt commit-env` explicitly if you want an environment file in your repository.

## Installation and upgrades

1. Validate the destination and its ownership marker. Home/root aliases, source
   checkout overlap, and populated unrelated directories are rejected.
2. Stage molt and missing portable tools inside the destination. Downloads use
   pinned versions and SHA-256 hashes from `tools.lock`, without executing a
   downloaded installer. External binaries can be selected with
   `MOLT_MUTAGEN_BINARY` and `MOLT_OPENCODE_BINARY`.
3. Verify executable versions, then switch the `current` release link. Preserve
   configuration, passwords, and project records. A failed upgrade leaves the
   previous release available; a failed fresh installation removes its artifacts.
4. Source `activate.zsh` for the current session. Repeated activation does not
   duplicate PATH entries.
5. `molt setup` checks existing Docker access and creates the marked remote root.
   It does not provision the VM.

Tool environment overrides apply only to molt-managed processes. Mutagen's
local daemon and remote agent run from private state directories, so global
Mutagen sessions and OpenCode settings are independent of a new installation.

Generated environments run from their metadata folder, then commands enter the
project workspace. When a checkout has its own environment, it is used directly.
Remote-generated lock/config files are protected from synchronization until a
corresponding Mac source file exists; starting again updates that policy.

## Reset and uninstall

Reset a project when you want to remove its container, image, Mutagen session,
forwarded ports, remote mirror, and local state:

```bash
molt reset
```

Reset keeps the Mac checkout and Git history. Cleanup is safe to retry: already
absent resources count as removed; real failures return a nonzero exit status
and keep the records needed for another attempt.

To remove registered projects, the remote root, and the local installation:

```bash
molt-uninstall --yes
```

Without `--yes`, removal asks for confirmation. An installation that never
created remote resources can be removed without connecting to the VM. If the
VM is unreachable and resources are recorded, normal uninstall preserves the
installation for retry.

For explicit local-only removal:

```bash
molt-uninstall --yes --local-only
```

This prints the saved hosts, paths, and Docker identifiers before removing local
records. Save that output for later remote cleanup. It stops owned local helpers
and leaves remote containers and files in place.

Existing external tools, Git checkouts, SSH settings, Docker itself, and shared
Docker base/build caches are preserved. Close activated shells or remove their
session PATH entries after deleting the installation.

## Manual removal without the uninstaller

For a normal shutdown, run `molt down` and `molt local-down`, then delete
`~/.molt`. If molt cannot run, stop its command processes, private Mutagen daemon,
and SSH connections in Activity Monitor before deleting the folder. Deleting a
folder alone does not stop running processes.

On the VM, the following Bash commands remove the labeled resources for the
default remote root and then delete the folder. Substitute your configured root
if different:

```bash
root="$HOME/molt"
owner="$(cat "$root/.install-manifest")"
[[ "$owner" =~ ^[a-f0-9]{32}$ ]] || { printf 'Invalid installation ID\n' >&2; exit 1; }
docker ps -aq --filter "label=io.molt.installation=$owner" | xargs -r docker rm -f
docker image ls -q --filter "label=io.molt.installation=$owner" | sort -u | xargs -r docker image rm
# Containers may have created files owned by root. This helper restores ownership.
docker run --rm --network none --mount "type=bind,src=$root,dst=/cleanup" \
  busybox:1.37.0 chown -R "$(id -u):$(id -g)" /cleanup
rm -rf -- "$root"
```

The installation ID is also in the Mac manifest if the remote marker is missing.
Shared Docker base images and build cache remain under Docker's own management;
there is no broad Docker prune in molt cleanup.

## Migrating an older installation

Run the new installer with the same `MOLT_HOME`. It preserves project records,
configuration, and credentials, saves `legacy-install-manifest`, and removes
exactly matching legacy shell entries. Symlinked `.zshrc` files stay symlinked;
the original content is backed up inside the installation. Edited entries are
reported for manual cleanup.

Legacy project records retain their original container/image/volume names and
paths for `molt reset --all`. Reset these projects before starting them with the
contained layout. If you changed the SSH host before migration, correct the
saved project `host` records before resetting.

Global Homebrew/OpenCode installations, shared OpenCode configuration, shared
Mutagen state, old SSH entries, and empty legacy remote directories are reported
or preserved for manual review. In particular, remove empty legacy `projects`
and `meta` directories before claiming the same remote root with `molt setup`.
Import any provider settings into the new remote configuration explicitly.

## Development

Run the shell checks from the repository root:

```bash
bash tests/molt_test.sh
bash tests/lifecycle_test.sh
```

For a real lifecycle and containment check, run the opt-in integration test. It
requires a local Docker daemon, downloads the pinned tools if needed, and creates
a disposable SSH host with an independent Docker daemon:

```bash
bash tests/integration_test.sh
```

The test covers setup, real synchronization, project startup, running a command,
stop/restart, and complete removal. It checks for global tool directories on both
machines. Failed runs retain their local diagnostic artifacts; the test's Docker
host and image are removed on exit.

For debugging, `MOLT_INTEGRATION_KEEP_VM=1` keeps the disposable host and image
after a failure. The test prints their name; remove them with `docker rm -f` and
`docker image rm` after investigating.
