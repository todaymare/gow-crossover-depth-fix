#!/usr/bin/env python3
"""Exercise real installer recovery in a disposable CrossOver bottle (macOS)."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KEY = r"HKCU\Software\Wine\AppDefaults\GoW.exe\DllOverrides"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--archive", type=Path, default=ROOT / "dist/gow-crossover-depth-fix-macos.zip")
parser.add_argument("--crossover", type=Path, default=Path("/Applications/CrossOver.app"))
args = parser.parse_args()
wine = args.crossover / "Contents/SharedSupport/CrossOver/bin/wine"
cxbottle = wine.with_name("cxbottle")
assert wine.is_file() and cxbottle.is_file(), "Select an installed CrossOver.app."
assert (ROOT / "verify.exe").is_file(), "Run make verify.exe first."


def command(argv, success=True):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True, timeout=180)
    if success and result.returncode:
        raise RuntimeError(f"Command failed: {argv}\n{result.stdout}\n{result.stderr}")
    return result


temporary = Path(tempfile.mkdtemp(prefix="gow-depth-installer-")).resolve()
bottle = temporary / "bottle"
game = bottle / "drive_c/Games/Installer Smoke/GoW.exe"
recovery = Path.home() / "Library/Application Support/God of War Depth Fix" / hashlib.sha256(str(game).encode()).hexdigest()
try:
    command(["/usr/bin/ditto", "-x", "-k", args.archive.resolve(), temporary / "download"])
    app = temporary / "download/God of War Depth Fix/God of War Depth Fix.app/Contents/MacOS/God of War Depth Fix"
    assert app.is_file(), "Release archive is missing the installer app."
    command([cxbottle, "--bottle", bottle, "--create", "--template", "win10_64"])
    game.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / "verify.exe", game)
    dll = game.with_name("d3d11.dll")
    mode = game.with_name("gow_proxy_depth.txt")

    def registry(*options, success=True):
        return command([wine, "--bottle", bottle, "--no-gui", "reg", *options], success)

    def value():
        result = registry("query", KEY, "/v", "d3d11", success=False)
        if result.returncode:
            assert "unable to find" in (result.stdout + result.stderr).lower()
            return None
        line = next(line for line in result.stdout.splitlines() if line.startswith("    d3d11    "))
        return tuple(line[len("    d3d11    "):].split("    ", 1))

    def action(operation, selected=game, success=True):
        return command([app, operation, selected, "--bottle", bottle, "--crossover", args.crossover, "--yes"], success)

    def round_trip(expected):
        action("--install")
        action("--uninstall")
        assert value() == expected, "Original registry value/type changed."
        assert not dll.exists() and not mode.exists(), "Uninstall did not restore the initially empty folder."

    dll.write_bytes(b"original third-party proxy\n")
    mode.write_bytes(b"0\n")
    registry("add", KEY, "/v", "d3d11", "/t", "REG_SZ", "/d", "builtin  ,  native", "/f")
    action("--install")
    alias = game.with_name("gow.exe")
    selected = alias if alias.exists() else game
    action("--install", selected)
    action("--uninstall", selected)
    assert dll.read_bytes() == b"original third-party proxy\n" and mode.read_bytes() == b"0\n"
    assert value() == ("REG_SZ", "builtin  ,  native")
    print("PASS reinstall/uninstall preserves initial files and override, including case aliases where supported.")
    dll.unlink()
    mode.unlink()

    for kind, data in [("REG_SZ", ""), ("REG_EXPAND_SZ", "  %PRESERVE_ME%  native  ")]:
        registry("add", KEY, "/v", "d3d11", "/t", kind, "/d", data, "/f")
        round_trip((kind, data))
    registry("delete", KEY, "/v", "d3d11", "/f")
    round_trip(None)
    print("PASS empty/absent registry values, types, and whitespace restored exactly.")

    recovery.mkdir(parents=True, exist_ok=True)
    with (recovery / "operation.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = action("--install", success=False)
        assert result.returncode and "already running" in result.stderr
    with game.open("rb") as held:
        result = action("--install", success=False)
        assert result.returncode and "in use" in result.stderr
    os.chmod(game.parent, 0o555)
    try:
        result = action("--install", success=False)
        assert result.returncode and "manual" in result.stderr.lower()
    finally:
        os.chmod(game.parent, 0o755)
    assert not dll.exists() and not mode.exists() and value() is None
    print("PASS concurrent, in-use, and protected-folder operations fail before mutation.")
finally:
    if bottle.exists():
        command([cxbottle, "--bottle", bottle, "--uninstall", "--delete", "--force"])
    if recovery.exists():
        shutil.rmtree(recovery)
    shutil.rmtree(temporary)
