# worker

Worker keeps the Mac as the user-facing machine and runs project work inside an isolated Docker container on a remote Ubuntu or Debian VM.

```text
Mac checkout  --Mutagen one-way sync-->  VM project directory
Mac command  --SSH-->  project container
VM port      --SSH local forward-->     Mac localhost
```

The normal workflow is:

```bash
./install.sh
# start a new shell or source the updated ~/.zshrc
worker
```

Remove the Mac installation with:

```bash
worker-uninstall
```

Use `worker-uninstall --yes` for automation. It resets registered projects first, removes Worker-owned host files, removes host dependencies installed by Worker, and removes the PATH block it added to `.zshrc`. The SSH host entry is managed manually, so remove that block from `~/.ssh/config` when it is no longer needed.

The TUI asks for a project root, scans Git repositories below it, and lets you start a repository. Starting a repository:

1. Detects its language and package manager.
2. Creates a minimal `devenv.nix` locally when one is missing.
3. Lets you review and commit that file locally from the TUI.
4. Installs Docker on the VM through SSH when needed.
5. Creates a per-project Mutagen session.
6. Builds a reusable Nix/devenv Docker image.
7. Starts one container for the repository.
8. Starts a project-specific OpenCode server.
9. Forwards OpenCode and declared project ports to the Mac.

## Requirements

Mac:

- Git
- SSH key access to the VM
- Homebrew for automatic Mutagen installation, or Mutagen installed manually
- A local OpenCode client; `install.sh` installs it when `curl` is available

VM:

- Ubuntu or Debian
- Reachable through the configured SSH host
- A user with `sudo`
- Enough disk for Docker images, Nix packages, and project caches

The SSH host must be configured before running `worker setup`. Use the example in [macos/ssh_config.snippet](macos/ssh_config.snippet).

## First setup

Copy the repository somewhere permanent and run:

```bash
./install.sh
```

`install.sh` adds this to `~/.zshrc`:

```bash
export WORKER_HOME="$HOME/.worker"
export PATH="$HOME/.worker/shims:$HOME/.worker/bin:$HOME/.opencode/bin:$PATH"
```

Create or edit `~/.worker/config`:

```bash
WORKER_HOST=oci-dev
WORKER_ROOT="$HOME/Documents/Github"
WORKER_REMOTE_ROOT='$HOME/worker/projects'
WORKER_REMOTE_META_ROOT='$HOME/worker/meta'
WORKER_OPENCODE_BASE_PORT=4100
```

Append [macos/ssh_config.snippet](macos/ssh_config.snippet) to `~/.ssh/config` and replace `HostName`, `User`, and `IdentityFile`.

Check the connection and VM prerequisites:

```bash
worker doctor
worker setup
```

`worker setup` is safe to run repeatedly. It installs Docker and the small set of host packages needed by the worker on Ubuntu or Debian.

## Daily use

```bash
worker
```

Select a repository and choose `start`. After it is running, enter the repository in any shell:

```bash
cd ~/Documents/Github/app
pnpm dev
pnpm test
opencode
git status
nvim .
```

The command shims route supported development commands to the project container. Git, editors, search tools, and ordinary shell commands stay on the Mac. Use `WORKER_LOCAL=1` to bypass routing for one command:

```bash
WORKER_LOCAL=1 pnpm test
```

Use `worker status` to see active containers, synchronization, and forwarded ports. Use `worker stop` or `worker down` when finished.

## Commands

```text
worker                         open the TUI
worker scan [root]             list Git repositories
worker inspect [repo]          inspect detected project files
worker generate-env [repo]     create devenv.nix locally
worker setup                   prepare the VM
worker register [repo]         register a repository without starting it
worker start [repo]            sync, build, and start the project
worker stop [repo]             stop one project
worker up                      start all registered projects
worker down                    stop all active projects
worker status                  show the worker state
worker doctor                  check local and VM prerequisites
worker run <command> [args]    execute inside the current project container
worker oc [args]               attach the local OpenCode client
worker logs [repo]             show the remote OpenCode log
worker reset [repo]            remove project worker state after confirmation
worker reset --all             remove all project worker state after confirmation
```

## Project configuration

Most projects need no worker file. Detection handles Node, Rust, Go, and Python projects. A repository can declare ports in an optional `.worker.yml`:

```yaml
ports:
  - 3000
  - 4173
```

The file is read locally and can be committed with the repository. The worker also forwards newly opened ports while an attached remote command is running.

## Files and ownership

```text
Mac checkout                 source of truth and Git repository
VM ~/worker/projects/<id>    Mutagen mirror
VM ~/worker/meta/<id>        Dockerfile, password, and OpenCode log
VM ~/.config/opencode         provider configuration shared by project containers
VM Docker container          devenv shell, dependencies, processes, and tools
VM Docker volume             language and package caches
~/.worker/projects/<id>      local project registry and worker state
```

Mutagen uses one-way Mac-to-VM synchronization. `.git`, dependencies, build output, virtual environments, and common caches are excluded from the mirror.

The generated `devenv.nix` is written and committed on the Mac. The VM only consumes the synchronized repository.

## Resetting a project

```bash
worker reset
```

This removes the project container, image, Mutagen session, forwarded ports, and local worker state after confirmation. It does not delete the Mac checkout or its Git history.

Reset also removes the remote project mirror, project metadata, and the per-project Docker cache volume. Shared VM Docker packages and the shared OpenCode configuration remain available for other projects.
