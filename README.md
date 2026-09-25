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
- Generates a small `devenv.nix` when a project does not have one.
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
- [Mutagen](https://mutagen.io/)
- [OpenCode](https://opencode.ai/)
- Homebrew and `curl` if you want `install.sh` to install missing tools

### Remote VM

- Ubuntu or Debian
- A user with `sudo`
- Docker, installed automatically by `molt setup`
- Enough disk for Docker images, Nix packages, and project caches

## Quick start

1. Configure an SSH host using [macos/ssh_config.snippet](macos/ssh_config.snippet).
   Replace `HostName`, `User`, and `IdentityFile` for your VM.
2. Install molt from this checkout:

   ```bash
   ./install.sh
   source ~/.zshrc
   ```

3. Edit `~/.molt/config` if the defaults do not match your setup.
4. Check the connection and prepare the VM:

   ```bash
   molt doctor
   molt setup
   ```

5. Open the project picker:

   ```bash
   molt
   ```

Choose a project and select **start**. molt will sync the checkout, build its
environment, start the container, and forward its ports.

## Configuration

`install.sh` creates `~/.molt/config` from [config.example](config.example):

```bash
MOLT_HOST=oci-dev
MOLT_ROOT="$HOME/Documents/Github"
MOLT_REMOTE_ROOT='$HOME/molt/projects'
MOLT_REMOTE_META_ROOT='$HOME/molt/meta'
MOLT_OPENCODE_BASE_PORT=4100
```

The remote root values use `$HOME` on the VM. Each project receives a stable
directory and an OpenCode port derived from its repository path.

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

## Where files live

```text
Mac checkout              source of truth and Git repository
VM ~/molt/projects/<id>   Mutagen mirror
VM ~/molt/meta/<id>       Dockerfile, password, and OpenCode log
VM ~/.config/opencode     shared OpenCode provider configuration
VM Docker container       devenv shell, dependencies, and processes
VM Docker volume           language and package caches
~/.molt/projects/<id>     local project registry and state
```

Mutagen synchronizes the checkout one way from the Mac to the VM. Git data,
dependencies, build output, virtual environments, and common caches stay out
of the mirror. Generated `devenv.nix` files are written and committed on the
Mac.

## Reset and uninstall

Reset a project when you want to remove its container, image, Mutagen session,
forwarded ports, remote mirror, and local state:

```bash
molt reset
```

This keeps the Mac checkout and its Git history. To remove the complete Mac
installation and molt-managed dependencies:

```bash
molt-uninstall --yes
```

The SSH host block in `~/.ssh/config` is managed manually and should be
removed separately when it is no longer needed.

## Development

Run the shell checks from the repository root:

```bash
bash tests/molt_test.sh
bash tests/lifecycle_test.sh
```
