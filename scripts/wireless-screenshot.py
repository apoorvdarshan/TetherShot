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

The helper exits when its stdin closes or when it has held no sessions for
_EMPTY_EXIT_AFTER seconds, so a device that never comes back can't leave a
python process resident forever.
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

from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

_TUNNELD_URL = "http://127.0.0.1:49151/"
_CONNECT_TIMEOUT = 6
_REUSED_CAPTURE_TIMEOUT = 3
_FRESH_CAPTURE_TIMEOUT = 6
_CLOSE_TIMEOUT = 1.5
# How long to keep running with no open sessions before exiting. The client
# restarts the helper on the next request, so this only bounds idle residency.
_EMPTY_EXIT_AFTER = 30
# How often the read loop wakes up to check whether it should exit.
_IDLE_POLL = 5


class Session:
    def __init__(self, address: tuple[str, int]) -> None:
        self.address = address
        self._stack = contextlib.AsyncExitStack()
        self.screenshot: Screenshot | None = None

    async def open(self) -> None:
        rsd = await self._stack.enter_async_context(RemoteServiceDiscoveryService(self.address))
        dvt = await self._stack.enter_async_context(DvtProvider(rsd))
        self.screenshot = await self._stack.enter_async_context(Screenshot(dvt))

    async def close(self) -> None:
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self._stack.aclose(), 2)


def tunnel_address(udid: str) -> tuple[str, int]:
    with urllib.request.urlopen(_TUNNELD_URL, timeout=2) as response:
        tunnels = json.load(response)
    candidates = tunnels.get(udid) or []
    if not candidates:
        raise RuntimeError("No tunnel to this device. Is it on the same Wi-Fi and is tunneld running?")
    # Match `--tunnel UDID`, which uses the first tunnel tunneld reports.
    tunnel = candidates[0]
    return tunnel["tunnel-address"], int(tunnel["tunnel-port"])


class Server:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}

    async def session(self, udid: str) -> tuple[Session, bool]:
        """Returns the device's session and whether it was already open.

        tunneld recreates a tunnel on a new address when Wi-Fi drops, so a
        changed address means the cached connection is dead. A device with no
        tunnel at all also drops any cached session, so disappeared phones
        don't leave connections resident.
        """
        try:
            address = tunnel_address(udid)
        except Exception:
            await self.drop(udid)
            raise
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


async def serve(out) -> None:
    server = Server()
    idle_since = asyncio.get_running_loop().time()
    while True:
        # Poll stdin so an idle helper with no sessions can retire on its own
        # instead of staying resident until the client drops it.
        line = await asyncio.to_thread(_read_line_or_timeout, _IDLE_POLL)
        if line is None:
            if not server.sessions and (
                asyncio.get_running_loop().time() - idle_since >= _EMPTY_EXIT_AFTER
            ):
                break
            continue
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
                await server.drop(udid)
                reply(out, b"K", b"")
            else:
                reply(out, b"E", f"Unknown request: {command}".encode())
        except Exception as error:
            message = str(error) or type(error).__name__
            reply(out, b"E", message.encode())
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
