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
    list         phones macOS's own pairing daemon can reach (see below)
    caps         {"native": bool}, whether macOS's own tunnel can be used

Every request gets one reply on stdout: a kind byte, a big-endian UInt32
payload length, then the payload. Kinds: b"P" PNG bytes, b"K" warm finished,
b"J" UTF-8 JSON, b"E" UTF-8 error message.

Two ways to reach a phone, in order:

1. macOS's own tunnel (pymobiledevice3 11+ on macOS). macOS keeps a tunnel to
   paired phones (remoted, the one Xcode uses for wireless debugging), and
   `NativeRemotedTunnel` rides it without root. It needs no tunneld, finds a
   phone tunneld has lost, and doesn't add tunneld's keep-alive traffic.
2. tunneld, for older pymobiledevice3 or when Apple's tunnel can't reach the
   phone. tunneld finds Wi-Fi phones only through Bonjour, which a locked phone
   on a busy network may stop sending; then only a USB cable brought it back.
   It also rebuilds its tunnels every few minutes on new addresses, so while
   idle the helper follows moved tunnels.

While no requests arrive the helper keeps the connection ready: every
_PROBE_EVERY seconds, and right after the Mac wakes, it sends a tiny DVT
request and replaces a dead connection in the background, so the first
capture after a quiet stretch doesn't pay for the reconnect. A phone that
can't be reached is retried with backoff, up to _NATIVE_RETRY_MAX apart.

The helper exits when its stdin closes or when it has had no devices to keep
warm for _EMPTY_EXIT_AFTER seconds. A device whose tunnel stays gone that long
is forgotten, so one that never comes back can't leave a python process
resident forever.
"""

from __future__ import annotations

import asyncio
import contextlib
import functools
from importlib import metadata
import json
import os
from pathlib import Path
import re
import select
import struct
import sys
import time
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
# Opening Apple's tunnel takes about 2 s (XPC to remotepairingd plus a nettop
# sample to find the RSD port). Kept so a stale reuse, this, a tunneld attempt
# and a fresh capture still fit the app's 30 s watchdog.
_NATIVE_CONNECT_TIMEOUT = 8
# Background retries for a phone Apple's tunnel can't reach start this far
# apart and double up to the max, so an absent phone costs almost nothing.
_NATIVE_RETRY = 30
_NATIVE_RETRY_MAX = 300
# remotepairingd's browse always runs for its full timeout.
_NATIVE_BROWSE_TIMEOUT = 1.0
# After this long, a `list` request answers from the cache and refreshes it in
# the background.
_NATIVE_LIST_TTL = 10

# A kept-open connection can die in place, for example when the phone or the
# Mac sleeps, without its tunnel moving. Idle sessions are checked this often
# with a tiny DVT request, so a dead one is replaced in the background instead
# of costing the next capture a timeout plus a reconnect.
_PROBE_EVERY = 60
_PROBE_TIMEOUT = 3
# Wall-clock time between idle polls beyond this means the Mac probably slept;
# every session is checked at once.
_WAKE_GAP = 30

# Session address for a connection that rides macOS's own tunnel.
NATIVE = "native"


@functools.cache
def native_supported() -> bool:
    """macOS with a pymobiledevice3 that can piggyback Apple's tunnel (11+)."""
    if sys.platform != "darwin":
        return False
    try:
        from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel  # noqa: F401
    except ImportError:
        return False
    return True


def describe(address) -> str:
    return "Apple's tunnel" if address == NATIVE else "tunneld"


def reason(error: BaseException) -> str:
    """Timeouts stringify to nothing; name them instead."""
    return str(error) or type(error).__name__


