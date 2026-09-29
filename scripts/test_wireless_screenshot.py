"""Run with: python3 -m unittest discover -s scripts -p 'test_*.py'.

Uses fake sessions and tunnel discovery; no phone or pymobiledevice3 required.
"""
import asyncio
import importlib.util
import io
from pathlib import Path
import threading
import unittest
from unittest.mock import AsyncMock, patch

spec = importlib.util.spec_from_file_location('wireless_screenshot', Path(__file__).with_name('wireless-screenshot.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def tunnels(address='new'):
    return {'phone': [{'tunnel-address': address, 'tunnel-port': 1234}]}


class FakeSession:
    def __init__(self, address):
        self.address = address
        self.closed = False
        self.screenshot = self

    async def open(self):
        pass

    async def close(self):
        self.closed = True

    async def get_screenshot(self):
        return b'png'


class ReconnectTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = helper.Server()
        self.server.wanted['phone'] = asyncio.get_running_loop().time()

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
        self.server.session = AsyncMock(side_effect=[TimeoutError(), (FakeSession(('new', 1234)), False)])
        with patch.object(helper, 'list_tunnels', return_value=tunnels()):
            await self.server.refresh()
            await self.server.refresh()
        self.assertEqual(self.server.session.await_count, 2)

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


if __name__ == '__main__':
    unittest.main()
