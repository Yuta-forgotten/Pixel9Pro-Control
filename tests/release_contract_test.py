"""Package regression; writes only beneath the project's controlled work area."""
import dataclasses
import importlib.util
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import release_contract as contract


class ReleaseContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = contract.collect_runtime_files(ROOT)
        cls.scratch = ROOT.parent / 'work' / 'webui-md3-refactor-20260921' / 'release-tests'
        cls.scratch.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=self.scratch, prefix='case-')
        self.directory = Path(self.temp.name).resolve()
        self.assertTrue(self.directory.is_relative_to(self.scratch.resolve()))

    def tearDown(self):
        self.temp.cleanup()

    def write(self, files=None, name='candidate.zip'):
        target = self.directory / name
        contract.write_deterministic_zip(self.files if files is None else files, target)
        return target

    def test_deterministic_dos_metadata_and_cache_stamp(self):
        first, second = self.write(name='a.zip'), self.write(name='b.zip')
        self.assertEqual(first.read_bytes(), second.read_bytes())
        report = contract.audit_zip(first)
        self.assertEqual(set(report.payload_devices), {'caiman', 'komodo'})
        with zipfile.ZipFile(first) as archive:
            self.assertIsNone(archive.testzip())
            for info in archive.infolist():
                self.assertEqual(info.create_system, 0)
                self.assertEqual(info.external_attr, contract._mode_for(info.filename))
            self.assertNotIn(b'__WEBUI_VER__', archive.read('webroot/index.html'))

    def test_reject_missing_linked_frontend(self):
        candidate = self.write(tuple(item for item in self.files if item.archive_path != 'webroot/js/analytics_view.js'))
        with self.assertRaisesRegex(contract.ContractError, 'asset is missing'):
            contract.audit_zip(candidate)

    def test_reject_missing_boot_entry(self):
        candidate = self.write(tuple(item for item in self.files if item.archive_path != 'post-fs-data.sh'))
        with self.assertRaisesRegex(contract.ContractError, 'required entries'):
            contract.audit_zip(candidate)

    def test_reject_payload_corruption(self):
        files = tuple(dataclasses.replace(item, data=item.data + b'bad') if item.archive_path.endswith('.binarypb') else item for item in self.files)
        with self.assertRaises(contract.ContractError):
            contract.audit_zip(self.write(files))

    def test_reject_pre_activation_and_path_escape(self):
        for path in ['system/vendor/etc/thermal_info_config.json', 'system/vendor/etc/thermal_stock.json',
                     'system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.binarypb',
                     '../module.prop', '/module.prop', 'work/private.txt']:
            with self.subTest(path=path), self.assertRaises(contract.ContractError):
                contract._validate_archive_path(path)

    def test_reject_runtime_crlf_and_bom(self):
        for data in [b'line\r\n', b'\xef\xbb\xbfline\n']:
            with self.subTest(data=data), self.assertRaises(contract.ContractError):
                contract.validate_runtime_text('webroot/app.js', data)

    def test_reject_unix_metadata(self):
        original = self.write()
        changed = self.directory / 'unix.zip'
        with zipfile.ZipFile(original) as source, zipfile.ZipFile(changed, 'w') as target:
            for info in source.infolist():
                info.create_system = 3
                info.external_attr = (0o100000 | contract._mode_for(info.filename)) << 16
                target.writestr(info, source.read(info))
        with self.assertRaisesRegex(contract.ContractError, 'permission'):
            contract.audit_zip(changed)

    def test_integration_entry_routes_current_contract(self):
        script = ROOT.parent / 'builds/scripts/build_module.py'
        spec = importlib.util.spec_from_file_location('integration_builder', script)
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        self.assertEqual(builder.run_current_control_builder(['--validate-only', str(ROOT)]), 0)
        self.assertIsNone(builder.run_current_control_builder(['--fingerprint', str(ROOT)]))


if __name__ == '__main__':
    unittest.main(verbosity=2)