def require_supported_engine() -> None:
    requirement = Path(__file__).with_name("requirements-wireless.txt").read_text()
    minimum = re.search(r"^pymobiledevice3==(\d+)\.(\d+)\.(\d+)$", requirement, re.MULTILINE)
    if minimum is None:
        raise RuntimeError("Wi-Fi engine requirement is missing. Reinstall TetherShot.")
    try:
        installed = metadata.version("pymobiledevice3")
    except metadata.PackageNotFoundError:
        installed = "0.0.0"
    numbers = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", installed)
    if numbers is None or tuple(map(int, numbers.groups())) < tuple(map(int, minimum.groups())):
        raise RuntimeError("Wi-Fi engine is outdated. Run iPhone Wi-Fi Repair in TetherShot's Connections settings.")


class Session:
    def __init__(self, address: tuple[str, int] | str, udid: str | None = None) -> None:
        self.address = address
        self.udid = udid
        self._stack = contextlib.AsyncExitStack()
        self.screenshot: Screenshot | None = None
        self._dvt = None
        self._device_info = None
        # Loop time this connection was last known to work.
        self.checked_at = float("-inf")

    async def probe(self) -> None:
        """Cheap liveness check: a few bytes over the open DVT connection."""
        if self._device_info is None:
            from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo

            self._device_info = await self._stack.enter_async_context(DeviceInfo(self._dvt))
        await self._device_info.mach_time_info()

    async def open(self) -> None:
        require_supported_engine()
        from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

        if self.address == NATIVE:
            from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel

            # Holds an assertion that keeps Apple's tunnel up until closed.
            rsd = await self._stack.enter_async_context(NativeRemotedTunnel(serial=self.udid))
        else:
            rsd = await self._stack.enter_async_context(RemoteServiceDiscoveryService(self.address))
        dvt = await self._stack.enter_async_context(DvtProvider(rsd))
        self._dvt = dvt
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


def _case(value) -> str | None:
    return value.get("rawCase") if isinstance(value, dict) else None


async def browse_native() -> dict[str, str]:
    """UDID -> name for phones macOS's pairing daemon can reach right now."""
    from pymobiledevice3.remote.native_tunnel import browse_native_devices

    devices = await browse_native_devices(timeout=_NATIVE_BROWSE_TIMEOUT)
    return {
        device["udid"]: device.get("name") or ""
        for device in devices
        if device.get("udid")
        and not device.get("virtual")
        and _case(device.get("authState")) == "authenticated"
        and _case(device.get("connectionState")) in ("available", "connected")
    }


