# molt

One remote OpenCode workspace per Git repository, managed from your Mac.

MOLT synchronizes your repository with an Ubuntu or Debian VM, runs an OpenCode
server in a dedicated Ubuntu 22.04 Docker container, and connects your local
OpenCode terminal interface to it. Running `opencode` inside a registered
repository automatically starts its workspace, waits for the server, and attaches.

```text
Mac repository ◀── Mutagen (two-way-safe) ──▶ VM workspace ──▶ repo container
Mac OpenCode   ─── authenticated SSH tunnel ────────────────▶ OpenCode server
```

## Start

Double-click **MOLT.command**, or run:

```bash
./install.sh
```

The installer lets you choose an installation folder and offers automatic
activation in new Zsh terminals immediately, before VM setup. Accept that option
to reopen MOLT by running `molt` in a new terminal. In an existing terminal,
run `source ~/.molt/activate.zsh` (using your chosen installation folder).

You can also reopen it directly with `~/.molt/bin/molt`, or double-click
`MOLT.command` in the installation folder, when shell activation is disabled.

The setup wizard then configures SSH and prepares Docker on the VM.
Existing SSH aliases can be selected directly; MOLT can also create and authorize
a dedicated SSH key using an initial working login.

Then choose **Projects → Scan / add repositories** and register your repository.
In a terminal inside that repository:

```bash
source ~/.molt/activate.zsh  # use your chosen installation folder
opencode
```

The first launch builds the container. Later launches reuse it and reconnect.
Stopped workspaces start automatically. Subdirectories and nested registered
repositories select the closest registered workspace.

Open `opencode` in multiple local terminals inside the same repository to use
independent sessions on its shared server. Connection setup is serialized; the
clients then run concurrently through the same SSH tunnel.

Quitting OpenCode or closing its terminal stops the work that terminal started,
including work in sessions created with `/new` or selected later. Other terminals
keep running, and conversation history remains available. A session being used
by one terminal can be viewed elsewhere, but another terminal cannot modify it
until its owner exits. Use a new session for independent work.

Cleanup requires a working connection. Sudden power loss, a hard process kill,
or a lost network connection can leave remote work running; reconnect and abort
it in OpenCode. Changing shared configuration or credentials can still reload
the server and interrupt attached clients.

Only the `opencode` command is intercepted. Commands such as `npm`, `python`,
`cargo`, and `git` use your ordinary local tools. Outside registered repositories,
`opencode` runs locally with your normal configuration, accounts, and session
history. Clients attached to a VM also retain your saved model variants and UI
preferences.
Use `MOLT_LOCAL=1 opencode` to run locally inside a registered repository.
OpenCode's explicit `attach`, `serve`, `web`, help, and
version commands retain their normal client behavior.

OpenCode provider commands also work inside a registered repository:

```bash
opencode auth login
opencode models
opencode run 'Explain this project'
```

These run inside its container. Provider credentials are shared by all repository
containers using the same MOLT workspace root on the VM. Run `opencode auth login`
once per provider from any registered repository; `opencode auth logout` affects
every repository using that shared login. Credentials live in `auth/auth.json`
under the owned VM root and survive removing or resetting an individual project.
Complete uninstallation removes them.

Session history and other application data remain in each project's VM cache.
After changing credentials, reconnect to OpenCode so MOLT reloads any server with
cached provider settings. Mac provider credentials and shell API-key environment
variables are not copied to the VM.

Before starting or attaching, MOLT copies your local global OpenCode configuration
to the shared VM configuration directory.
Settings, `AGENTS.md`, custom agents, commands, skills, tools, and plugins are
included. `OPENCODE_CONFIG_DIR` takes precedence over
`${XDG_CONFIG_HOME:-~/.config}/opencode` when choosing the local directory.

The Mac is the source of truth: updates and deletions replace the VM copy on the
next launch. MOLT validates JSONC settings and checks the upload before installing
them, retains the previous configuration for recovery, and reloads a project's
server when its configuration changes. If the local directory is absent, the
existing VM configuration is retained. Generated dependencies and lockfiles stay
on the VM; Mac `node_modules` are excluded.

