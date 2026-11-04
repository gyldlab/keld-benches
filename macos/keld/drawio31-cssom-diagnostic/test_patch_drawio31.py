"""Offline negative controls for the unscored, pinned draw.io 31.7.0 renderer patch."""
from __future__ import annotations

import importlib.util
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

    def test_write_once_refuses_overwrite_and_retains_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'out' / 'original.js'
            patch.write_once(target, b'first')
            self.assertEqual(target.read_bytes(), b'first')
            with self.assertRaises(FileExistsError):
                patch.write_once(target, b'second')
            self.assertEqual(target.read_bytes(), b'first')

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
