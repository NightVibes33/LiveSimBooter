#!/usr/bin/env python3
"""Fail-closed, offline preflight for a fully staged iOS Simulator 26.0 23A343 RuntimeRoot.

Checks the project's pinned cache layout and embedded CMS signature, loader
Mach-O types/signature presence, guest helper, capabilities and signing team.
Passing this check is NOT iOS kernel code-signing acceptance or a guest boot.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PATHS = {
    "dyld_sim": ("usr/lib/dyld_sim", 7),
    "launchd_sim": ("sbin/launchd_sim", 2),
    "spawn_shim": ("usr/lib/libLiveSimSpawn.dylib", 6),
}
CACHE = "System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64"
CAPABILITIES = "Library/Developer/CoreSimulator/DeviceType/capabilities.plist"
MAX_CODE_SIG = 10 * 1024 * 1024


def fail(issues, field, detail):
    issues.append({"stage": field, "problem": str(detail)})


def macho(path, expected):
    with path.open("rb") as stream:
        header = stream.read(32)
        if len(header) != 32:
            raise ValueError("Missing Mach-O header")
        magic, cpu, subtype, filetype, commands, sizeofcmds, flags, reserved = struct.unpack("<8I", header)
        if magic != 0xfeedfacf or cpu != 0x0100000c or filetype != expected:
            raise ValueError(f"Expected thin arm64 file type {expected}; got cpu={cpu:#x} type={filetype}")
        if commands > 4096 or sizeofcmds < 16 or sizeofcmds > 2 * 1024 * 1024:
            raise ValueError("Invalid Mach-O load-command bounds")
        if 32 + sizeofcmds > path.stat().st_size:
            raise ValueError("Truncated Mach-O load commands")
        blob = stream.read(sizeofcmds)
        offset, signature = 0, None
        for _ in range(commands):
            if offset + 8 > len(blob):
                raise ValueError("Truncated load command")
            command, size = struct.unpack_from("<II", blob, offset)
            if size < 8 or offset + size > len(blob):
                raise ValueError("Invalid load-command length")
            if command == 0x1d:
                if size < 16 or signature is not None:
                    raise ValueError("Malformed/duplicate code-signature command")
                signature = struct.unpack_from("<II", blob, offset + 8)
            offset += size
        if offset != len(blob):
            raise ValueError("Mach-O load-command table did not terminate exactly")
        if not signature:
            raise ValueError("Missing embedded LC_CODE_SIGNATURE")
        sig_offset, sig_size = signature
        if not (0 < sig_size <= MAX_CODE_SIG and sig_offset >= 32 + sizeofcmds
                and sig_offset + sig_size <= path.stat().st_size):
            raise ValueError("Invalid embedded code-signature range")
        stream.seek(sig_offset)
        superblob = stream.read(min(sig_size, MAX_CODE_SIG))
        return signature_slots(superblob)


def signature_slots(data):
    if len(data) < 12:
        raise ValueError("Truncated signature SuperBlob")
    magic, length, count = struct.unpack_from(">III", data)
    if magic != 0xfade0cc0 or not (12 + count * 8 <= length <= len(data)):
        raise ValueError("Invalid signature SuperBlob")
    kinds, spans = set(), []
    for i in range(count):
        kind, pos = struct.unpack_from(">II", data, 12 + i * 8)
        if pos < 12 + count * 8 or pos + 8 > length or kind in kinds:
            raise ValueError("Invalid signature slot index")
        body_magic, size = struct.unpack_from(">II", data, pos)
        if size < 8 or pos + size > length or any(not(pos+size <= a or pos >= b) for a,b in spans):
            raise ValueError("Invalid signature slot overlap or length")
        if kind == 0 and body_magic != 0xfade0c02:
            raise ValueError("Invalid CodeDirectory magic")
        if kind == 0x10000 and body_magic != 0xfade0b01:
            raise ValueError("Invalid CMS magic")
        spans.append((pos, pos+size))
        kinds.add(kind)
    if 0 not in kinds or 0x10000 not in kinds:
        raise ValueError("Missing CodeDirectory or CMS signature; ad-hoc signing alone is insufficient")
    return {"slots": sorted(kinds), "cms_present": True}


def code_sign(path, expected_team):
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--verbose=4", str(path)],
                            capture_output=True, text=True, timeout=100)
    if result.returncode:
        raise ValueError("macOS codesign verification failed: " + (result.stderr or result.stdout)[-500:])
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)],
                            capture_output=True, text=True, timeout=100)
    metadata = result.stderr + result.stdout
    team_lines = [line for line in metadata.splitlines() if line.startswith("TeamIdentifier=")]
    if not team_lines or team_lines[-1].partition("=")[2] != expected_team:
        raise ValueError(f"Code signing team differs from expected {expected_team}")
    return {"codesign_verified_mac": True, "team": expected_team}


def verify(root, expected_team, verify_codesign):
    issues, found = [], {}
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("RuntimeRoot is not a directory")
    for label, (rel, expected_type) in PATHS.items():
        path = root / rel
        try:
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
                raise ValueError("Missing, unsafe symlink, or nonregular executable")
            record = macho(path, expected_type)
            if verify_codesign:
                record.update(code_sign(path, expected_team))
            found[label] = record
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            fail(issues, rel, error)
    path = root / CACHE
    try:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError("Missing, unsafe symlink, or nonregular simulator shared cache")
        spec = importlib.util.spec_from_file_location("signed_guest_cache_inspector", ROOT / "Tools/sign-dyld-cache.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        offset, size, mappings = module.cache_info(path)
        slots, used = module.signature_slots(path, offset)
        if not {0, 2, 0x10000}.issubset(slots):
            raise ValueError("Signed dyld cache does not have CodeDirectory, requirements and CMS")
        if verify_codesign:
            signature = code_sign(path, expected_team)
        else:
            signature = {"codesign_verified_mac": False}
        found["shared_cache"] = {
            "signed_region_length": offset,
            "signature_size": used,
            "mappings": len(mappings),
            "cms_present": True, **signature
        }
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        fail(issues, CACHE, error)
    try:
        capabilities = root / CAPABILITIES
        if capabilities.is_symlink() or not capabilities.is_file() or not capabilities.resolve().is_relative_to(root):
            raise ValueError("Missing or symlinked device capabilities")
        with capabilities.open("rb") as data:
            plist = plistlib.load(data)
        if not isinstance(plist, dict) or len(plist) == 0:
            raise ValueError("Invalid or empty device capabilities plist")
        found["capabilities"] = {"readable": True}
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        fail(issues, CAPABILITIES, error)
    return {
        "runtime_build": "23A343",
        "expected_team": expected_team,
        "offline_checks_pass": not issues,
        "mac_codesign_checks_enabled": verify_codesign,
        "device_kernel_signature_acceptance_verified": False,
        "usb_extension_access_verified": False,
        "guest_boot_verified": False,
        "present": found, "issues": issues,
        "note": "This report cannot replace real iPhone code-signing, external filesystem, or guest launchd_sim/SpringBoard tests."
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--runtime-root", type=Path, required=True)
    p.add_argument("--expected-team", required=True)
    p.add_argument("--verify-macos-codesign", action="store_true")
    p.add_argument("--output", type=Path, help="Optional JSON report path, never overwrites an existing file")
    args = p.parse_args()
    if not args.expected_team or len(args.expected_team) > 128 or any(c.isspace() for c in args.expected_team):
        p.error("Invalid expected signing team")
    try:
        result = verify(args.runtime_root, args.expected_team, args.verify_macos_codesign)
    except (OSError, ValueError) as exc:
        sys.exit(f"offline guest preflight: {exc}")
    serialized = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        with args.output.open("x") as out:
            out.write(serialized)
    print(serialized)
    return 0 if result["offline_checks_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