**OpenCode → Edit server settings** edits the VM copy. When local configuration
sync is active, change your local files to make lasting changes. VM-only edits
are replaced on the next launch. Restart your local OpenCode after editing its
configuration so local sessions load the changes too.

## Requirements

- macOS with Bash, Zsh, Git, SSH, `curl`, `tar`, `unzip`, `shasum`, and Perl.
- An Ubuntu or Debian VM with a working SSH login, Bash, and GNU `realpath`.
  Its SSH server must permit local TCP forwarding for the OpenCode connection.
- Docker usable by the SSH user. The wizard can install `docker.io` and configure
  access through `sudo`.
- Internet access for the initial tool downloads and Docker build.

The installer downloads private, checksum-verified copies of Mutagen 0.18.1
and OpenCode 1.18.34 when suitable external tools are unavailable.
OpenCode's server version is pinned in the image. The container includes Git,
curl, CA certificates, and checksum-verified Node.js 24.21.0 with npm and npx for
local MCP servers. Project toolchains and dependency installation are not
generated by MOLT. Browser binaries required by browser MCP servers are installed
separately.

## Terminal control center

Run `molt` to open a persistent dashboard. It shows local CPU, memory, disk, network
rates, uptime and load alongside your VMs, MOLT-owned Docker containers, project
synchronization and OpenCode server health. CPU history appears as sparklines.
The selected VM's Docker panel includes per-container CPU and memory usage.

Metrics refresh every three seconds, independently of keyboard input. Each VM is
probed concurrently through authenticated SSH; no monitoring agent is installed.
An unreachable VM shows **unknown** project health and marks the previous sample
as stale. Saved project activation is never presented as observed container health.
SSH probes use batch authentication and trusted host keys; press `c` to complete
an interactive login when needed. Docker counts cover resources owned by this
MOLT installation. Local disk usage covers the filesystem containing `MOLT_HOME`;
VM disk usage covers the remote user's home filesystem.

Transfers animate when Mutagen reports staging progress. Actions stream output
into the lower panel and record their result in the activity feed. Log views poll
the latest 200 server lines, keep your scroll position and resume following with
`G`. The feed keeps 200 session events; action output is retained in
`MOLT_HOME/state/ui/last.log`. Monitoring ends when you quit; project servers and
existing synchronization continue independently.

| Key | Action |
| --- | --- |
| `h` / `l`, Tab / Shift-Tab | Move panel focus |
| `j` / `k`, arrows; `g` / `G`; Ctrl-D / Ctrl-U | Move selection or scroll |
| `1`–`4` | Focus VM, system panels, projects, activity/output |
| `[` / `]` | Select a VM |
| `/`, Enter, Escape | Filter projects, apply, clear |
| Enter | Inspect selected project |
| `s`, `S`, `r` | Start, stop, restart selected project |
| `o` | Attach OpenCode inside the embedded terminal pane |
| `L`, `a`, `y` | Server logs, activity, synchronization details |
| `c`, `d`, `n` | Connect VM, diagnostics, register a repository |
| `:` or Ctrl-P | Open all management commands |
| `R`, `p` | Refresh now, pause/resume polling |
| `?`, `q` | Help, quit |
| Ctrl-] in a session | Open session controls; confirm before ending the process |

The footer shows shortcuts for the focused panel or open dialog. **Commands** and
**Help** stay visible on the dashboard, including in compact terminals. Press `?`
for grouped navigation, workspace, monitoring, and session shortcuts; use arrows
or `j`/`k` to scroll through the help.

Mouse clicks select projects and focus panels; the wheel moves or scrolls.
Stop/restart actions ask for confirmation. Escape cancels a running action after
confirmation; quitting during an action also asks before cancelling it.

The command palette opens native Bubble Tea management screens. Scanning,
registration, connections, setup, settings, maintenance, and removal stay inside
the control center. Command labels are concise, with an explanation below the
selected item. Menus show the visible item range; Home/End or `g`/`G` jump to the
first or last item. Press `i` to read full command descriptions, setting values,
repository paths, or SSH destinations. Forms use Tab/Shift-Tab to switch fields
and Enter to continue or save. Escape returns to the previous screen;
confirmations default to cancel.
Long confirmations scroll with arrows or `j`/`k`, keeping the confirm and cancel
controls visible. Scan results show repository names and relative paths.
`molt menu <screen>` opens the corresponding native screen.

