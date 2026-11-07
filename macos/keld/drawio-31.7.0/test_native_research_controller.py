"""Portable non-GUI regressions for the original31 correctness controller.

These are not native editor, RAM, CPU or successful IPC delivery tests.
"""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

import native_research_controller as controller

HERE = Path(__file__).resolve().parent
EXPECTED_SOURCE = '236ffe4a7936e1d541b50e26f070177085dcdf5779055e67de6ba379801ba7a3'
OK = 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n'


class FixtureNativeCorrectnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=HERE)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fixture = self.root / 'fixture'
        self.fixture.mkdir()
        for name in ('test_source_manifest.py', 'scene.drawio', 'source-manifest.json'):
            shutil.copyfile(HERE/name, self.fixture/name)
        self.attempt = self.root / 'attempt-01'
        self.attempt.mkdir(mode=0o700)
        self.uid = str(uuid.uuid4())

    def portable_bundle(self, arm_root, arm):
        app = arm_root / 'NativeFixtureBoundary.app'
        binary = app / 'Contents' / 'MacOS' / 'NativeFixtureBoundary'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        with (app/'Contents'/'Info.plist').open('wb') as stream:
            plistlib.dump({
                'CFBundlePackageType': 'APPL',
                'CFBundleExecutable': 'NativeFixtureBoundary',
                'CFBundleIdentifier': f'com.gyldlab.keld.kel90.bench.{arm}',
            }, stream)
        return app

    def stage(self, arm='baseline'):
        return controller.stage_verified_input(arm, '01', self.attempt, self.fixture, self.uid)

    def test_real_source_and_attestor_stage_to_distinct_0600_file(self):
        result = self.stage()
        target = self.attempt / 'kel-b01.drawio'
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), EXPECTED_SOURCE)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertFalse(result['app_loaded_source_verified'])
        self.assertFalse(result['equivalent_work_verified'])
        self.assertFalse(result['performance_admitted'])
        receipt = json.loads((self.attempt/'source-prelaunch.json').read_text())
        self.assertEqual(receipt['status'], 'source_bytes_verified_only')
        self.assertEqual(receipt['source_sha256'], EXPECTED_SOURCE)
        self.assertEqual(result['source_receipt_sha256'], hashlib.sha256((self.attempt/'source-prelaunch.json').read_bytes()).hexdigest())
        self.assertEqual(json.loads((self.attempt/'source-into-attempt.json').read_text()), result)

    def test_candidate_uses_exact_same_registered_file(self):
        result = self.stage('candidate')
        self.assertEqual(result['arm'], 'candidate')
        self.assertEqual(hashlib.sha256((self.attempt/'kel-c01.drawio').read_bytes()).hexdigest(), EXPECTED_SOURCE)

    def test_second_attempt_cannot_replace_receipt(self):
        self.stage()
        before = (self.attempt/'source-prelaunch.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.stage()
        self.assertEqual((self.attempt/'source-prelaunch.json').read_bytes(), before)

    def test_scene_mutation_cannot_stage(self):
        p = self.fixture/'scene.drawio'
        p.write_bytes(p.read_bytes().replace(b'x="190"', b'x="191"', 1))
        with self.assertRaisesRegex(ValueError, 'attestation rejected'):
            self.stage()
        self.assertFalse((self.attempt/'kel-b01.drawio').exists())

    def test_modified_attestor_cannot_stage_even_when_scene_valid(self):
        p = self.fixture/'test_source_manifest.py'
        p.write_bytes(p.read_bytes()+b'\n# adversarial but syntax-preserving edit\n')
        with self.assertRaisesRegex(ValueError, 'attestor identity'):
            self.stage()
        self.assertFalse((self.attempt/'source-prelaunch.json').exists())

    def test_source_symlink_is_rejected(self):
        p = self.fixture/'scene.drawio'
        outside = self.root/'copy.drawio'
        outside.write_bytes(p.read_bytes())
        p.unlink(); p.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            self.stage()

    def test_controller_rejects_electron_until_separate_campaign(self):
        with self.assertRaisesRegex(ValueError, 'only the KELD'):
            self.stage('electron')
        self.assertFalse((self.attempt/'source-prelaunch.json').exists())

    def test_native_terminal_binary_ok_is_insufficient(self):
        self.assertIs(controller.check_native_final_log(OK), True)
        for marker in ('KELD-GUARD003', 'webContents.send failed', 'js-error',
                       'KELD-NATIVE-017', 'KELD-IPC-022', 'KELD-IPC-005',
                       'KELD main IPC delivery failed'):
            with self.subTest(marker=marker):
                with self.assertRaisesRegex(ValueError, 'delivery/admission'):
                    controller.check_native_final_log(OK + marker + '\n')
        with self.assertRaisesRegex(ValueError, 'binary_terminal_failed'):
            controller.check_native_final_log('test result: FAILED.\n')

    def test_cli_source_stage_and_final_log_fail_closed(self):
        code = HERE/'native_research_controller.py'
        cmd = [sys.executable, '-B', str(code), 'stage', '--arm', 'baseline',
               '--attempt', '01', '--attempt-id', self.uid, '--attempt-dir', str(self.attempt),
               '--fixture-dir', str(self.fixture)]
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['app_loaded_source_verified'])
        again = subprocess.run(cmd, capture_output=True, text=True, check=False)
        self.assertEqual(again.returncode, 2)
        self.assertIn('REFUSED', again.stderr)
        bad = self.root/'final.log'; bad.write_text(OK + 'KELD-IPC-005\n')
        checked = subprocess.run([sys.executable, '-B', str(code), 'screen-log', '--log', str(bad)],
                                 capture_output=True, text=True, check=False)
        self.assertEqual(checked.returncode, 2)

    def test_mixed_binary_terminals_rejected(self):
        for log in (OK + 'test result: FAILED. 0 passed; 1 failed; 0 ignored\n',
                    'test result: FAILED. 0 passed; 1 failed; 0 ignored\n' + OK):
            with self.subTest(log=log):
                with self.assertRaisesRegex(ValueError, 'binary_terminal_failed'):
                    controller.check_native_final_log(log)

    def test_symlink_arm_refused_before_attempt_or_fifo(self):
        pair = self.root / 'pair'
        pair.mkdir()
        outside = self.root / 'outside'
        outside.mkdir()
        (pair/'baseline').symlink_to(outside, target_is_directory=True)
        with patch.object(controller, 'pair', pair), patch.object(controller, 'family', return_value=[]), patch.object(controller, 'stage_verified_input', side_effect=RuntimeError('stage sentinel')):
            with self.assertRaisesRegex(ValueError, 'arm root must be an existing real directory'):
                controller.go('baseline', '07')
        self.assertFalse((outside/'attempt-07').exists())

    def test_other_arm_app_bundle_refused_before_creating_attempt(self):
        pair = self.root / 'pair'
        arm = pair / 'candidate'
        arm.mkdir(parents=True)
        self.portable_bundle(arm, 'baseline')
        with patch.object(controller, 'pair', pair), patch.object(controller, 'family', return_value=[]), patch.object(controller, 'stage_verified_input', side_effect=RuntimeError('stage sentinel')):
            with self.assertRaisesRegex(ValueError, 'native bundle arm identity'):
                controller.go('candidate', '07')
        self.assertFalse((arm/'attempt-07').exists())

    def test_bundle_symlink_refused_before_creating_attempt(self):
        pair = self.root / 'pair'
        source = pair / 'baseline'
        source.mkdir(parents=True)
        self.portable_bundle(source, 'baseline')
        arm = pair / 'candidate'
        arm.mkdir()
        (arm/'NativeFixtureBoundary.app').symlink_to(source/'NativeFixtureBoundary.app', target_is_directory=True)
        with patch.object(controller, 'pair', pair), patch.object(controller, 'family', return_value=[]), patch.object(controller, 'stage_verified_input', side_effect=RuntimeError('stage sentinel')):
            with self.assertRaisesRegex(ValueError, 'native bundle path'):
                controller.go('candidate', '07')
        self.assertFalse((arm/'attempt-07').exists())

    def test_bundle_missing_executable_refused(self):
        pair = self.root / 'pair'
        arm = pair / 'candidate'
        arm.mkdir(parents=True)
        app = self.portable_bundle(arm, 'candidate')
        (app/'Contents'/'MacOS'/'NativeFixtureBoundary').unlink()
        with patch.object(controller, 'pair', pair), patch.object(controller, 'family', return_value=[]), patch.object(controller, 'stage_verified_input', side_effect=RuntimeError('stage sentinel')):
            with self.assertRaisesRegex(ValueError, 'native bundle metadata or executable'):
                controller.go('candidate', '07')
        self.assertFalse((arm/'attempt-07').exists())

    def test_real_arm_reaches_stage_without_gui_launch(self):
        pair = self.root / 'pair'
        (pair/'baseline').mkdir(parents=True)
        self.portable_bundle(pair/'baseline', 'baseline')
        pinned = hashlib.sha256((pair/'baseline'/'NativeFixtureBoundary.app'/'Contents'/'MacOS'/'NativeFixtureBoundary').read_bytes()).hexdigest()
        with patch.object(controller, 'REGISTERED_NATIVE_EXECUTABLE_SHA256', {'baseline': pinned}), \
             patch.object(controller, 'pair', pair), \
             patch.object(controller, 'family', return_value=[]), \
             patch.object(controller, 'stage_verified_input', side_effect=RuntimeError('stage sentinel')):
            with self.assertRaisesRegex(RuntimeError, 'stage sentinel'):
                controller.go('baseline', '07')
        self.assertTrue((pair/'baseline'/'attempt-07'/'control.fifo').exists())

    def test_changed_executable_with_same_bundle_id_rejected_before_attempt(self):
        pair = self.root / 'pair'
        arm = pair / 'candidate'
        arm.mkdir(parents=True)
        app = self.portable_bundle(arm, 'candidate')
        binary = app / 'Contents' / 'MacOS' / 'NativeFixtureBoundary'
        pinned_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        with patch.object(controller, 'pair', pair), \
             patch.object(controller, 'family', return_value=[]), \
             patch.object(controller, 'stage_verified_input', side_effect=RuntimeError('stage sentinel')), \
             patch.object(controller, 'REGISTERED_NATIVE_EXECUTABLE_SHA256', {'candidate': pinned_digest}, create=True):
            with self.assertRaisesRegex(RuntimeError, 'stage sentinel'):
                controller.go('candidate', '07')
            self.assertTrue((arm / 'attempt-07').exists())
            binary.write_bytes(binary.read_bytes() + b'\n# altered executable\n')
            self.assertTrue(os.access(binary, os.X_OK))
            with self.assertRaisesRegex(ValueError, 'native executable digest mismatch'):
                controller.go('candidate', '08')
            self.assertFalse((arm / 'attempt-08').exists())

    def test_native_run_invalid_arm_attempt_rejected_before_gui(self):
        with patch.object(controller.sp, 'run') as called:
            with self.assertRaisesRegex(ValueError, '2-3 digit'):
                controller.go('baseline', '../unsafe')
            with self.assertRaisesRegex(ValueError, 'baseline/candidate'):
                controller.go('electron', '01')
            called.assert_not_called()


if __name__ == '__main__':
    unittest.main()
