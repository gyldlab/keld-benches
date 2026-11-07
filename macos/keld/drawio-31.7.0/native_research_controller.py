import argparse,json,os,re,subprocess as sp,sys,time,pathlib,hashlib
from datetime import datetime,timezone
# Runtime sources must be provided explicitly. No machine-specific paths are committed.
out=pathlib.Path(__file__).parent
pair=None
def note(s):print(datetime.now(timezone.utc).isoformat(),s,flush=True)
def filehash(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def family():
 return [x for x in sp.check_output(['ps','-axo','comm='],text=True).splitlines() if (x.endswith('/keld-host') or x.endswith('/draw.io.app/Contents/MacOS/draw.io') or '/debug/deps/no_flag_macos-' in x)]

def stage_verified_input(arm, num, dest, fixture_dir=None, attempt_id=None):
    """Stage actual SHA-pinned file for the *prospective* app launch, not proof it loaded."""
    import stat, uuid
    if arm not in ('baseline', 'candidate'):
        raise ValueError('native controller accepts only the KELD baseline/candidate arms')
    fixture_dir = pathlib.Path(fixture_dir or os.environ["KELD_DRAWIO31_FIXTURE_DIR"])
    source = fixture_dir / 'scene.drawio'
    checker = fixture_dir / 'test_source_manifest.py'
    # This sealed prospective campaign fixes the code *and* the source payload.
    # An updated PR/checker or scene needs a separately registered candidate and D1;
    # a self-consistent unreviewed local attestor may not redefine either input.
    expected_checker_sha256 = '2f25b816bbb3a7304a30891bccf69925fba5d45dadb31efb3845537f5d0be66a'
    expected_scene_sha256 = '236ffe4a7936e1d541b50e26f070177085dcdf5779055e67de6ba379801ba7a3'
    if not dest.is_dir() or dest.is_symlink() or source.is_symlink() or checker.is_symlink():
        raise ValueError('untrusted attempt/source/checker filesystem identity')
    attempt_id = attempt_id or str(uuid.uuid4())
    # The source tool, not this controller, owns fixture/manifest policy and digest.
    receipt = dest / 'source-prelaunch.json'
    if receipt.exists() or receipt.is_symlink():
        raise ValueError('source receipt already exists for this attempt')
    if hashlib.sha256(checker.read_bytes()).hexdigest() != expected_checker_sha256:
        raise ValueError('attestor identity differs from registered source')
    result = sp.run(
        [sys.executable, '-B', str(checker), '--attest-before-launch',
         '--arm', arm, '--attempt-id', attempt_id, '--receipt-out', str(receipt)],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        raise ValueError(f'source attestation rejected: exit={result.returncode}: {result.stderr[:250]}')
    # Verify the executed path did not drift during the child process; a hostile
    # concurrent writer still needs ownership-level exclusion, not hash checks alone.
    if hashlib.sha256(checker.read_bytes()).hexdigest() != expected_checker_sha256:
        raise ValueError('attestor identity changed during source attestation')
    proof_bytes = receipt.read_bytes()
    proof = json.loads(proof_bytes)
    if proof.get('source_sha256') != expected_scene_sha256:
        raise ValueError('registered payload digest differs from attested source')
    if (proof.get('schema') != 'keld31-source-prelaunch-custody-v1'
        or proof.get('status') != 'source_bytes_verified_only'
        or proof.get('arm') != arm or proof.get('attempt_id') != attempt_id
        or proof.get('source_path') != str(source.absolute())
        or proof.get('source_bytes') != 1040
        or any(proof.get(flag) is not False for flag in
               ('app_launched_by_check', 'app_loaded_source_verified',
                'equivalent_work_verified', 'performance_admitted'))):
        raise ValueError('invalid prelaunch proof or false success assertion')
    # Open separately from the attestor. Re-check the inode and digest; a
    # rename/mutation between attestation and actual staging must fail.
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, 'O_CLOEXEC', 0))
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode)
            or (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size)
            != (proof.get('source_device'), proof.get('source_inode'),
                proof.get('source_mtime_ns'), proof.get('source_bytes'))):
            raise ValueError('source identity moved after receipt')
        data = os.read(fd, proof['source_bytes'] + 1)
        after = os.fstat(fd)
        if (len(data) != proof['source_bytes']
            or (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size, before.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size, after.st_ctime_ns)
            or hashlib.sha256(data).hexdigest() != proof.get('source_sha256')):
            raise ValueError('staged source bytes differ from attestation')
    finally:
        os.close(fd)
    if (source.is_symlink() or
        (source.stat().st_dev, source.stat().st_ino, source.stat().st_mtime_ns)
        != (before.st_dev, before.st_ino, before.st_mtime_ns)):
        raise ValueError('source path changed while staging')
    name = f'kel-{arm[0]}{num}.drawio'
    target = dest / name
    if target.exists() or target.is_symlink():
        raise ValueError('launch document already exists')
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as writer:
            writer.write(data)
            writer.flush()
            os.fsync(writer.fileno())
    except BaseException:
        # Preserve failed attempt bytes; no launch may follow a failed stage.
        raise
    observed = target.read_bytes()
    if hashlib.sha256(observed).hexdigest() != proof['source_sha256'] or target.is_symlink():
        raise ValueError('actual launch document differs from attested source')
    target_stat = target.stat()
    with (dest / 'document-name').open('x') as output:
        output.write(name)
        output.flush()
        os.fsync(output.fileno())
    binding = {
        'schema': 'keld31-controller-input-staging-v1',
        'status': 'copied_for_launch_not_editor_loaded',
        'arm': arm, 'attempt_id': attempt_id,
        'source_receipt_sha256': hashlib.sha256(proof_bytes).hexdigest(),
        'launch_document_name': name,
        'launch_document_sha256': hashlib.sha256(observed).hexdigest(),
        'launch_document_device': target_stat.st_dev,
        'launch_document_inode': target_stat.st_ino,
        'launch_document_mtime_ns': target_stat.st_mtime_ns,
        'app_loaded_source_verified': False, 'equivalent_work_verified': False,
        'performance_admitted': False,
    }
    with (dest / 'source-into-attempt.json').open('x') as output:
        json.dump(binding, output, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    directory_fd = os.open(dest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return binding


def check_native_final_log(log):
    """Reject logged delivery/JS faults even when the binary test printed PASS.

    This is a necessary negative gate, NOT proof of editor-loaded bytes, successful
    equivalent work, complete process cleanup or scoreable resource accounting.
    """
    failures = tuple(name for name, marker in (
        ('guard_denied', 'KELD-GUARD003'),
        ('event_send_failed', 'webContents.send failed'),
        ('page_js_error', 'js-error'),
        ('native_teardown_failed', 'KELD-NATIVE-017'),
        ('ipc_delivery_failed', 'KELD-IPC-022'),
        ('call_not_admitted', 'KELD-IPC-005'),
        ('main_ipc_delivery_failed', 'KELD main IPC delivery failed'),
    ) if marker.lower() in log.lower())
    binary_success = bool(re.search(r'(?m)^\s*test result: ok\.', log))
    if failures or not binary_success:
        raise ValueError('native close or delivery/admission check failed: '+
                         ','.join(failures or ('no_binary_terminal_success',)))
    return True

def go(arm,num):
 if arm not in ('baseline', 'candidate') or not re.fullmatch(r'[0-9]{2,3}', num):
  raise ValueError('native diagnostic requires a baseline/candidate arm and 2-3 digit attempt')
 if pair is None:
  raise ValueError('runtime pair root is required')
 if family():raise ValueError('preexisting app or fixture: '+str(family()))
 note(('launch',arm,num))
 dest=pair/arm/('attempt-'+num)
 # One fresh process generation per attempt: even a failed setup is retained,
 # never retried under the same attempt directory / score slot.
 if dest.exists() or dest.is_symlink(): raise ValueError('attempt path reused')
 dest.mkdir(mode=0o700);os.mkfifo(dest/'control.fifo',0o600)
 binding = stage_verified_input(arm,num,dest)
 launch_file = dest / binding['launch_document_name']
 launch_stat = launch_file.stat()
 if (launch_file.is_symlink()
     or (launch_stat.st_dev, launch_stat.st_ino, launch_stat.st_mtime_ns)
     != (binding['launch_document_device'], binding['launch_document_inode'],
         binding['launch_document_mtime_ns'])
     or filehash(launch_file) != binding['launch_document_sha256']):
  raise ValueError('launch document mutated after verified stage')
 sp.run(['open','-n','-a',str(pair/arm/'NativeFixtureBoundary.app'),'--args',str(dest)],check=True)
 for tool in ['drive','work']:
  with (dest/(tool+'-strict.log')).open('x') as f:
   sp.run([sys.executable,'-u',str(out/(tool+'.py')),arm,num],stdout=f,stderr=sp.STDOUT,check=True,timeout=260)
 for _ in range(100):
  log=(dest/'native-session.log').read_text()
  if 'test result:' in log:break
  time.sleep(.3)
 check_native_final_log(log)
 if family():raise ValueError('native close or admission check failed: live target coalition')
 for phase in ('reopen','post-save'):
  meta=json.loads((dest/phase/'phase.json').read_text())
  if not 9.8<=meta['delay_from_anchor_s']<=12:raise ValueError('sampling delay drift')
 # The final retained file can gain diagnostics after the first terminal marker.
 # A clean terminal marker is never sufficient for equivalent-work admission.
 check_native_final_log((dest/'native-session.log').read_text())
 note(('diagnostic_native_close_only_not_admitted',arm,num))

def main(argv=None):
    """Research correctness controller; never produces a benchmark result/score."""
    parser = argparse.ArgumentParser(description='draw.io 31.7.0 non-scoring native correctness controller')
    parser.add_argument('action', choices=('stage', 'screen-log', 'run-native'))
    parser.add_argument('--arm', choices=('baseline', 'candidate'))
    parser.add_argument('--attempt', help='2-3 digit attempt number, not a metric sample')
    parser.add_argument('--attempt-id', help='canonical UUID for source stage (required for stage)')
    parser.add_argument('--attempt-dir', type=pathlib.Path)
    parser.add_argument('--pair-root', type=pathlib.Path)
    parser.add_argument('--drivers-dir', type=pathlib.Path)
    parser.add_argument('--log', type=pathlib.Path)
    parser.add_argument('--fixture-dir', type=pathlib.Path, default=pathlib.Path(__file__).parent)
    args = parser.parse_args(argv)
    try:
        if args.action == 'screen-log':
            if args.log is None or args.log.is_symlink():
                raise ValueError('regular final native log required')
            check_native_final_log(args.log.read_text(encoding='utf-8'))
            print('negative-log-screen-only; equivalent-work/performance NOT admitted')
            return 0
        if args.arm is None or args.attempt is None or not re.fullmatch(r'[0-9]{2,3}', args.attempt):
            raise ValueError('baseline/candidate arm and 2-3 digit attempt required')
        if args.fixture_dir.is_symlink() or not args.fixture_dir.is_dir():
            raise ValueError('real fixture directory required')
        os.environ['KELD_DRAWIO31_FIXTURE_DIR'] = str(args.fixture_dir)
        if args.action == 'stage':
            if args.attempt_dir is None or not args.attempt_id:
                raise ValueError('attempt directory and canonical UUID required for staging')
            result = stage_verified_input(args.arm, args.attempt, args.attempt_dir,
                                          args.fixture_dir, args.attempt_id)
            print(json.dumps(result, sort_keys=True, allow_nan=False))
            return 0
        global out, pair
        if args.pair_root is None or args.drivers_dir is None:
            raise ValueError('pair root and existing native drivers directory required')
        for path in (args.pair_root, args.drivers_dir):
            if not path.is_dir() or path.is_symlink():
                raise ValueError('pair/driver directories must be existing real directories')
        pair, out = args.pair_root, args.drivers_dir
        # No metric is produced. OS-level GUI lease and build/input acceptance
        # are owned externally and MUST be obtained before run-native.
        go(args.arm, args.attempt)
        return 0
    except (OSError, ValueError, json.JSONDecodeError, sp.CalledProcessError,
            sp.TimeoutExpired) as error:
        print(f'native correctness controller REFUSED: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