SSH authentication, key creation, administrator prompts, provider authentication,
and OpenCode run in an embedded terminal pane with the MOLT header and controls
still visible. Keys, including Escape and Ctrl-C, go to the child application;
Ctrl-] opens MOLT's session controls. Terminal size changes are forwarded to the
child. Interactive session transcripts and password input are not saved to action
logs. Background operations use batch SSH authentication and offer an embedded
login when authentication is needed. The JSONC server-settings editor uses Ctrl-S
to save and Escape to discard, with confirmation for both.

| Screen | Actions |
| --- | --- |
| Overview | Connection and workspace status |
| Projects | Register, open OpenCode, start, stop, restart, logs, synchronization, remove |
| Connections | SSH profiles, existing aliases, dedicated keys |
| Guided setup | Configure SSH, prepare Docker, enable shell activation |
| OpenCode | Attach, provider authentication, models, server configuration |
| Settings | Folders, OpenCode port range, animations, shell activation |
| Maintenance | Update MOLT, diagnostics, VM preparation, repair, upgrade from checkout, cleanup |
| Uninstall | Complete removal, optional Docker preparation reversal, local-only removal |

The dashboard adapts to terminal size: wide terminals show three system panels;
narrow terminals combine the infrastructure overview, and very small terminals
prioritize the project list. Rounded borders, restrained cyan accents and explicit
focus markers remain readable with color disabled. Disable motion in **Settings →
Animations**, or save the preference from the CLI:

```bash
molt config set MOLT_ANIMATIONS 0
```

This disables animated indicators while preserving live metrics and action output.
`NO_COLOR=1` also disables color and decorative motion.

Source installations rebuild the dashboard automatically with **Go 1.26 or newer**,
including when `bin/molt-tui` already exists. Run `./install.sh --non-interactive`
to install changes from your local checkout; `molt update` downloads and installs
the published GitHub `main` branch. Neither needs a separate build command.

The resulting executable needs no Go runtime. Packaged releases can use their
bundled executable without Go. A packaged executable can also be supplied with
`MOLT_TUI_BINARY=/path/to/molt-tui ./install.sh`. Interactive installation uses the
same Bubble Tea interface. The previous shell UI and its Gum dependency have
been removed.

## Synchronization and connections

Synchronization is bidirectional: edits made by OpenCode return to your Mac,
including newly created files and Git changes. Dependency directories such as
`node_modules`, `.venv`, `target`, and build output are excluded. Git metadata is
included so the server can inspect normal repository history and changes.

Mutagen's `two-way-safe` mode preserves conflicting changes rather than silently
overwriting either side. **Projects → Synchronization**, or `molt sync <repo>`,
shows conflicts. Resolve them before restarting or removing the workspace. MOLT
checks for conflicts and synchronization problems before deleting its mirror.

Each container uses Docker's bridge network. Its server listens on port 4096
inside the container, published to a project-specific **127.0.0.1** port on the VM.
MOLT forwards that port over its private SSH connection and uses a generated
password for OpenCode authentication. Application port discovery and forwarding
have been removed.

The base port defaults to 4100, with 500 ports available. Registration avoids
assigning an existing workspace's port again. A listener belonging to another
application causes an explicit connection error. Change the base port before
registering a project when the default range is unavailable.

## CLI

```bash
./install.sh --non-interactive       # install without opening the wizard
source ~/.molt/activate.zsh
molt connection use my-vm           # select an existing SSH alias
molt bootstrap                      # prepare Docker and the owned VM workspace
molt register /path/to/repo
molt start /path/to/repo
molt oc --continue                  # attach from this repo; start if necessary
molt stop /path/to/repo
molt logs /path/to/repo
molt sync /path/to/repo
molt status
molt doctor
```

Use `molt help` for the command list. Set `MOLT_HOME` when installing into a custom
folder. `molt shell enable` adds a recorded activation line to `.zshrc`;
`molt shell disable` removes it while preserving user edits.

## Clean removal

```bash
molt-uninstall --yes
```

