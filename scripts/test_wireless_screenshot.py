"""Run with: python3 -m unittest discover -s scripts -p 'test_*.py'.

Uses fake sessions and tunnel discovery; no phone or pymobiledevice3 required.
"""
import asyncio
import importlib.util
import io
import json
from pathlib import Path
import sys
import threading
import types
import unittest
from unittest.mock import AsyncMock, patch

spec = importlib.util.spec_from_file_location('wireless_screenshot', Path(__file__).with_name('wireless-screenshot.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def tunnels(address='new'):
    return {'phone': [{'tunnel-address': address, 'tunnel-port': 1234}]}


class FakeSession:
    def __init__(self, address, udid=None):
        self.address = address
        self.udid = udid
        self.closed = False
        self.screenshot = self
        self.checked_at = float('-inf')
        self.probes = 0

    async def open(self):
        pass

    async def probe(self):
        self.probes += 1

    async def close(self):
        self.closed = True

    async def get_screenshot(self):
        return b'png'


class ReconnectTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = helper.Server()
        self.server.wanted['phone'] = asyncio.get_running_loop().time()
        # These tests cover tunneld alone; NativeFallbackTests enable Apple's tunnel.
        patcher = patch.object(helper, 'native_supported', return_value=False)
        patcher.start()
        self.addCleanup(patcher.stop)

    async def test_moved_address_reconnects_and_closes_old_session(self):
        old = FakeSession(('old', 1234))
        self.server.sessions['phone'] = old
        with patch.object(helper, 'list_tunnels', return_value=tunnels()), patch.object(helper, 'Session', FakeSession):
            await self.server.refresh()
        self.assertTrue(old.closed)
        self.assertEqual(self.server.sessions['phone'].address, ('new', 1234))

    async def test_brief_gap_keeps_device_but_long_gap_expires_it(self):
        old = FakeSession(('old', 1234))
        self.server.sessions['phone'] = old
        with patch.object(helper, 'list_tunnels', return_value={}):
            self.server.wanted['phone'] -= 10
            await self.server.refresh()
            self.assertIn('phone', self.server.wanted)
            self.server.wanted['phone'] -= 30
            await self.server.refresh()
        self.assertNotIn('phone', self.server.wanted)
        self.assertTrue(old.closed)

    async def test_discovery_failure_expires_sessionless_device(self):
        self.server.wanted['phone'] -= 60
        with patch.object(helper, 'list_tunnels', side_effect=ConnectionError):
            await self.server.refresh()
        self.assertFalse(self.server.wanted)

    async def test_discovery_failure_preserves_cached_session(self):
        self.server.sessions['phone'] = FakeSession(('old', 1234))
        self.server.wanted['phone'] -= 60
        with patch.object(helper, 'list_tunnels', side_effect=ConnectionError):
            await self.server.refresh()
        self.assertIn('phone', self.server.wanted)

    async def test_failed_reconnect_retries_next_poll(self):
        self.server.open_tunneld = AsyncMock(side_effect=[TimeoutError(), FakeSession(('new', 1234))])
        with patch.object(helper, 'list_tunnels', return_value=tunnels()):
            await self.server.refresh()
            await self.server.refresh()
        self.assertEqual(self.server.open_tunneld.await_count, 2)

    async def test_capture_interrupts_background_reconnect(self):
        started = threading.Event()
        closed = []
        class SlowSession(FakeSession):
            async def open(self):
                if self.address[0] == 'new':
                    started.set()
                    await asyncio.Event().wait()
            async def close(self):
                closed.append(self.address[0])
        reads = iter([b'warm phone\n', None, 'wait', b''])
        def read(_):
            item = next(reads)
            if item == 'wait':
                if not started.wait(2):
                    raise AssertionError('Background reconnect did not start')
                return b'shot other\n'
            return item
        def address(udid):
            if udid == 'other':
                return ('other', 1234)
            return ('old' if not server.sessions else 'new', 1234)
        server = helper.Server()
        out = io.BytesIO()
        with patch.object(helper, 'Server', return_value=server), patch.object(helper, 'Session', SlowSession), patch.object(helper, '_read_line_or_timeout', side_effect=read), patch.object(helper, 'list_tunnels', return_value=tunnels()), patch.object(helper, 'tunnel_address', side_effect=address):
            await asyncio.wait_for(helper.serve(out), 3)
        self.assertIn('new', closed)
        self.assertEqual(out.getvalue(), b'K\0\0\0\0P\0\0\0\3png')

    async def test_cancelled_close_completes_cleanup(self):
        started = asyncio.Event()
        release = asyncio.Event()
        finished = asyncio.Event()
        class Stack:
            async def aclose(self):
                started.set()
                await release.wait()
                finished.set()
        session = helper.Session(('old', 1234))
        session._stack = Stack()
        task = asyncio.create_task(session.close())
        await started.wait()
        task.cancel()
        release.set()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(finished.is_set())

    async def test_empty_helper_retires(self):
        server = helper.Server()
        with patch.object(helper, 'Server', return_value=server), patch.object(helper, '_EMPTY_EXIT_AFTER', 0), patch.object(helper, '_read_line_or_timeout', return_value=None):
            await asyncio.wait_for(helper.serve(io.BytesIO()), 1)

    async def test_close_clears_wanted_and_session(self):
        old = FakeSession(('old', 1234))
        self.server.sessions['phone'] = old
        with patch.object(helper, 'Server', return_value=self.server), patch.object(helper, '_read_line_or_timeout', side_effect=[b'close phone\n', b'']):
            await helper.serve(io.BytesIO())
        self.assertFalse(self.server.wanted)
        self.assertFalse(self.server.sessions)
        self.assertTrue(old.closed)


class NativeFallbackTests(unittest.IsolatedAsyncioTestCase):
    """tunneld lost the phone; Apple's tunnel (pymobiledevice3 11+) still reaches it."""

    async def asyncSetUp(self):
        self.server = helper.Server()
        for target, value in [('native_supported', True), ('Session', FakeSession)]:
            patcher = patch.object(helper, target, return_value=value) if target == 'native_supported' else patch.object(helper, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    async def test_missing_tunnel_falls_back_to_apple_tunnel(self):
        with patch.object(helper, 'tunnel_address', side_effect=RuntimeError('No tunnel')):
            session, reused = await self.server.session('phone')
        self.assertEqual(session.address, helper.NATIVE)
        self.assertEqual(session.udid, 'phone')
        self.assertFalse(reused)
        self.assertIn('phone', self.server.wanted)

    async def test_dead_tunneld_tunnel_falls_back_to_apple_tunnel(self):
        class DeadTunneld(FakeSession):
            async def open(self):
                if self.address != helper.NATIVE:
                    raise ConnectionResetError('tunnel gone')
        with patch.object(helper, 'Session', DeadTunneld), patch.object(helper, 'tunnel_address', return_value=('fd00::1', 1234)):
            session, _ = await self.server.session('phone')
        self.assertEqual(session.address, helper.NATIVE)

    async def test_both_failing_reports_both(self):
        class Unreachable(FakeSession):
            async def open(self):
                raise OSError('Device not found')
        with patch.object(helper, 'Session', Unreachable), patch.object(helper, 'tunnel_address', side_effect=RuntimeError('No tunnel')):
            with self.assertRaises(RuntimeError) as raised:
                await self.server.session('phone')
        self.assertIn('No tunnel', str(raised.exception))
        self.assertIn('Device not found', str(raised.exception))
        self.assertNotIn('phone', self.server.sessions)

    async def test_apple_tunnel_session_survives_tunneld_coming_back(self):
        native = FakeSession(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = native
        self.server.wanted['phone'] = asyncio.get_running_loop().time() - 60
        with patch.object(helper, 'list_tunnels', return_value=tunnels()):
            await self.server.refresh()
            session, reused = await self.server.session('phone')
        self.assertIs(session, native)
        self.assertTrue(reused)
        self.assertFalse(native.closed)
        self.assertIn('phone', self.server.wanted)

    async def test_refresh_moves_lost_device_to_apple_tunnel(self):
        old = FakeSession(('old', 1234), 'phone')
        self.server.sessions['phone'] = old
        self.server.wanted['phone'] = asyncio.get_running_loop().time()
        with patch.object(helper, 'list_tunnels', return_value={}):
            await self.server.refresh()
        self.assertTrue(old.closed)
        self.assertEqual(self.server.sessions['phone'].address, helper.NATIVE)

    async def test_background_fallback_is_rate_limited_and_device_expires(self):
        attempts = []
        class Unreachable(FakeSession):
            async def open(self):
                attempts.append(self.address)
                raise OSError('Device not found')
        self.server.wanted['phone'] = asyncio.get_running_loop().time()
        with patch.object(helper, 'Session', Unreachable), patch.object(helper, 'list_tunnels', return_value={}):
            await self.server.refresh()
            await self.server.refresh()
            self.assertEqual(attempts, [helper.NATIVE])
            self.server.wanted['phone'] -= 60
            await self.server.refresh()
        self.assertNotIn('phone', self.server.wanted)

    async def test_list_replies_with_reachable_phones(self):
        out = io.BytesIO()
        with patch.object(helper, 'browse_native', AsyncMock(return_value={'phone': 'Noah’s iPhone'})) as browse, \
                patch.object(helper, '_read_line_or_timeout', side_effect=[b'list\n', b'list\n', b'']), \
                patch.object(helper, 'Server', return_value=self.server):
            await helper.serve(out)
        payload = json.dumps({'phone': 'Noah’s iPhone'}).encode()
        frame = b'J' + len(payload).to_bytes(4, 'big') + payload
        self.assertEqual(out.getvalue(), frame + frame)
        self.assertEqual(browse.await_count, 1, 'second list within the TTL uses the cache')

    async def test_apple_tunnel_first_even_when_tunneld_has_the_phone(self):
        lookup = unittest.mock.Mock(return_value=('fd00::1', 1234))
        with patch.object(helper, 'tunnel_address', lookup):
            session, _ = await self.server.session('phone')
        self.assertEqual(session.address, helper.NATIVE)
        lookup.assert_not_called()

    async def test_tunneld_is_the_fallback_when_apple_tunnel_fails(self):
        class NoAppleTunnel(FakeSession):
            async def open(self):
                if self.address == helper.NATIVE:
                    raise OSError('Device not found')
        with patch.object(helper, 'Session', NoAppleTunnel), patch.object(helper, 'tunnel_address', return_value=('fd00::1', 1234)):
            session, _ = await self.server.session('phone')
        self.assertEqual(session.address, ('fd00::1', 1234))

    async def test_tunneld_fallback_moves_back_to_apple_tunnel(self):
        fallback = FakeSession(('fd00::1', 1234), 'phone')
        self.server.sessions['phone'] = fallback
        self.server.wanted['phone'] = asyncio.get_running_loop().time()
        await self.server.refresh()
        self.assertEqual(self.server.sessions['phone'].address, helper.NATIVE)
        self.assertTrue(fallback.closed)

    async def test_failed_apple_tunnel_attempt_keeps_working_fallback(self):
        class NoAppleTunnel(FakeSession):
            async def open(self):
                if self.address == helper.NATIVE:
                    raise OSError('Device not found')
        fallback = FakeSession(('fd00::1', 1234), 'phone')
        self.server.sessions['phone'] = fallback
        self.server.wanted['phone'] = asyncio.get_running_loop().time()
        with patch.object(helper, 'Session', NoAppleTunnel), patch.object(helper, 'list_tunnels', return_value={'phone': [{'tunnel-address': 'fd00::1', 'tunnel-port': 1234}]}):
            await self.server.refresh()
        self.assertIs(self.server.sessions['phone'], fallback)
        self.assertFalse(fallback.closed)

    async def test_unreachable_phone_backs_off_to_five_minutes(self):
        class Unreachable(FakeSession):
            async def open(self):
                raise OSError('Device not found')
        due = []
        with patch.object(helper, 'Session', Unreachable):
            now = 1000.0
            for _ in range(7):
                await self.server.warm_native('phone', now)
                now = self.server.native_next['phone']
                due.append(self.server.native_backoff['phone'])
        self.assertEqual(due, [30, 60, 120, 240, 300, 300, 300])

    async def test_idle_probe_replaces_dead_connection(self):
        class Dead(FakeSession):
            async def probe(self):
                raise ConnectionResetError('gone')
        dead = Dead(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = dead
        self.server.wanted['phone'] = asyncio.get_running_loop().time()
        await self.server.refresh()
        self.assertTrue(dead.closed)
        self.assertIsNot(self.server.sessions['phone'], dead)
        self.assertEqual(self.server.sessions['phone'].address, helper.NATIVE)

    async def test_recently_used_connection_is_not_probed_until_mac_wakes(self):
        session = FakeSession(helper.NATIVE, 'phone')
        session.checked_at = asyncio.get_running_loop().time()
        self.server.sessions['phone'] = session
        self.server.wanted['phone'] = session.checked_at
        await self.server.refresh()
        self.assertEqual(session.probes, 0)
        self.server.last_wall -= 3600  # an hour passed on the wall clock: the Mac slept
        await self.server.refresh()
        self.assertEqual(session.probes, 1)

    async def test_capture_counts_as_a_liveness_check(self):
        session = FakeSession(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = session
        await self.server.capture('phone')
        self.assertGreater(session.checked_at, float('-inf'))

    async def test_slow_screenshot_on_a_live_connection_is_waited_for(self):
        class Slow(FakeSession):
            async def get_screenshot(self):
                await asyncio.sleep(0.05)
                return b'big png'
        session = Slow(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = session
        with patch.object(helper, '_PROBE_TIMEOUT', 0.01):
            png = await self.server.capture('phone')
        self.assertEqual(png, b'big png')
        self.assertFalse(session.closed, 'the probe answered, so the connection is kept')

    async def test_too_slow_screenshot_on_a_live_connection_is_not_retried(self):
        class Endless(FakeSession):
            opened = 0

            async def open(self):
                Endless.opened += 1

            async def get_screenshot(self):
                await asyncio.sleep(3600)
        session = Endless(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = session
        with patch.object(helper, '_PROBE_TIMEOUT', 0.01), patch.object(helper, '_CAPTURE_TIMEOUT', 0.02), \
                patch.object(helper, 'Session', Endless):
            with self.assertRaises(asyncio.TimeoutError):
                await self.server.capture('phone')
        self.assertTrue(session.closed)
        self.assertEqual(Endless.opened, 0, 'a new connection would be just as slow')

    async def test_probe_still_in_flight_after_the_screenshot_is_left_to_finish(self):
        class SlowProbe(FakeSession):
            async def probe(self):
                await asyncio.sleep(0.02)
                self.probes += 1
        session = SlowProbe(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = session
        await self.server.capture('phone')
        self.assertEqual(session.probes, 0)
        await asyncio.sleep(0.05)
        self.assertEqual(session.probes, 1)
        self.assertFalse(session.closed)

    async def test_dead_connection_is_replaced_after_the_probe_times_out(self):
        class Dead(FakeSession):
            async def probe(self):
                await asyncio.sleep(3600)

            async def get_screenshot(self):
                await asyncio.sleep(3600)
        dead = Dead(helper.NATIVE, 'phone')
        self.server.sessions['phone'] = dead
        with patch.object(helper, '_PROBE_TIMEOUT', 0.01):
            png = await self.server.capture('phone')
        self.assertEqual(png, b'png')
        self.assertTrue(dead.closed)
        self.assertIsNot(self.server.sessions['phone'], dead)

    async def test_caps_reports_apple_tunnel_support(self):
        out = io.BytesIO()
        with patch.object(helper, '_read_line_or_timeout', side_effect=[b'caps\n', b'']), \
                patch.object(helper, 'Server', return_value=self.server):
            await helper.serve(out)
        payload = b'{"native": true}'
        self.assertEqual(out.getvalue(), b'J' + len(payload).to_bytes(4, 'big') + payload)

    async def test_stale_list_answers_at_once_and_refreshes_in_background(self):
        release = asyncio.Event()
        calls = []
        async def browse():
            calls.append(1)
            if len(calls) > 1:
                await release.wait()
                return {'phone': 'Renamed'}
            return {'phone': 'Noah'}
        with patch.object(helper, 'browse_native', side_effect=browse):
            self.assertEqual(await self.server.native_devices(), {'phone': 'Noah'})
            self.server.native_listed_at -= helper._NATIVE_LIST_TTL + 1
            stale = await asyncio.wait_for(self.server.native_devices(), 0.1)
            self.assertEqual(stale, {'phone': 'Noah'}, 'stale cache returned without waiting')
            await self.server.native_devices()
            # Let the scheduled refresh start. asyncio.wait_for stopped
            # yielding to the loop in Python 3.12, so nothing else does.
            await asyncio.sleep(0)
            self.assertEqual(len(calls), 2, 'one background refresh, not one per request')
            release.set()
            await self.server.native_list_task
        self.assertEqual(self.server.native_list, {'phone': 'Renamed'})

    async def test_browse_keeps_only_authenticated_reachable_real_phones(self):
        def device(udid, connection='available', auth='authenticated', virtual=False):
            return {'udid': udid, 'name': udid.upper(), 'virtual': virtual,
                    'connectionState': {'rawCase': connection}, 'authState': {'rawCase': auth}}
        fake = types.ModuleType('pymobiledevice3.remote.native_tunnel')
        fake.browse_native_devices = AsyncMock(return_value=[
            device('a'), device('b', connection='connected'), device('c', connection='unavailable'),
            device('d', auth='unpaired'), device('e', virtual=True),
        ])
        with patch.dict(sys.modules, {'pymobiledevice3.remote.native_tunnel': fake}):
            self.assertEqual(await helper.browse_native(), {'a': 'A', 'b': 'B'})


if __name__ == '__main__':
    unittest.main()
