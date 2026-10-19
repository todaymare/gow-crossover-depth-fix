# God of War CrossOver Depth Fix 0.1.0

Download **gow-crossover-depth-fix-macos.zip** below, unzip it, and open **God of War Depth Fix.app**. Quit God of War before installing. Select the game's GoW.exe and confirm the target. D3DMetal is recommended for correct lighting in the tested setup.

- Original D3D11 depth proxy for CrossOver's D3DMetal and DXMT backends.
- EQUAL-to-GREATER_EQUAL depth-state substitution, with live 0/2 toggling.
- Native universal macOS installer and reversible uninstall with backups.
- Manual-install DLL and instructions included in the same download.
- Uses the selected system graphics runtime; no proprietary runtime is bundled.

**Verification:** real God of War main-menu on/off/on comparison with D3DMetal; API regression checks on real D3DMetal and DXMT. Gameplay has not been verified; watch for geometry incorrectly drawing through other geometry and report issues with versions/backend.

**Requirements:** macOS 13+, CrossOver, and God of War (2018). The installer is ad-hoc signed, not notarized; macOS may block it. Use the included manual-install instructions if you cannot open the app, without weakening system-wide security settings.

`SHA256SUMS.txt` contains the download checksum. Source is MIT-licensed. Community workaround credit and implementation details are in the README.