MOLT keeps installation manifests, project records, exact dedicated SSH keys, and
Docker ownership labels. Complete removal stops owned clients and servers, flushes
server edits to the Mac, removes synchronization sessions, project containers and
images, VM mirrors, credentials, caches, SSH helpers, and the local installation.
It restores its recorded shell activation change. Mac repositories are retained.

Cleanup failures preserve the installation and retry records. Reconnect to the VM
or resolve synchronization problems and retry. `molt reset <repo>` removes just
that project's resources; `molt reset --all` removes all project resources.

Registration and SSH tests do not prepare a project or VM. MOLT records setup as
untouched, started, or complete, including attempts that may have changed the VM
before failing. Projects that were only registered can be removed without SSH;
an installation with no recorded VM changes can also be uninstalled offline.
Run `molt setup-state [repo]` to inspect this recorded state without contacting a VM.

`molt-uninstall --yes --undo-vm` also reverses MOLT-recorded Docker installation
and user access when the daemon has no containers or volumes. Existing Docker
installations and external tools are preserved. Shared Docker base images, build
cache, and system Docker storage remain under Docker's management; MOLT never runs
a broad Docker prune.

When the VM is unavailable, choose **Remove project locally only** in the TUI or
run `molt reset <repo> --local-only` (`--all` also works). This terminates the
project's local synchronization without flushing remote edits and removes its
local registration, so `opencode` no longer routes that project to the VM.

`molt-uninstall --local-only` removes the Mac installation. If VM or project changes
are recorded, local-only removal warns before confirmation that containers may
remain running and that VM workspaces, images, caches, provider credentials, SSH
authorization, and preparation may remain. Partial setup and older resource
records also trigger this warning. `--yes --local-only` explicitly accepts it for
non-interactive uninstall; project removal uses `MOLT_ASSUME_YES=1`.

Mac repositories are kept. Local-only removal discards the relevant local cleanup
records, leaving VM cleanup to you. No inventory file or cleanup script is saved.
Complete removal is the default when VM changes are recorded.

## Upgrading

Choose **Maintenance → Update MOLT** to download and install the latest `main`
from `DerekNGAI/molt`, then select **Restart control center** to load the updated
interface in the same terminal. The update streams its progress and supports
cancellation and retry. It requires internet access and Go 1.26 or newer to build
the downloaded interface. Synchronization may pause briefly during installation.
The same update is available from the CLI with `molt update`.

To install from a local source checkout, use **Maintenance → Upgrade from checkout**.
Run the installer with your existing `MOLT_HOME`. It preserves configuration,
credentials, and ownership records. Existing contained projects rebuild into the
plain Ubuntu OpenCode container on their next launch while retaining their mirror
and session history. Projects switch to the shared VM credential store on their
next launch. Authenticate once from any registered repository to populate it;
previous per-project credential files remain in their caches for recovery until
those projects are reset or removed. See [MIGRATION.md](MIGRATION.md) for details
and older layouts.

## Development

```bash
bash tests/molt_test.sh
bash tests/session_test.sh
bash tests/lifecycle_test.sh
bash tests/manage_test.sh
bash tests/offline_test.sh
bash tests/tui_test.sh
bash tests/dashboard_test.sh
bash tests/integration_test.sh
# Dashboard tests, static checks and build:
(cd tui && go test -race ./... && go vet ./... && CGO_ENABLED=0 go build -trimpath -o ../bin/molt-tui .)
```

The shell tests use isolated tool doubles. The dashboard Go tests cover telemetry,
sync conflicts, safe terminal text, filtering, stable selection, compact layouts
and contextual controls, grouped help, readable menu details and confirmation
scrolling, cancellation prompts, native management routing, complete scan results,
small-terminal validation, and real embedded PTY input, queries and resize.
The TUI tests build Bubble Tea and use an `expect` pseudo-terminal with isolated
SSH/tool doubles. They check scanning and registration, aliases, password input,
cancellation, resize, terminal restoration, settings, and the guided installation
through uninstallation flow. The opt-in integration test requires Docker and creates a disposable SSH
host with its own Docker daemon; it checks real builds, synchronization in both
directions, server health, stop/restart, and complete removal.
