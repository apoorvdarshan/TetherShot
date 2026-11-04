"""Pairing migration and dependency regressions, without a phone or credentials."""
import asyncio
import importlib.util
import plistlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

spec = importlib.util.spec_from_file_location('wireless_setup', Path(__file__).with_name('wireless-setup.py'))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
spec = importlib.util.spec_from_file_location('wireless_screenshot_version', Path(__file__).with_name('wireless-screenshot.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Completed(Exception):
    pass


class PairingTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.record = self.home / 'remote_phone.plist'
        self.original = plistlib.dumps({'private_key': b'fixture-only-legacy-key'})
        self.record.write_bytes(self.original)
        self.modern = {'private_key': b'fixture-only-refreshed-key', 'peer_alt_irk': b'x' * 16}

    async def migrate(self, effect):
        service = SimpleNamespace(connect=AsyncMock(side_effect=effect))
        await setup.refresh_pairing(self.record, service, Completed)
        return service

    async def test_refreshes_legacy_pairing_and_preserves_private_backup(self):
        def connect(**kwargs):
            self.assertTrue(kwargs['autopair'])
            self.assertFalse(self.record.exists())
            self.record.write_bytes(plistlib.dumps(self.modern))
            raise Completed()
        await self.migrate(connect)
        self.assertTrue(setup.has_discovery_key(self.record))
        backups = list((self.home / 'backups').glob('*.plist'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.original)
        for path in [backups[0], self.record]:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.home / 'backups').stat().st_mode & 0o777, 0o700)

    async def test_keeps_working_pairing_without_repairing_it(self):
        data = plistlib.dumps(self.modern)
        self.record.write_bytes(data)
        service = await self.migrate(None)
        service.connect.assert_not_awaited()
        self.assertEqual(self.record.read_bytes(), data)
        self.assertFalse((self.home / 'backups').exists())

    async def test_failed_pairing_restores_original(self):
        with self.assertRaises(TimeoutError):
            await self.migrate(TimeoutError())
        self.assertEqual(self.record.read_bytes(), self.original)

    async def test_incomplete_new_key_is_preserved_before_rollback(self):
        incomplete = plistlib.dumps({'private_key': b'fixture-only-incomplete-key'})
        def connect(**_):
            self.record.write_bytes(incomplete)
        with self.assertRaises(RuntimeError):
            await self.migrate(connect)
        self.assertEqual(self.record.read_bytes(), self.original)
        backups = list((self.home / 'backups').glob('*incomplete*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), incomplete)

    async def test_completed_reply_without_record_is_failure(self):
        with self.assertRaises(RuntimeError):
            await self.migrate(Completed())
        self.assertEqual(self.record.read_bytes(), self.original)

    async def test_cancellation_restores_original(self):
        started = asyncio.Event()
        async def connect(**_):
            started.set()
            await asyncio.Event().wait()
        task = asyncio.create_task(self.migrate(connect))
        await started.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertEqual(self.record.read_bytes(), self.original)

    async def test_new_pairing_without_legacy_record(self):
        self.record.unlink()
        def connect(**_):
            self.record.write_bytes(plistlib.dumps(self.modern))
        await self.migrate(connect)
        self.assertTrue(setup.has_discovery_key(self.record))

    async def test_rejects_symlinked_backup_without_touching_credentials(self):
        external = self.home / 'external'
        external.mkdir()
        (self.home / 'backups').symlink_to(external)
        with self.assertRaises(ValueError):
            await self.migrate(None)
        self.assertEqual(self.record.read_bytes(), self.original)
        self.assertFalse(list(external.iterdir()))

    async def test_rejects_symlinked_record(self):
        external = self.home / 'external.plist'
        self.record.rename(external)
        self.record.symlink_to(external)
        with self.assertRaises(ValueError):
            await self.migrate(None)
        self.assertEqual(external.read_bytes(), self.original)


class SetupTests(unittest.TestCase):
    def test_current_requirement_and_engine_are_accepted(self):
        requirement = setup.requirement(Path(__file__).with_name('requirements-wireless.txt'))
        with patch.object(helper.metadata, 'version', return_value=requirement.split('==')[1]):
            helper.require_supported_engine()

    def test_old_engine_fails_with_repair_guidance(self):
        with patch.object(helper.metadata, 'version', return_value='9.33.1'):
            with self.assertRaisesRegex(RuntimeError, 'Wi-Fi engine.*Repair'):
                helper.require_supported_engine()

    def test_missing_engine_fails_with_repair_guidance(self):
        with patch.object(helper.metadata, 'version', side_effect=helper.metadata.PackageNotFoundError):
            with self.assertRaisesRegex(RuntimeError, 'Wi-Fi engine.*Repair'):
                helper.require_supported_engine()

    def test_daemon_uses_managed_engine_and_no_root_bytecode(self):
        home = Path('/Users/a person & another')
        tool = home / '.local/share/tethershot/wireless/bin/pymobiledevice3'
        data = setup.daemon_plist(home, tool)
        decoded = plistlib.loads(plistlib.dumps(data))
        self.assertEqual(decoded['ProgramArguments'], [str(tool), 'remote', 'tunneld', '--no-usbmux', '--no-mobdev2'])
        self.assertEqual(decoded['EnvironmentVariables']['HOME'], str(home))
        self.assertEqual(decoded['EnvironmentVariables']['PYTHONDONTWRITEBYTECODE'], '1')

    def test_requirement_rejects_additional_packages_or_urls(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'requirements.txt'
            for value in ['pymobiledevice3==11.49.5\nother==1', 'https://example.com/pkg.whl', 'pymobiledevice3>=11']:
                path.write_text(value)
                with self.assertRaises(ValueError):
                    setup.requirement(path)

    def test_ownership_rejects_symlinked_cache_before_chown(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            external = home / 'external'
            external.mkdir()
            (home / '.pymobiledevice3').symlink_to(external)
            user = SimpleNamespace(pw_dir=tmp, pw_gid=20)
            with patch.object(setup.os, 'geteuid', return_value=0), patch.object(setup.pwd, 'getpwuid', return_value=user), patch.object(setup.os, 'chown') as chown:
                with self.assertRaises(ValueError):
                    setup.repair_ownership(501)
                chown.assert_not_called()

    def test_ownership_does_not_follow_record_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            cache = home / '.pymobiledevice3'
            cache.mkdir()
            external = home / 'external'
            external.write_bytes(b'unchanged')
            external.chmod(0o644)
            (cache / 'remote_phone.plist').symlink_to(external)
            user = SimpleNamespace(pw_dir=tmp, pw_gid=20)
            with patch.object(setup.os, 'geteuid', return_value=0), patch.object(setup.pwd, 'getpwuid', return_value=user), patch.object(setup.os, 'chown') as chown:
                setup.repair_ownership(501)
                chown.assert_called_once_with(cache, 501, 20, follow_symlinks=False)
            self.assertEqual(external.stat().st_mode & 0o777, 0o644)
