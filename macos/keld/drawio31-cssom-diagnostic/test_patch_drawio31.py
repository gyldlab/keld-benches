"""Offline negative controls for the unscored, pinned draw.io 31.7.0 renderer patch."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MODULE_FILE = Path(__file__).with_name('patch_drawio31.py')
SPEC = importlib.util.spec_from_file_location('patch_drawio31', MODULE_FILE)
assert SPEC is not None and SPEC.loader is not None
patch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patch)


class PinTests(unittest.TestCase):
    def test_exact_single_minified_function(self) -> None:
        self.assertEqual(patch.replace_one(patch.OLD_MIN, patch.OLD_MIN, patch.NEW_MIN), patch.NEW_MIN)
        self.assertNotEqual(patch.OLD_MIN, patch.NEW_MIN)

    def test_readable_source_patch_keeps_attribute_fallback(self) -> None:
        output = patch.replace_one(patch.OLD_SRC, patch.OLD_SRC, patch.NEW_SRC)
        self.assertIn(b'elt.style.cssText = css', output)
        self.assertIn(patch.OLD_SRC, output)
        self.assertIn(b'else', output)

    def test_duplicate_original_must_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Expected one original'):
            patch.replace_one(patch.OLD_MIN + b'\n' + patch.OLD_MIN, patch.OLD_MIN, patch.NEW_MIN)

    def test_missing_original_must_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Expected one original'):
            patch.replace_one(b'irrelevant', patch.OLD_MIN, patch.NEW_MIN)

    def test_already_patched_must_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Expected one original'):
            patch.replace_one(patch.NEW_MIN, patch.OLD_MIN, patch.NEW_MIN)

    def test_mixed_original_and_patched_must_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Expected one original'):
            patch.replace_one(patch.OLD_MIN + patch.NEW_MIN, patch.OLD_MIN, patch.NEW_MIN)

    def test_pinned_bytes_accept_and_mutation_refuse(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'original.min.js'
            path.write_bytes(patch.OLD_MIN)
            expected = patch.digest(patch.OLD_MIN)
            self.assertEqual(patch.load(path, expected), patch.OLD_MIN)
            path.write_bytes(patch.OLD_MIN + b' ')
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                patch.load(path, expected)

    def test_missing_and_symlinked_inputs_refuse(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / 'original.js'
            alias = Path(folder) / 'link.js'
            original.write_bytes(patch.OLD_MIN)
            alias.symlink_to(original)
            with self.assertRaisesRegex(ValueError, 'symlinked'):
                patch.load(alias, patch.digest(patch.OLD_MIN))
            with self.assertRaisesRegex(ValueError, 'Invalid'):
                patch.load(Path(folder) / 'missing.js', patch.digest(patch.OLD_MIN))

    def test_private_dir_writer_refuses_overwrite_and_retains_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            app = home / 'source-app'
            webroot = app / 'drawio/src/main/webapp'
            webroot.mkdir(parents=True)
            policy = app / 'keld.permissions.jsonc'
            policy.write_text('{}')
            out = home / 'out'
            root_fd = patch.open_new_output(webroot, policy, out)
            try:
                patch.write_once_at(root_fd, 'js/original.js', b'first')
                with self.assertRaises(FileExistsError):
                    patch.write_once_at(root_fd, 'js/original.js', b'second')
                for bad_path in ('../escape.js', '/absolute.js', 'js/../../escape.js'):
                    with self.subTest(bad_path=bad_path):
                        with self.assertRaises(ValueError):
                            patch.write_once_at(root_fd, bad_path, b'second')
            finally:
                os.close(root_fd)
            target = out / 'js/original.js'
            self.assertEqual(target.read_bytes(), b'first')
            self.assertFalse((home / 'escape.js').exists())

    def test_refuse_output_inside_source_and_symlinked_parent(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            app = home / 'source-app'
            webroot = app / 'drawio/src/main/webapp'
            webroot.mkdir(parents=True)
            policy = app / 'keld.permissions.jsonc'
            policy.write_text('{}')
            for path in (webroot / 'generated', app / 'generated'):
                with self.subTest(path=path):
                    with self.assertRaisesRegex(ValueError, 'outside the pinned app'):
                        patch.open_new_output(webroot, policy, path)
                    self.assertFalse(path.exists())
            relocated_webroot = home / 'relocated-webroot'
            relocated_webroot.mkdir()
            with self.assertRaisesRegex(ValueError, 'outside the pinned app'):
                patch.open_new_output(relocated_webroot, policy, app / 'generated')
            (home / 'safe-parent').mkdir()
            alias = home / 'symlink-parent'
            alias.symlink_to(home / 'safe-parent', target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'symlinked output'):
                patch.open_new_output(webroot, policy, alias / 'new')
            self.assertFalse((home / 'safe-parent/new').exists())

    def test_refuse_symlinked_child_directory_for_writer(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            app = home / 'source-app'
            webroot = app / 'drawio/src/main/webapp'
            webroot.mkdir(parents=True)
            policy = app / 'keld.permissions.jsonc'
            policy.write_text('{}')
            outside = home / 'outside'
            outside.mkdir()
            out = home / 'out'
            root_fd = patch.open_new_output(webroot, policy, out)
            try:
                (out / 'js').symlink_to(outside, target_is_directory=True)
                with self.assertRaises(OSError):
                    patch.write_once_at(root_fd, 'js/app.min.js', b'do-not-leak')
                self.assertFalse((outside / 'app.min.js').exists())
            finally:
                os.close(root_fd)

    def test_cli_rejects_wrong_original_before_output(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            webroot = home / 'webroot'
            (webroot / 'js').mkdir(parents=True)
            (webroot / 'mxgraph/src/util').mkdir(parents=True)
            (webroot / 'js/app.min.js').write_bytes(b'not draw.io 31.7.0')
            (webroot / 'mxgraph/src/util/mxSvgCanvas2D.js').write_bytes(patch.OLD_SRC)
            policy = home / 'keld.permissions.jsonc'
            policy.write_bytes(b'{}')
            output = home / 'must_not_exist'
            result = subprocess.run(
                [sys.executable, '-B', str(MODULE_FILE), '--webroot', str(webroot),
                 '--policy', str(policy), '--output', str(output)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Pinned input SHA-256 mismatch', result.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
