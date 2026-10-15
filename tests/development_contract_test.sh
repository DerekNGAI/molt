#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${MOLT_DEVELOPMENT_TEST_BINARY:?supply the current compiled molt-tui}"
python3 - "$ROOT" "$MOLT_DEVELOPMENT_TEST_BINARY" <<'PY'
import copy, json, os, pathlib, shutil, subprocess, sys, tempfile

root, binary = pathlib.Path(sys.argv[1]), sys.argv[2]
with tempfile.TemporaryDirectory(prefix='development-contract-', dir=os.environ.get('TMPDIR')) as tmp:
    repo = pathlib.Path(tmp) / 'repo with spaces $(literal)'
    (repo / '.molt').mkdir(parents=True)
    profile = repo / '.molt/development.json'
    base = {'version': 1, 'name': 'Node fixture', 'actions': [
        {'id': 'test', 'label': 'Run tests', 'kind': 'task', 'argv': ['node', '-e', 'process.exit(0)', '$(touch escaped)']},
        {'id': 'dev', 'label': 'Development server', 'kind': 'service', 'argv': ['npm', 'run', 'dev'], 'cwd': '.'}],
        'ports': [{'id': 'web', 'label': 'Web application', 'service': 'dev', 'container_port': 3000, 'local_port': 3000, 'scheme': 'http'}]}

    def call(args, code=0):
        result = subprocess.run([binary, 'development-tools', *map(str, args)], capture_output=True, text=True)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        if code:
            assert not result.stdout, ('failed helper polluted JSON stdout', result.stdout)
            return None
        return json.loads(result.stdout)

    def validate(data, code=0):
        profile.write_text(json.dumps(data))
        return call(['validate', profile], code)

    normalized = validate(base)
    assert normalized['android'] == {'enabled': False}
    assert normalized['actions'][0]['cwd'] == '.'
    assert normalized['actions'][0]['argv'][-1] == '$(touch escaped)'
    assert not (repo / 'escaped').exists()
    empty = validate({'version': 1, 'name': 'Empty'})
    assert empty['actions'] == [] and empty['ports'] == []

    bad = []
    for field, value in [('version', 2), ('version', True), ('name', 'x' * 81), ('name', '\u001b[31m'), ('unknown', True), ('actions', None)]:
        candidate = copy.deepcopy(base)
        candidate[field] = value
        bad.append(candidate)
    for field, value in [('id', '../bad'), ('label', ''), ('kind', 'shell'), ('argv', []), ('argv', ['']), ('argv', ['bad\nargv']), ('argv', ['x' * 4097]), ('cwd', '..'), ('cwd', '/tmp')]:
        candidate = copy.deepcopy(base)
        candidate['actions'][0][field] = value
        bad.append(candidate)
    for field, value in [('service', 'test'), ('container_port', 4096), ('container_port', 0), ('local_port', 80), ('scheme', 'file')]:
        candidate = copy.deepcopy(base)
        candidate['ports'][0][field] = value
        bad.append(candidate)
    candidate = copy.deepcopy(base)
    candidate['actions'].append(copy.deepcopy(candidate['actions'][0]))
    bad.append(candidate)
    for candidate in bad:
        validate(candidate, 2)
    for candidate in json.loads((root / 'tests/fixtures/development-contract/invalid-profiles.json').read_text()):
        validate(candidate, 2)
    profile.write_text('{"version":1,"version":1,"name":"duplicate key"}')
    call(['validate', profile], 2)
    profile.write_text(json.dumps(base) + '{}')
    call(['validate', profile], 2)
    outside = pathlib.Path(tmp) / 'outside'
    outside.mkdir()
    (repo / 'redirect').symlink_to(outside, target_is_directory=True)
    candidate = copy.deepcopy(base)
    candidate['actions'][0]['cwd'] = 'redirect'
    validate(candidate, 2)
    profile.unlink()
    (outside / 'profile.json').write_text(json.dumps(base))
    profile.symlink_to(outside / 'profile.json')
    call(['validate', profile], 2)
    call(['validate', 'relative/.molt/development.json'], 2)
    call(['validate'], 2)
    call(['unknown'], 2)

    lock = root / 'development-tools.lock.json'
    artifact = call(['artifact', lock, 'viewer', 'darwin', 'aarch64'])
    assert artifact['arch'] == 'arm64' and artifact['version'] == '4.1'
    assert artifact['sha256'] == '20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3'
    assert call(['artifact', lock, 'adb', 'darwin', 'x86_64'])['arch'] == 'amd64'
    call(['artifact', lock, 'viewer', 'linux', 'arm64'], 2)
    fixture_profile = root / 'tests/fixtures/development-contract/node/.molt/development.json'
    assert call(['validate', fixture_profile])['actions'][0]['id'] == 'setup'
    snapshot = pathlib.Path(tmp) / 'snapshot'
    existing = root / 'tests/fixtures/development-contract/existing'
    originals = {str(path.relative_to(existing)): path.read_bytes() for path in existing.rglob('*') if path.is_file()}
    shutil.copytree(existing, snapshot)
    (snapshot / 'devenv.original.nix').write_bytes((snapshot / 'devenv.nix').read_bytes())
    (snapshot / 'devenv.nix').write_text('{ imports = [ ./devenv.original.nix ./molt.nix ]; }\n')
    assert (snapshot / 'devenv.original.nix').read_bytes() == originals['devenv.nix']
    assert (snapshot / 'environment/node.nix').read_bytes() == originals['environment/node.nix']
    assert originals == {str(path.relative_to(existing)): path.read_bytes() for path in existing.rglob('*') if path.is_file()}

    # This stub proves menu argument routing/exit status only, not persistent services.
    runner = pathlib.Path(tmp) / 'runner.mjs'
    runner.write_text('const args = process.argv.slice(2);\n'
        'if (args[0] !== "--root" || args[1] !== "/workspace" || args[2] !== "--state" || args[3] !== "/molt-cache/development" || args[4] !== "--profile" || args[5] !== "/molt-meta/development/profile.json") process.exit(99);\n'
        'console.log(JSON.stringify(args.slice(6)));\n'
        'if (args[6] === "run") process.exit(23);\n')
    menu = pathlib.Path(tmp) / 'menu.mjs'
    menu.write_text((root / 'templates/development/menu.mjs').read_text().replace('/opt/molt/development.mjs', str(runner)))
    for args, expected, code in [(['--list'], ['list'], 0), (['test'], ['run', 'test'], 23)]:
        result = subprocess.run(['node', str(menu), *args], capture_output=True, text=True)
        assert result.returncode == code and json.loads(result.stdout) == expected, result
    result = subprocess.run(['node', str(menu), 'test;touch escaped'], capture_output=True, text=True)
    assert result.returncode == 2 and not (repo / 'escaped').exists(), result
print('PASS: development helper validation, literal arguments, containment, lock lookup, and menu runner stub')
PY
