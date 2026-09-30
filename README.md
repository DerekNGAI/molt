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
- Provides a full screen control center on your Mac for installation, SSH setup,
  VM preparation, projects, settings, diagnostics, upgrades, and uninstall.

## Requirements

### Mac

- macOS with Bash and Zsh
- Git
- A VM address and an initial working SSH login (key, SSH agent, or password)
- `curl`, `tar`, `unzip`, and `shasum` for private dependency downloads
- Perl (included with macOS) for reading SSH aliases and included configurations
- [Mutagen](https://mutagen.io/) 0.18.1 and [OpenCode](https://opencode.ai/)
  can be supplied externally; otherwise the installer downloads private copies
- [Gum](https://github.com/charmbracelet/gum) 2.0.2 powers the terminal interface;
  the installer supplies a private copy automatically

### Remote VM

- Ubuntu or Debian
- Bash, GNU `realpath`, and an SSH server
- Docker usable by the SSH user without `sudo`; the guided setup can install the
  distribution's `docker.io` package and grant user access using `sudo`
- Enough disk for Docker images, Nix packages, and project caches

## Quick start

Double-click **`MOLT.command`** in this checkout, or launch the installer:

```bash
./install.sh
```

An interactive terminal opens the installation wizard. Choose an installation
folder. A fresh installation starts with no connection configured. Follow
**Guided setup** to:

1. Enter the VM address, username, port, and identity file, or select an existing
   SSH alias. The console writes a private SSH configuration for you.
2. Optionally generate a dedicated key and authorize it using an initial working
   login. SSH handles fingerprint confirmation, passwords, and passphrases.
3. Choose your Mac project folder and remote workspace.
4. Prepare the VM. Missing Docker and user access can be configured from the
   console; administrator authentication is requested when needed.
5. Optionally enable automatic activation in new Zsh terminals.
6. Select a Git repository and choose **Start**.

The console performs the lifecycle commands and displays progress, results, and
scrollable logs. Use arrow keys and Enter to select actions, Escape to go back,
and Ctrl-C to cancel an action. SSH, provider authentication, and interactive
shells temporarily use the terminal, then return to the console.

After installation, open the console with `molt`, or double-click
`MOLT.command` in the installation folder. **Maintenance → Open installation
folder in Finder** helps locate the launcher.

If automatic shell activation was not selected, activate the current session:

```bash
source ~/.molt/activate.zsh
molt
```

For scripted installation, use `--non-interactive`. It installs the private
files and tools without opening the wizard:

```bash
./install.sh --non-interactive
```

## Local control center

| Screen | Actions |
| --- | --- |
| Overview | SSH, project, container, and forwarding status |
| Projects | Scan/register, start/stop/restart, logs, ports, shells, environment files, reset |
| Connections | Create/select profiles, use existing aliases, generate/authorize/revoke dedicated keys |
| Guided setup | Choose folders, verify SSH, prepare Docker, enable shell activation |
| OpenCode | Select a project, attach, provider login/logout, available models, server JSON settings |
| Settings | Project folder, remote workspace, OpenCode port range, denied ports, polling, activation |
| Maintenance | Tool versions, diagnostics, VM preparation, shutdown, cleanup, repair, upgrade from a checkout |
| Uninstall | Preview cleanup, complete removal, optional Docker preparation undo, local-only removal |

OpenCode authentication runs in the selected project's remote environment, so
credentials are stored in its contained cache. OAuth callback ports use the
same automatic forwarding as other remote commands. Server settings are edited
as a JSON object and shared by projects on that VM; restart projects to apply
changes. Shell activation takes effect in new terminals. Changes to the
OpenCode base port apply to newly registered projects.

Saved connections referenced by projects, workspaces, or an authorized dedicated
key are retained for cleanup. To change those connection details, clean up their
resources or create a new alias. The Mac checkout remains available after reset.

## Configuration

The console manages the usual settings without editing files. Advanced users
can edit `~/.molt/config`, created from [config.example](config.example):

```bash
MOLT_HOST=''
MOLT_ROOT="$HOME/src"
MOLT_REMOTE_HOME='$HOME/molt'
MOLT_OPENCODE_BASE_PORT=4100
```

`MOLT_HOST` starts empty. Choose a connection in the console to set it to a saved
profile name or an existing SSH alias. A connection name needs an SSH configuration
mapping it to your VM address; the name alone does not create a connection.

**Connections → Use an existing SSH alias** lists named `Host` entries from the
SSH configuration and its included files, showing each alias's effective username,
hostname, and port. Wildcard rules such as `Host *` are defaults, so they are not
selectable entries. Choose **Add a connection** if your VM has no named entry.
The same list is available with `molt connection aliases`.

The remote root uses `$HOME` on the VM. All child directories derive from it.
Each project receives a stable directory and an OpenCode port derived from its
repository path. An optional `MOLT_SSH_CONFIG` can point to an SSH configuration
file stored inside the local installation; an existing `~/.ssh/config` is also
usable as an external prerequisite.

The connection wizard uses `~/.molt/state/ssh/config`, including existing SSH
configuration so recorded external aliases remain available. It stores generated
keys under `state/ssh/keys`. Existing private keys are referenced directly.
[macos/ssh_config.snippet](macos/ssh_config.snippet) is an optional manual setup
example.

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

Use **Overview** to see project/container state and forwarded ports. Choose
**Stop** in a project menu or **Stop all projects** when you are finished.
The equivalent `molt status`, `molt stop`, and `molt down` commands are available
for scripts and direct use.

## Commands

| Command | Description |
| --- | --- |
| `molt` | Open the local control center |
| `molt scan [root]` | List Git repositories |
| `molt inspect [repo]` | Inspect runtime and project files |
| `molt generate-env [repo]` | Create a minimal `devenv.nix` |
| `molt setup` | Prepare the VM |
| `molt bootstrap` | Install missing Docker, grant user access, and prepare the VM |
| `molt config [show\|get\|set]` | Manage configuration |
| `molt connection [action]` | Manage SSH profiles and dedicated access keys |
| `molt shell [status\|enable\|disable]` | Manage optional Zsh activation |
| `molt ports <repo> "3000 4173"` | Save ports in `.molt.yml` and apply forwarding |
| `molt tools` | Show tool versions and locations |
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
| `molt unprepare-vm` | Undo recorded Docker preparation when its daemon is empty |

Stop, reset, logs, and other management operations can use `@<project-id>` to address a saved registration. This
lets the console stop or reset resources after a Mac checkout is moved or deleted.

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
  MOLT.command           Finder launcher for the console
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

Opting into shell activation adds a recorded `.zshrc` entry. Authorizing a
dedicated key adds an exact public-key entry on the VM. Guided Docker preparation
uses VM packages and user groups. The console requests these actions explicitly
and records them for cleanup.

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
    `MOLT_MUTAGEN_BINARY`, `MOLT_OPENCODE_BINARY`, and `MOLT_GUM_BINARY`.
3. Verify executable versions, then switch the `current` release link. Preserve
   configuration, passwords, and project records. A failed upgrade leaves the
   previous release available; a failed fresh installation removes its artifacts.
4. Interactive installations open the local setup wizard. Optional automatic
   activation adds a recorded entry to `.zshrc`; it preserves dotfile symlinks
   and backs up the original content. Explicit session activation is also
   available through `activate.zsh`.
5. Guided VM preparation uses Ubuntu/Debian package tools when Docker or user
   access is missing. An existing VM and initial SSH login are required.
   `molt setup` remains available to check Docker and create the marked root.

Use **Maintenance → Repair this installation** to rerun the bundled installer,
or **Upgrade from a checkout** to select an updated MOLT source folder. Gum,
Mutagen, and OpenCode binaries can be supplied with `MOLT_GUM_BINARY`,
`MOLT_MUTAGEN_BINARY`, and `MOLT_OPENCODE_BINARY`.

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

Choose **Uninstall** in the local console to preview and remove the installation.
The console also offers optional Docker preparation undo and local-only removal
with an exported cleanup inventory.

For command line removal:

```bash
molt-uninstall --yes
```

Without `--yes`, removal asks for confirmation. An installation that never
created remote resources can be removed without connecting to the VM. If the
VM is unreachable and resources are recorded, normal uninstall preserves the
installation for retry.

Normal removal revokes dedicated public keys using their saved authorization
records and removes managed shell activation. It keeps credentials and retry
records if cleanup fails. Initial setup failures can be removed without Docker
when the owned workspace has never created project Docker resources.

To also undo recorded Docker installation/user access:

```bash
molt-uninstall --yes --undo-vm
```

This requires an empty Docker container and volume inventory. It removes only
the Docker package installed by MOLT and the group membership MOLT added.
Docker storage and shared package dependencies are retained.

For explicit local-only removal:

```bash
molt-uninstall --yes --local-only
```

This prints the saved hosts, paths, and Docker identifiers before removing local
records. Save that output for later remote cleanup. It stops owned local helpers
and leaves remote containers, files, and dedicated public-key entries in place.
Generated private keys are removed with the local installation; retain your
initial VM login method for later cleanup.

Existing external tools, Git checkouts, external SSH settings, and shared
Docker base/build caches are preserved. Docker itself is retained unless its
recorded installation is explicitly undone. Close activated shells or remove their
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
bash tests/manage_test.sh
bash tests/tui_test.sh
```

The terminal interaction check uses macOS `expect` and Python 3 to run the real
Gum UI in a pseudo-terminal. It checks keyboard navigation, cancellation and
owned child cleanup, settings, SSH failure, resizing, terminal restoration, and
the guided install-to-uninstall flow. It downloads verified Gum if
`MOLT_GUM_BINARY` is not supplied. SSH and VM package operations in the shell and
terminal checks use isolated test doubles.

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
