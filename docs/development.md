# Remote repository development

Install Molt, configure its SSH connection, and register a repository in **Projects**.
Open its **Development menu**, press **D** on the dashboard, or run `menu` from the
repository or one of its subdirectories. Nested registrations select the nearest
repository. Outside registered repositories, `menu` uses an existing local menu
executable. `MOLT_LOCAL=1 menu` also chooses that local command.

## Prepare and work

Choose **Prepare** or run `molt dev . prepare`. Molt synchronizes the repository,
inspects its development files, generates missing candidates, validates them,
and builds the toolchain on the VM. First builds can take several minutes.
Progress appears in the terminal; failure retains output and ownership records
for retry. Ordinary registration and OpenCode startup need no development profile
or provider and do not trigger generation.

Generation uses the VM's existing OpenCode provider/model configuration. Authenticate
through `opencode auth login` inside the registered repository when generation
needs a provider. Local provider secrets are not copied to the VM. Existing
`devenv.nix`, `devenv.yaml`, `devenv.lock`, profile and menu files remain the source
of truth; generation writes only missing candidates. Molt compares source identities
before promotion and retains the working runtime on generation/build failure.
Unchanged preparation reuses its revision without calling AI again. Close active
work before rebuilding: an active or unknown OpenCode/development session can
block replacement of its runtime.

The shipped [menu guideline](../templates/development/GUIDELINE.md) reuses existing
repository scripts. It lists available setup, development, test, check and build
actions first, then repository-specific actions. Missing commands are omitted.

```bash
molt dev . prepare          # prepare missing configuration and toolchain
molt dev . menu             # same development screen as local `menu`
molt dev . shell            # shell with the prepared remote toolchain
molt dev . run setup        # run a declared action
molt dev . run test
molt dev . start            # start declared persistent services and app forwards
molt dev . logs             # bounded service logs; add a service ID to select one
molt dev . stop             # stop services/device/viewer, preserve persistent data
```

Inside the prepared remote environment, `menu --list` lists actions and
`menu <action-id>` executes one. Task exit codes are preserved; Ctrl-C interrupts
the foreground task. Service actions use managed processes. Closing a menu or
client preserves services; **Stop** explicitly stops them. Normal `molt stop` and
`molt restart` also stop development services and local helpers before stopping
the workspace writer.

## Repository profile

Devenv files define the toolchain. `.molt/development.json` contains only Molt menu,
port and Android metadata. An example for a repository with matching npm scripts:

```json
{
  "version": 1,
  "name": "Web application",
  "actions": [
    {"id":"setup","label":"Install dependencies","kind":"task","argv":["npm","ci"],"cwd":"."},
    {"id":"dev","label":"Start development","kind":"service","argv":["npm","run","dev","--","--host","0.0.0.0"],"cwd":"."},
    {"id":"test","label":"Run tests","kind":"task","argv":["npm","test"],"cwd":"."}
  ],
  "ports": [
    {"id":"web","label":"Web application","service":"dev","container_port":3000,"local_port":3000,"scheme":"http"}
  ],
  "android": {"enabled":false}
}
```

Use commands that exist in your repository. Arguments execute directly; shell
operators require an explicit shell command in `argv`. Working directories default
to `.` and must stay inside the repository, including after resolving symlinks.
Unknown fields/versions, duplicate IDs, invalid ports, escaping directories and
invalid arguments are rejected. A missing/invalid profile leaves Molt's native
management controls available with a reason.

IDs use lowercase letters, numbers and hyphens, begin with a letter, and contain
at most 32 characters. Names/labels contain 1–80 characters. The limits are 32
actions, 16 ports, 64 arguments per action and 4096 bytes per argument. Arguments
cannot contain NUL, CR or LF. Ports refer to service actions; container ports are
unique and in 1–65535, excluding OpenCode's 4096. Preferred local ports are in
1024–65535; schemes are `http` or `https`.

## Local application access

Choose **Ports** to see actual URLs, copy them, or open one in your browser.
`molt dev . ports --json` returns the same observations and `molt dev . open web`
checks/restores the selected mapping and opens its URL.