class Server:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}
        # Devices the app asked about -> when their tunnel was last seen. These
        # are kept warm in the background even while their session is closed.
        self.wanted: dict[str, float] = {}
        # Background attempts at Apple's tunnel: when the next one is due and
        # the current backoff, per device.
        self.native_next: dict[str, float] = {}
        self.native_backoff: dict[str, float] = {}
        self.native_failing: set[str] = set()
        self.native_list: dict[str, str] = {}
        self.native_listed_at = float("-inf")
        self.native_list_task: asyncio.Task | None = None
        self.last_wall = time.time()

    async def check_sessions(self) -> None:
        """Drops connections that died while idle so refresh can replace them.

        Without this a dead connection is only found by the next capture,
        which then waits out _REUSED_CAPTURE_TIMEOUT before reconnecting.
        """
        now = asyncio.get_running_loop().time()
        wall = time.time()
        woke = wall - self.last_wall > _IDLE_POLL + _WAKE_GAP
        self.last_wall = wall
        for udid, session in list(self.sessions.items()):
            if not woke and now - session.checked_at < _PROBE_EVERY:
                continue
            try:
                await asyncio.wait_for(session.probe(), _PROBE_TIMEOUT)
            except Exception:
                print(f"connection to {udid} via {describe(session.address)} went stale; reconnecting",
                      file=sys.stderr, flush=True)
                await self.drop(udid)
                # Let refresh try Apple's tunnel again right away.
                self.native_next.pop(udid, None)
                self.native_backoff.pop(udid, None)
                continue
            session.checked_at = asyncio.get_running_loop().time()

    async def refresh(self) -> None:
        """Keeps wanted devices connected while no requests arrive.

        Idle connections are checked first, so a dead one is replaced here
        rather than during the next capture. Apple's tunnel is preferred: a
        device without it is retried there (with backoff), which also moves a
        tunneld fallback back once Apple's tunnel works again. Otherwise the
        tunneld fallback follows moved tunnels. A device reachable by neither
        for _EMPTY_EXIT_AFTER seconds is forgotten.
        """
        if not self.wanted:
            return
        await self.check_sessions()
        now = asyncio.get_running_loop().time()
        tunnels = None
        tunneld_reachable = False
        for udid in list(self.wanted):
            current = self.sessions.get(udid)
            if current is not None and current.address == NATIVE:
                self.wanted[udid] = now
                continue
            if native_supported() and await self.warm_native(udid, now):
                continue
            if not tunneld_reachable:
                # Only ask tunneld when a device actually needs it.
                try:
                    tunnels = await asyncio.to_thread(list_tunnels)
                except Exception:
                    tunnels = None
                tunneld_reachable = True
            address = first_address(tunnels, udid) if tunnels is not None else None
            if address is not None:
                self.wanted[udid] = now
                if current is not None and current.address == address:
                    continue
                try:
                    await self.open_tunneld(udid, address)
                    print(f"reconnected {udid} via tunneld", file=sys.stderr, flush=True)
                except Exception as error:
                    print(f"background reconnect to {udid} failed: {reason(error)}", file=sys.stderr, flush=True)
                continue
            if tunnels is None:
                # Discovery outages must not retain sessionless devices forever.
                if current is None and now - self.wanted[udid] >= _EMPTY_EXIT_AFTER:
                    del self.wanted[udid]
                continue
            # Tunnels briefly vanish while tunneld rebuilds them. Keep the
            # device wanted through that gap and only give up after a while.
            if now - self.wanted[udid] >= _EMPTY_EXIT_AFTER:
                del self.wanted[udid]
                await self.drop(udid)

    async def warm_native(self, udid: str, now: float) -> bool:
        """Background attempt at Apple's tunnel, with backoff. True if open."""
        if now < self.native_next.get(udid, float("-inf")):
            return False
        try:
            await self.open_native(udid)
        except Exception as error:
            backoff = min(self.native_backoff.get(udid, _NATIVE_RETRY / 2) * 2, _NATIVE_RETRY_MAX)
            self.native_backoff[udid] = backoff
            self.native_next[udid] = now + backoff
            if udid not in self.native_failing:
                self.native_failing.add(udid)
                print(f"Apple's tunnel can't reach {udid}: {reason(error)}", file=sys.stderr, flush=True)
            return False
        return True

    async def open_native(self, udid: str) -> Session:
        """Opens Apple's tunnel and only then replaces any existing session,
        so a failed attempt never costs a working tunneld fallback."""
        session = Session(NATIVE, udid)
        try:
            await asyncio.wait_for(session.open(), _NATIVE_CONNECT_TIMEOUT)
        except BaseException:
            await session.close()
            raise
        await self.drop(udid)
        session.checked_at = asyncio.get_running_loop().time()
        self.sessions[udid] = session
        self.wanted[udid] = session.checked_at
        self.native_failing.discard(udid)
        self.native_next.pop(udid, None)
        self.native_backoff.pop(udid, None)
        print(f"connected to {udid} via Apple's tunnel", file=sys.stderr, flush=True)
        return session

    async def open_tunneld(self, udid: str, address: tuple[str, int] | None = None) -> Session:
        if address is None:
            address = await asyncio.to_thread(tunnel_address, udid)
        await self.drop(udid)
        session = Session(address, udid)
        try:
            await asyncio.wait_for(session.open(), _CONNECT_TIMEOUT)
        except BaseException:
            await session.close()
            raise
        session.checked_at = asyncio.get_running_loop().time()
        self.sessions[udid] = session
        self.wanted[udid] = session.checked_at
        return session

    async def session(self, udid: str) -> tuple[Session, bool]:
        """Returns the device's session and whether it was already open.

        Apple's tunnel is tried first where available, then tunneld. A tunneld
        session is reused while tunneld still lists the same tunnel; tunneld
        recreates tunnels on new addresses, so a changed or missing address
        means it is dead and is dropped, so disappeared phones don't leave
        connections resident.
        """
        self.wanted.setdefault(udid, asyncio.get_running_loop().time())
        current = self.sessions.get(udid)
        if current is not None and current.address == NATIVE:
            return current, True
        address = None
        if current is not None:
            try:
                address = await asyncio.to_thread(tunnel_address, udid)
            except Exception:
                address = None
            if address == current.address:
                return current, True
            await self.drop(udid)
        return await self.connect(udid, address), False

    async def connect(self, udid: str, tunneld_address: tuple[str, int] | None = None) -> Session:
        apple_error = None
        if native_supported():
            try:
                return await self.open_native(udid)
            except Exception as error:
                apple_error = error
        try:
            session = await self.open_tunneld(udid, tunneld_address)
        except Exception as error:
            if apple_error is None:
                await self.drop(udid)
                raise
            raise RuntimeError(
                f"Apple's tunnel: {reason(apple_error)}; tunneld: {reason(error)}"
            ) from error
        if apple_error is not None:
            print(f"connected to {udid} via tunneld (Apple's tunnel: {reason(apple_error)})",
                  file=sys.stderr, flush=True)
        return session

    async def native_devices(self) -> dict[str, str]:
        """Phones Apple's tunnel can reach.

        Browsing always takes its full second, and the app asks on the hotkey
        path, so only the first request waits for it. Later ones answer from
        the cache at once and refresh it in the background when it is stale.
        """
        if not native_supported():
            return {}
        if self.native_listed_at == float("-inf"):
            await self.refresh_native_list()
        elif asyncio.get_running_loop().time() - self.native_listed_at >= _NATIVE_LIST_TTL:
            if self.native_list_task is None or self.native_list_task.done():
                self.native_list_task = asyncio.create_task(self.refresh_native_list())
        return self.native_list

    async def refresh_native_list(self) -> None:
        try:
            self.native_list = await browse_native()
        except Exception as error:
            print(f"listing phones via Apple's tunnel failed: {reason(error)}", file=sys.stderr, flush=True)
        self.native_listed_at = asyncio.get_running_loop().time()

    async def drop(self, udid: str) -> None:
        session = self.sessions.pop(udid, None)
        if session is not None:
            await session.close()

    async def capture(self, udid: str) -> bytes:
        session, reused = await self.session(udid)
        if reused:
            try:
                png = await asyncio.wait_for(
                    session.screenshot.get_screenshot(), _REUSED_CAPTURE_TIMEOUT
                )
                self.log_shot(session)
                return png
            except Exception:
                # The phone may have slept or dropped the channel without the
                # tunnel moving, or remoted evicted our RSD connection on
                # Apple's tunnel. Reconnect once before reporting a failure.
                await self.drop(udid)
                session, _ = await self.session(udid)
        try:
            png = await asyncio.wait_for(
                session.screenshot.get_screenshot(), _FRESH_CAPTURE_TIMEOUT
            )
        except BaseException:
            await self.drop(udid)
            raise
        self.log_shot(session)
        return png

    @staticmethod
    def log_shot(session: Session) -> None:
        # A capture proves the connection works; no need to probe it soon.
        session.checked_at = asyncio.get_running_loop().time()
        print(f"shot via {describe(session.address)}", file=sys.stderr, flush=True)


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
                elif command == "list":
                    reply(out, b"J", json.dumps(await server.native_devices()).encode())
                elif command == "caps":
                    # Lets the app treat Wi-Fi as ready without tunneld.
                    reply(out, b"J", json.dumps({"native": native_supported()}).encode())
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
