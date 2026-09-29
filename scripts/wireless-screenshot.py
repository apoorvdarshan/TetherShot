#!/usr/bin/env python3
"""Keep DVT screenshot connections open so Wi-Fi captures skip setup.

A one-shot `pymobiledevice3 developer dvt screenshot` pays for Python startup,
the RemoteXPC handshake and opening the instruments channel on every capture,
which is most of its time. This helper stays running and reuses one connection
per device.

Requests arrive on stdin, one per line:
    warm UDID    open (or verify) the connection without capturing
    shot UDID    capture a PNG
    close UDID   drop the connection for a device that went away

Every request gets one reply on stdout: a kind byte, a big-endian UInt32
payload length, then the payload. Kinds: b"P" PNG bytes, b"K" warm finished,
b"E" UTF-8 error message.

tunneld rebuilds Wi-Fi tunnels every few minutes, each on a new address. While
no requests arrive, the helper checks tunneld every _IDLE_POLL seconds and
reconnects any device whose tunnel moved, so the first capture after a quiet
stretch doesn't pay for the reconnect.

The helper exits when its stdin closes or when it has had no devices to keep
warm for _EMPTY_EXIT_AFTER seconds. A device whose tunnel stays gone that long
is forgotten, so one that never comes back can't leave a python process
resident forever.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import select
import struct
import sys
import urllib.request


_TUNNELD_URL = "http://127.0.0.1:49151/"
_CONNECT_TIMEOUT = 6
_REUSED_CAPTURE_TIMEOUT = 3
_FRESH_CAPTURE_TIMEOUT = 6
_CLOSE_TIMEOUT = 1.5
# How long to keep running with no devices to keep warm before exiting, and how
# long a device's tunnel may stay missing before it is forgotten. The client
# restarts the helper on the next request, so this only bounds idle residency.
_EMPTY_EXIT_AFTER = 30
# How often the read loop wakes up to follow moved tunnels and check whether
# it should exit.
_IDLE_POLL = 5


class Session:
    def __init__(self, address: tuple[str, int]) -> None:
        self.address = address
        self._stack = contextlib.AsyncExitStack()
        self.screenshot: Screenshot | None = None

    async def open(self) -> None:
        from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

        rsd = await self._stack.enter_async_context(RemoteServiceDiscoveryService(self.address))
        dvt = await self._stack.enter_async_context(DvtProvider(rsd))
        self.screenshot = await self._stack.enter_async_context(Screenshot(dvt))

    async def close(self) -> None:
        async def cleanup():
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self._stack.aclose(), _CLOSE_TIMEOUT)
        task = asyncio.create_task(cleanup())
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            # A capture can interrupt refresh while it closes an old session.
            # Complete bounded cleanup before letting that capture proceed.
            await task
            raise


def list_tunnels() -> dict:
    with urllib.request.urlopen(_TUNNELD_URL, timeout=2) as response:
        return json.load(response)


def first_address(tunnels: dict, udid: str) -> tuple[str, int] | None:
    candidates = tunnels.get(udid) or []
    if not candidates:
        return None
    # Match `--tunnel UDID`, which uses the first tunnel tunneld reports.
    tunnel = candidates[0]
    return tunnel["tunnel-address"], int(tunnel["tunnel-port"])


def tunnel_address(udid: str) -> tuple[str, int]:
    address = first_address(list_tunnels(), udid)
    if address is None:
        raise RuntimeError("No tunnel to this device. Is it on the same Wi-Fi and is tunneld running?")
    return address


class Server:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}
        # Devices the app asked about -> when their tunnel was last seen. These
        # are kept warm in the background even while their session is closed.
        self.wanted: dict[str, float] = {}

    async def refresh(self) -> None:
        """Reconnects wanted devices whose tunnel moved or whose session failed.

        Runs only between requests. A device whose tunnel has been missing for
        _EMPTY_EXIT_AFTER seconds is forgotten.
        """
        if not self.wanted:
            return
        try:
            tunnels = await asyncio.to_thread(list_tunnels)
        except Exception:
            # Discovery outages must not retain sessionless devices forever.
            now = asyncio.get_running_loop().time()
            for udid in list(self.wanted):
                if udid not in self.sessions and now - self.wanted[udid] >= _EMPTY_EXIT_AFTER:
                    del self.wanted[udid]
            return
        now = asyncio.get_running_loop().time()
        for udid in list(self.wanted):
            address = first_address(tunnels, udid)
            if address is None:
                # Tunnels briefly vanish while tunneld rebuilds them. Keep the
                # device wanted through that gap and only give up after a while.
                if now - self.wanted[udid] >= _EMPTY_EXIT_AFTER:
                    del self.wanted[udid]
                    await self.drop(udid)
                continue
            self.wanted[udid] = now
            current = self.sessions.get(udid)
            if current is not None and current.address == address:
                continue
            try:
                await self.session(udid)
                print(f"reconnected {udid} after its tunnel moved", file=sys.stderr, flush=True)
            except Exception as error:
                print(f"background reconnect to {udid} failed: {error}", file=sys.stderr, flush=True)

    async def session(self, udid: str) -> tuple[Session, bool]:
        """Returns the device's session and whether it was already open.

        tunneld recreates a tunnel on a new address when Wi-Fi drops, so a
        changed address means the cached connection is dead. A device with no
        tunnel at all also drops any cached session, so disappeared phones
        don't leave connections resident.
        """
        self.wanted.setdefault(udid, asyncio.get_running_loop().time())
        try:
            address = await asyncio.to_thread(tunnel_address, udid)
        except Exception:
            await self.drop(udid)
            raise
        self.wanted[udid] = asyncio.get_running_loop().time()
        current = self.sessions.get(udid)
        if current is not None and current.address == address:
            return current, True
        await self.drop(udid)
        session = Session(address)
        try:
            await asyncio.wait_for(session.open(), _CONNECT_TIMEOUT)
        except BaseException:
            await session.close()
            raise
        self.sessions[udid] = session
        return session, False

    async def drop(self, udid: str) -> None:
        session = self.sessions.pop(udid, None)
        if session is not None:
            await session.close()

    async def capture(self, udid: str) -> bytes:
        session, reused = await self.session(udid)
        if reused:
            try:
                return await asyncio.wait_for(
                    session.screenshot.get_screenshot(), _REUSED_CAPTURE_TIMEOUT
                )
            except Exception:
                # The phone may have slept or dropped the channel without the
                # tunnel moving. Reconnect once before reporting a failure.
                await self.drop(udid)
                session, _ = await self.session(udid)
        try:
            return await asyncio.wait_for(
                session.screenshot.get_screenshot(), _FRESH_CAPTURE_TIMEOUT
            )
        except BaseException:
            await self.drop(udid)
            raise


def reply(out, kind: bytes, payload: bytes) -> None:
    out.write(kind + struct.pack(">I", len(payload)) + payload)
    out.flush()


async def stop_refresh(task) -> None:
    """Finish cancellation before handling commands that mutate sessions."""
    if task is not None:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


async def serve(out) -> None:
    server = Server()
    refresh_task = None
    idle_since = asyncio.get_running_loop().time()
    try:
        while True:
            # Read commands while reconnects run. A command interrupts the
            # refresh, so it never waits through every device's timeout.
            line = await asyncio.to_thread(_read_line_or_timeout, _IDLE_POLL)
            if line is None:
                if refresh_task is None or refresh_task.done():
                    if refresh_task is not None:
                        await refresh_task
                    refresh_task = asyncio.create_task(server.refresh())
                if not server.wanted and (
                    asyncio.get_running_loop().time() - idle_since >= _EMPTY_EXIT_AFTER
                ):
                    break
                continue
            await stop_refresh(refresh_task)
            refresh_task = None
            if not line:
                break
            idle_since = asyncio.get_running_loop().time()
            command, _, udid = line.decode().strip().partition(" ")
            try:
                if command == "warm":
                    await server.session(udid)
                    reply(out, b"K", b"")
                elif command == "shot":
                    reply(out, b"P", await server.capture(udid))
                elif command == "close":
                    server.wanted.pop(udid, None)
                    await server.drop(udid)
                    reply(out, b"K", b"")
                else:
                    reply(out, b"E", f"Unknown request: {command}".encode())
            except Exception as error:
                message = str(error) or type(error).__name__
                reply(out, b"E", message.encode())
    finally:
        await stop_refresh(refresh_task)
        for udid in list(server.sessions):
            await server.drop(udid)


def _read_line_or_timeout(timeout: float) -> bytes | None:
    """Reads one stdin line, returning None (not EOF) when nothing arrived."""
    if not select.select([sys.stdin.buffer], [], [], timeout)[0]:
        return None
    return sys.stdin.buffer.readline()


if __name__ == "__main__":
    # Replies own the real stdout. Anything else that prints (library logging,
    # warnings) goes to stderr so it cannot corrupt the framing.
    protocol_out = os.fdopen(os.dup(sys.stdout.fileno()), "wb")
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    asyncio.run(serve(protocol_out))
