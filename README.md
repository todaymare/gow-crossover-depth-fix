# God of War CrossOver Depth Fix

Removes the fine white specks on Kratos in **God of War (2018)** under CrossOver by relaxing `EQUAL` depth tests to `GREATER_EQUAL`.

**[Download the macOS installer](https://github.com/todaymare/gow-crossover-depth-fix/releases/latest/download/gow-crossover-depth-fix-macos.zip)** · [All releases and checksums](https://github.com/todaymare/gow-crossover-depth-fix/releases/latest) · [Report a problem](https://github.com/todaymare/gow-crossover-depth-fix/issues)

## Quick install

1. Quit God of War. In CrossOver, select **D3DMetal** as the game's bottle graphics backend; it restored the lighting in our tested setup.
2. Download and unzip the release. Open **God of War Depth Fix.app**, choose **Install**, and select your **GoW.exe**. If asked, select its CrossOver bottle and CrossOver app.
3. Check the paths in the confirmation, install, then launch the game normally through CrossOver.

The download contains a universal Apple Silicon/Intel installer for **macOS 13 or later**, the proxy DLL, and manual-install files. CrossOver and the game must already be installed. No build tools are needed to use the download.

**The installer is ad-hoc signed, not Developer ID signed or notarized. macOS may block it.** Only run software you trust; source and release checksums are provided. If you cannot open the app, use the manual installation below rather than changing system-wide security settings.

The installer backs up the existing DLL, toggle file, and game-specific registry override before changing them. It does not change graphics/HDR settings, saves, or folder ownership. The game folder must be writable; for a protected folder, use the manual Finder copy below. Keep its recovery data in `~/Library/Application Support/God of War Depth Fix/` until you uninstall.

## What is verified

- Real God of War main-menu A/B verification on an Apple M2 Max with CrossOver 26.3: specks returned with the fix off and disappeared with it on, while D3DMetal kept the scene lit.
- Real CrossOver D3DMetal and DXMT API checks: state substitution, live toggling, stencil preservation, and bound-state lifetime.
- Installer round trips in disposable real CrossOver bottles: install/reinstall/uninstall through case-alias paths, original file restoration, and preservation of empty/absent registry values, string types, and whitespace. In-use executables, protected folders, wrong bottles, and concurrent operations were rejected.

Gameplay still needs broader testing. Relaxing the depth comparison can affect occlusion: watch for objects drawing through characters or other geometry. Report the game/CrossOver/macOS versions, graphics backend, and whether toggling the fix changes the problem. DXMT is also supported by the proxy, but the tested game had overly dark lighting with that backend.

## Toggle the fix while playing

Open `gow_proxy_depth.txt` next to `GoW.exe` in a plain-text editor:

- `2` — enabled (default).
- `0` — original depth behavior.

Save the file. The proxy checks for changes about every 250 ms while depth states are bound; recorded deferred command lists retain their recorded state. No game restart is normally needed for this comparison.

## Uninstall

Quit the game. Open **God of War Depth Fix.app**, choose **Uninstall**, and select the same `GoW.exe` and bottle. It restores the original files and game-specific override from its backup. Keep the app/recovery data until removal is complete.

If you installed manually, restore your own backed-up files and previous registry override instead.

## Manual installation

1. Quit the game and select its graphics backend in CrossOver; **D3DMetal is recommended** for the lighting issue.
2. Open the release's **Manual install** folder. Back up any existing `d3d11.dll` and `gow_proxy_depth.txt` next to `GoW.exe`, then copy the two supplied files there. Record any existing game-specific `d3d11` override before changing it.
3. In CrossOver, select the game's bottle, open **Run Command**, and run:

   ```text
   reg add "HKCU\Software\Wine\AppDefaults\GoW.exe\DllOverrides" /v d3d11 /t REG_SZ /d native,builtin /f
   ```

4. Launch normally. The proxy loads the selected backend's `d3d11.dll` directly from the bottle's system directory, keeping it matched to the installed CrossOver runtime.

To remove a manual installation, quit the game, remove the supplied files, and restore your backups and original override. If there was no original game-specific override, remove just the value added above using the same bottle's Run Command:

```text
reg delete "HKCU\Software\Wine\AppDefaults\GoW.exe\DllOverrides" /v d3d11 /f
```

The app's uninstall option requires a backup created by the app; it cannot reconstruct a manual installation's prior state.

## How it works

A local D3D11 proxy forwards device creation to CrossOver's selected system D3D11 implementation. It intercepts `CreateDepthStencilState`, creates `GREATER_EQUAL` variants of `EQUAL` states, and binds the variant in `OMSetDepthStencilState` while enabled. Other depth and stencil settings are preserved. The original COM objects keep their identities; `OMGetDepthStencilState` reports the state actually bound.

This is a game-specific workaround for exact-depth comparison artifacts, not a translator-level vertex-invariance fix. CrossOver, the game, and their graphics runtimes are not included.

## Build from source

On macOS with Xcode Command Line Tools and Homebrew:

```sh
brew install mingw-w64
make
make verify.exe
make release VERSION=0.1.0
```

`make release` produces `dist/gow-crossover-depth-fix-macos.zip` and `dist/SHA256SUMS.txt`. The installer is built for both arm64 and x86_64. GitHub Actions also builds the download from source.

To run the graphics behavior checks, use a CrossOver bottle configured with the desired backend:

```sh
"/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine" \
  --bottle YOUR_BOTTLE --no-gui --dll 'd3d11=n,b' \
  --workdir "$PWD" "$PWD/verify.exe"
```

The verifier changes the toggle file in its working directory and leaves it enabled. Run from the source/build directory, not the game directory.

To exercise installer recovery against a disposable real CrossOver bottle:

```sh
python3 tests/verify_installer.py
```

This uses the built ZIP and `verify.exe`, tests file/registry restoration and safety boundaries, and removes its own temporary bottle. Use `--crossover /path/to/CrossOver.app` for a nonstandard installation.

## Credits and license

An independent implementation of the depth-test workaround described in [this community investigation](https://www.reddit.com/r/macgaming/comments/1x3samb/god_of_war_2018_white_dot_fix_through_crossover/), with D3DMetal-compatible hooking and system-backend forwarding. This is not the original post author's binary or an official CodeWeavers, DXMT, Apple, or game-vendor patch.

[MIT license](LICENSE). Provided without warranty.
