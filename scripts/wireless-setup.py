#!/usr/bin/env python3
"""Install-time helpers. Pairing credentials never leave this Mac or reach stdout."""
from __future__ import annotations

import argparse
import asyncio
import os
from pathlib import Path
import plistlib
import pwd
import re
import sys
import uuid

LABEL = "com.apoorvdarshan.tethershot.tunneld"


def requirement(path: Path) -> str:
    lines = [line.strip() for line in path.read_text().splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if len(lines) != 1 or not re.fullmatch(r"pymobiledevice3==\d+\.\d+\.\d+", lines[0]):
        raise ValueError("Invalid bundled wireless dependency requirement")
    return lines[0]


def has_discovery_key(record: Path) -> bool:
    if record.is_symlink():
        raise ValueError("Pairing records must not be symbolic links")
    if not record.exists():
        return False
    key = plistlib.loads(record.read_bytes()).get("peer_alt_irk")
    return isinstance(key, bytes) and len(key) == 16


async def refresh_pairing(record: Path, service, completed_error: type[Exception]) -> None:
    """Keep current pairings; back up legacy keys before a trusted migration.

    Pair-setup replaces the peer key on the phone. Preserve any newly written
    record on failure too, so recovery never discards either set of credentials.
    """
    if has_discovery_key(record):
        return
    backup = None
    backups = record.parent / "backups"
    if backups.is_symlink():
        raise ValueError("Pairing backup directory must not be a symbolic link")
    backups.mkdir(mode=0o700, exist_ok=True)
    backups.chmod(0o700)
    if record.exists():
        backup = backups / f"{record.stem}-{uuid.uuid4().hex}.plist"
        record.chmod(0o600)
        record.rename(backup)
    try:
        try:
            await asyncio.wait_for(service.connect(autopair=True), 20)
        except completed_error:
            pass  # Successful pair-setup normally closes the control connection.
        if not has_discovery_key(record):
            raise RuntimeError("The refreshed pairing record has no Wi-Fi discovery key")
        record.chmod(0o600)
    except BaseException:
        if record.exists():
            record.chmod(0o600)
            record.rename(backups / f"{record.stem}-incomplete-{uuid.uuid4().hex}.plist")
        if backup is not None:
            backup.rename(record)
        raise


def repair_ownership(uid: int) -> None:
    """Repair files left root-owned by old installs; never follow symbolic links."""
    if os.geteuid() != 0 or uid <= 0:
        raise PermissionError("Ownership repair requires admin access and a normal user")
    user = pwd.getpwuid(uid)
    home = Path(user.pw_dir)
    cache = home / ".pymobiledevice3"
    environment = home / ".local/share/tethershot/wireless"
    for path in (cache, environment):
        for ancestor in (path, *path.parents):
            if ancestor == home:
                break
            if ancestor.is_symlink():
                raise ValueError("Wireless setup directories must not be symbolic links")
    if cache.exists():
        os.chown(cache, uid, user.pw_gid, follow_symlinks=False)
        for record in cache.glob("remote_*.plist"):
            if record.is_symlink():
                continue
            os.chown(record, uid, user.pw_gid, follow_symlinks=False)
            record.chmod(0o600)
    if environment.exists():
        for root, dirs, files in os.walk(environment, followlinks=False):
            for path in (Path(root), *(Path(root) / name for name in dirs + files)):
                if path.lstat().st_uid == 0:
                    os.chown(path, uid, user.pw_gid, follow_symlinks=False)


async def repair_pairings() -> str:
    from pymobiledevice3.exceptions import RemotePairingCompletedError
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService
    from pymobiledevice3.usbmux import list_devices

    cache = Path.home() / ".pymobiledevice3"
    for serial in dict.fromkeys(device.serial for device in await list_devices()):
        # Use devices already trusted by this Mac; never trigger initial pairing.
        if not re.fullmatch(r"[A-Za-z0-9-]+", serial):
            continue
        record = cache / f"remote_{serial}.plist"
        if has_discovery_key(record):
            continue
        lockdown = await asyncio.wait_for(create_using_usbmux(serial=serial, autopair=False), 8)
        try:
            service = await asyncio.wait_for(RemotePairingLockdownService.create(lockdown), 5)
            try:
                await refresh_pairing(record, service, RemotePairingCompletedError)
            finally:
                await asyncio.wait_for(service.close(), 2)
        finally:
            await asyncio.wait_for(lockdown.close(), 2)
    stale = any(not has_discovery_key(record) for record in cache.glob("remote_*.plist"))
    if stale:
        return "Wi-Fi service installed. Older disconnected devices may need a USB connection and Repair."
    return "Wi-Fi service installed and pairing records are up to date."


def daemon_plist(home: Path, pmd3: Path) -> dict:
    return {
        "Label": LABEL,
        # Network usbmux/mobdev2 sync sessions can repeatedly displace the
        # screenshot tunnel. Use RemotePairing Wi-Fi discovery and USB NCM.
        "ProgramArguments": [str(pmd3), "remote", "tunneld", "--no-usbmux", "--no-mobdev2"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": "/tmp/tethershot-tunneld.log",
        "StandardErrorPath": "/tmp/tethershot-tunneld.log",
        "EnvironmentVariables": {
            "HOME": str(home),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            # Root must not leave bytecode in the user's managed environment.
            "PYTHONDONTWRITEBYTECODE": "1",
        },
    }


def main() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("requirement", "ownership", "pairings", "plist"))
    parser.add_argument("--uid", type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.action == "requirement":
        print(requirement(Path(__file__).with_name("requirements-wireless.txt")))
    elif args.action == "ownership":
        repair_ownership(args.uid or 0)
    elif args.action == "pairings":
        print(asyncio.run(repair_pairings()))
    elif args.action == "plist":
        if args.output is None:
            parser.error("plist requires --output")
        home = Path.home()
        pmd3 = home / ".local/share/tethershot/wireless/bin/pymobiledevice3"
        args.output.write_bytes(plistlib.dumps(daemon_plist(home, pmd3)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Pairing-library exception payloads may include private device data.
        print(f"Wireless setup failed ({type(error).__name__}). Connect the iPhone by USB, "
              "unlock it, and run Repair again. Existing pairing backups were preserved.", file=sys.stderr)
        sys.exit(1)
