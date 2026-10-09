#!/usr/bin/env bash
# Exercise the real startup orchestration without SSH, Docker, or an installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-startup.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/bin/_molt.sh"
source "$ROOT/bin/_docker.sh"
source "$ROOT/bin/_opencode.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf 'molt: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
managed_file() { [[ ! -L "$1" ]] || fail 'symlinked state'; }
write_value() { printf '%s\n' "$2" >"$1"; }
read_value() { local value=''; [[ ! -f "$1" ]] || IFS= read -r value <"$1"; printf '%s\n' "$value"; }
export MOLT_HOME="$TMP/home" PROJECT_STATE="$TMP/project" PROJECT_ID=aaaaaaaaaaaa PROJECT_NAME=app MOLT_HOST=fixture-vm
export MOLT_UI_PROGRESS="$TMP/progress"
export MOLT_RUNTIME_VERSION
mkdir -p "$PROJECT_STATE" "$MOLT_HOME/state/tmp"
load_project_state() { PROJECT_ACTIVE=1; PROJECT_RUNTIME_VERSION="$MOLT_RUNTIME_VERSION"; }
load_project() { load_project_state; }
ssh_up() { :; }
prepare_project_dirs() { :; }
start_sync() { :; }
sync_opencode_config() { :; }
sync_password() { :; }
ensure_container() { startup_progress 'Starting container'; return "${FAIL_CONTAINER:-0}"; }
wait_opencode_ready() { :; }
forward_opencode_port() { :; }

launch() { bash -c "$(declare -f); set -euo pipefail; ensure_project_container"; }
launch 2>"$TMP/launch.log"
[[ "$(<"$TMP/launch.log")" == *'app is ready'* ]] || fail 'warm attachment reports no readiness'
[[ "$(<"$MOLT_UI_PROGRESS")" == *'app is ready'* ]] || fail 'dashboard has no persistent startup stage'
[[ ! -e "$PROJECT_STATE/start.lock" ]] || fail 'startup left its lock'
[[ "$(<"$TMP/launch.log")" != *'Building'* ]] || fail 'warm attachment claims to build'

rc=0
FAIL_CONTAINER=42 launch 2>"$TMP/failure.log" || rc=$?
[[ "$rc" == 42 ]] || fail "startup changed failure status to $rc"
[[ "$(<"$TMP/failure.log")" == *'Failed during:'* ]] || fail 'failed startup lost stage context'
[[ "$(<"$TMP/failure.log")" != *'app is ready'* ]] || fail 'failed startup reports readiness'
[[ ! -e "$PROJECT_STATE/start.lock" ]] || fail 'failed startup left its lock'

# The full first-launch orchestrator must expose Docker's stdout through stderr.
export PROJECT_PATH="$TMP/repo" PROJECT_LAYOUT=2 PROJECT_IMAGE=fixture-image PROJECT_REMOTE_META="$TMP/meta"
export PROJECT_REMOTE_HOME="$TMP/vm" PROJECT_REMOTE_PATH="$TMP/vm/repo"
mkdir -p "$PROJECT_PATH" "$PROJECT_REMOTE_META" "$TMP/bin"
cat >"$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
[[ "$1" == build ]] || exit 99
printf 'Downloading Ubuntu layer fixture\n'
exit "${FAIL_BUILD:-0}"
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
cmd_setup() { :; }
set_remote_paths() { :; }
save_project() { :; }
upload_file() { :; }
remote_run() { bash -c "$1"; }
build_launch() {
  bash -c "source \"\$0\" help >/dev/null; $(declare -f log die managed_file write_value read_value load_project_state load_project ssh_up prepare_project_dirs start_sync sync_opencode_config sync_password ensure_container wait_opencode_ready forward_opencode_port cmd_setup set_remote_paths save_project upload_file remote_run); set -euo pipefail; with_project_setup_lock start_loaded_project" "$ROOT/bin/molt"
}
build_launch >"$TMP/build.stdout" 2>"$TMP/build.log"
[[ ! -s "$TMP/build.stdout" ]] || fail 'startup polluted stdout'
[[ "$(<"$TMP/build.log")" == *'Downloading Ubuntu layer fixture'* ]] || fail 'Docker build output was swallowed'
rc=0
FAIL_BUILD=23 build_launch 2>"$TMP/build-failure.log" || rc=$?
[[ "$rc" == 23 ]] || fail "build failure changed status to $rc"
[[ "$(<"$TMP/build-failure.log")" == *'Failed during: Building container image'* ]] || fail 'build failure lost its stage'
[[ "$(<"$TMP/build-failure.log")" != *'app is ready'* ]] || fail 'failed build reports readiness'

# Verify quiet-wait feedback and real process-group cancellation, including a held lock.
quiet_step() { startup_progress 'Synchronizing repository files'; sleep 30 & wait; }
declare -f >"$TMP/functions.sh"
perl - "$TMP" <<'PERL'
use strict;
use warnings;
use POSIX qw(setsid WNOHANG);
use Time::HiRes qw(time sleep);
my $root = $ARGV[0];
my $lock = "$ENV{PROJECT_STATE}/start.lock";
my $work = "$ENV{MOLT_HOME}/state/tmp";
sub read_text {
  open my $file, '<', $_[0] or return '';
  local $/;
  return <$file> // '';
}
for my $held (0, 1) {
  if ($held) {
    mkdir $lock or die $!;
    open my $owner, '>', "$lock/pid" or die $!;
    print $owner "$$\n";
    close $owner;
  }
  my $log = "$root/" . ($held ? 'lock-wait.log' : 'quiet-wait.log');
  my $pid = fork();
  defined $pid or die $!;
  if (!$pid) {
    setsid() != -1 or die $!;
    open STDERR, '>', $log or die $!;
    exec 'bash', '-c', 'source "$1/functions.sh"; set -euo pipefail; with_project_setup_lock quiet_step', 'fixture', $root;
    die $!;
  }
  my $reaped = 0;
  eval {
    my $deadline = time + 9;
    while (read_text($log) !~ /Waiting for progress:/) {
      $reaped = waitpid($pid, WNOHANG) == $pid;
      !$reaped && time < $deadline or die "no quiet-wait feedback: " . read_text($log);
      sleep .05;
    }
    my $expected = $held ? 'Waiting for workspace access' : 'Synchronizing repository files';
    index(read_text($log), $expected) >= 0 && read_text($log) =~ /elapsed/ or die 'wrong wait stage';
    kill 'TERM', -$pid;
    $deadline = time + 3;
    while (waitpid($pid, WNOHANG) != $pid) {
      time < $deadline or die 'cancellation did not finish';
      sleep .05;
    }
    $reaped = 1;
    $? != 0 or die 'cancelled startup succeeded';
    $deadline = time + 3;
    while (1) {
      opendir my $dir, $work or die $!;
      my @workers = grep { /^start\./ } readdir $dir;
      closedir $dir;
      last unless @workers;
      time < $deadline or die 'cancellation left its temporary worker';
      sleep .05;
    }
    (-d $lock ? 1 : 0) == $held or die 'cancellation removed another startup lock or retained its own';
    !$held || read_text("$lock/pid") eq "$$\n" or die 'cancellation replaced another startup owner';
  };
  my $error = $@;
  if (!$reaped) { kill 'KILL', -$pid; waitpid($pid, 0); }
  die $error if $error;
  if ($held) { unlink "$lock/pid"; rmdir $lock; }
}
PERL
printf 'molt startup tests: ok\n'