Applications publish to VM `127.0.0.1` and use private SSH tunnels to Mac
`127.0.0.1`. Molt tries the preferred local port, then up to 500 valid candidates
when listeners or other repositories already use it. Use the displayed URL;
`http://127.0.0.1:3000/` is a preference, not a promise. HTTP and WebSocket traffic
share the same TCP tunnel. A service must listen on `0.0.0.0` in its container;
container-only localhost listeners cannot be reached through a Docker publication.

Reconnecting restores recorded forwards for desired running services alongside
OpenCode's forward. App stop cancels app/device mappings and preserves the OpenCode
connection. Disconnected or unavailable observations show unknown with a reason.
`status --json`, `ports --json`, and `cache --json` never prepare/start/repair the VM.

## Per-repository Android

Android starts disabled. In **Android**, choose **Check host** first. The ARM64
candidate is the pinned Redroid image; standard Linux ARM AVD is unsupported.
Redroid needs compatible native ARM64 hardware, 4 KB pages, Binder/binderfs and
applicable memfd/ashmem support. A positive readiness state requires observed boot
and ADB, not a saved active flag.

Choose **Enable** for the repository, then **Prepare host** only after checking its
diagnostics. Host preparation is interactive and records its changes. Molt never
automatically replaces the kernel. Unsupported hosts remain unsupported until the
required host features are available.

```bash
molt dev . android check
molt dev . android enable
molt dev . android prepare-host
molt dev . android start
molt dev . android view
molt dev . android stop
```

Each repository has separate Android network/data ownership. The device has no
repository/provider/config mounts. Only Android receives its required elevated
container privileges; a privileged Android container shares the VM kernel and is
not a strong security boundary against the host. The development workspace retains
the VM user's UID/GID. Flutter uses the assigned private device.

The viewer lazily acquires checked private scrcpy/ADB tools. It uses a dedicated
local ADB server port and explicit device serial; Molt does not stop a global ADB
server on port 5037. A running viewer keeps its recorded executable/dependencies
through Molt updates. Closing it or stopping the project cleans its verified local
helpers and tunnels. **Disable** stops the device/viewer before updating the checked
repository profile.

**Reset Android data** (`molt dev . android reset --yes`) destroys only this
repository's device data. Stop/restart preserves it. Review the confirmation before
resetting.

## Storage, cleanup and retries

| Resource | Location / lifetime |
| --- | --- |
| Local project/helper records | `$MOLT_HOME/projects/<id>/development.json`, retained for cleanup retries |
| Private local viewer tools | `$MOLT_HOME/tools/development/`, installation-owned releases |
| VM controller/ownership records | `<remote-root>/state/development/` |
| Per-project metadata/active profile | `<remote-root>/meta/<id>/development/` |
| Service/device/build data | `<remote-root>/cache/<id>/development/`, outside source synchronization |
| Shared private Nix store | `<remote-root>/cache/development/nix/`, shared installation-owned storage |
| Recorded Android host preparation | `<remote-root>/state/android-preparation/` |

Choose **Cache** to preview recorded unused build outputs, images and Nix roots.
It excludes source, credentials, databases, Android userdata and live runtime data.
Cleanup rechecks the preview revision and live references under locks. If anything
changed, request a new preview and confirm again.

```bash
molt dev . cache --json
molt dev . clean-cache --yes --revision <revision-from-that-preview>
molt cleanup-inventory
```

Project removal stops writers/helpers and flushes source synchronization before
deleting owned resources/data and the mirror. Sync conflicts block deletion;
resolve them in Molt and retry. Failed cleanup retains registration and exact
resource records. **Local-only removal** can leave VM resources running and loses
project cleanup records; review its inventory and warning first.

Full uninstall cleans projects before shared private tooling/store. `--undo-vm`
reverses only recorded unused preparation; changed/in-use packages/modules remain
with explanations and retry records. Molt does not use broad Docker prune, system
Nix GC, or remove unrelated processes/packages. `molt local-down` closes owned local
helpers/tunnels and preserves remote data. After interrupted setup or cleanup,
inspect status/inventory and retry through Molt.
