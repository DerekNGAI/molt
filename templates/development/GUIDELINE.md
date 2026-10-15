# Repository development menu

Reuse commands already declared in manifests, lockfiles, CI, and repository scripts. Order available setup, dev, test, check, and build actions first, followed by useful declared extras. Omit missing commands. Use short, readable labels.

Use devenv files for toolchains and `.molt/development.json` version 1 for actions, ports, and optional Android. Actions use an argv array and a repository-relative cwd. Task actions run in the foreground; service actions use Molt's persistent runner. An explicit repository shell script is ordinary trusted repository code, not generated host shell interpolation.

`menu --list` lists entries; `menu <action-id>` runs one and preserves its exit code. Ctrl-C interrupts the foreground task. Exiting a menu closes its client. Use Molt Stop to stop persistent services. Display the actual forwarded loopback URLs returned by Molt.

The local Molt menu also offers ports, Android, logs, cache preview/cleanup, and workspace lifecycle. Android is disabled unless explicitly enabled for that repository. Cleanup requires a displayed inventory and its current revision; stop preserves source, dependencies, databases, and device data.
