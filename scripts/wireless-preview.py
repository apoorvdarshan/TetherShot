#!/usr/bin/env python3
"""Keep one DVT connection open and stream length-prefixed PNG frames."""

import asyncio
import json
import struct
import sys
import urllib.request

from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot


async def stream(udid: str) -> None:
    with urllib.request.urlopen("http://127.0.0.1:49151/", timeout=2) as response:
        tunnels = json.load(response)
    candidates = tunnels.get(udid) or []
    if not candidates:
        raise RuntimeError(f"No active tunnel for {udid}")

    tunnel = candidates[0]
    address = (tunnel["tunnel-address"], int(tunnel["tunnel-port"]))
    async with RemoteServiceDiscoveryService(address) as rsd:
        async with DvtProvider(rsd) as dvt, Screenshot(dvt) as screenshot:
            while True:
                png = await screenshot.get_screenshot()
                sys.stdout.buffer.write(struct.pack(">I", len(png)))
                sys.stdout.buffer.write(png)
                sys.stdout.buffer.flush()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: wireless-preview.py UDID")
    asyncio.run(stream(sys.argv[1]))
