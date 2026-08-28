#!/usr/bin/env python3
"""Keep one DVT connection open and stream low-latency preview frames."""

import asyncio
import io
import itertools
import json
import struct
import sys
import urllib.request

from PIL import Image
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

_REQUESTS_IN_FLIGHT = 3
_PREVIEW_MAXIMUM_SIZE = (1000, 2400)
_PREVIEW_JPEG_QUALITY = 70


def make_preview_frame(png: bytes) -> bytes:
    """Downscale device PNGs before crossing the local process pipe."""
    with Image.open(io.BytesIO(png)) as image:
        image.thumbnail(_PREVIEW_MAXIMUM_SIZE, Image.Resampling.BILINEAR)
        output = io.BytesIO()
        image.convert("RGB").save(
            output,
            format="JPEG",
            quality=_PREVIEW_JPEG_QUALITY,
            optimize=False,
        )
        return output.getvalue()


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
            sequence = itertools.count()
            latest_emitted = -1
            write_lock = asyncio.Lock()

            async def capture_frames() -> None:
                nonlocal latest_emitted
                while True:
                    request_sequence = next(sequence)
                    # Keeping several requests in flight roughly doubles the
                    # frame cadence on Wi-Fi iPhones. Encoding is moved off the
                    # event loop so it does not delay the next device request.
                    png = await screenshot.get_screenshot()
                    frame = await asyncio.to_thread(make_preview_frame, png)

                    async with write_lock:
                        # A newer request can finish first. Never send an older
                        # result afterwards and make the preview jump backward.
                        if request_sequence <= latest_emitted:
                            continue
                        latest_emitted = request_sequence
                        sys.stdout.buffer.write(struct.pack(">I", len(frame)))
                        sys.stdout.buffer.write(frame)
                        sys.stdout.buffer.flush()

            await asyncio.gather(
                *(capture_frames() for _ in range(_REQUESTS_IN_FLIGHT))
            )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: wireless-preview.py UDID")
    asyncio.run(stream(sys.argv[1]))
