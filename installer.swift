import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import Foundation

private enum InstallerError: LocalizedError {
    case invalid(String)
    case command(String)
    case io(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .command(let message), .io(let message): return message
        case .cancelled: return "Selection cancelled."
        }
    }
}

private struct RegistryValue: Codable {
    let exists: Bool
    let type: String?
    let value: String?
}

private struct InstallState: Codable {
    let gamePath: String
    let bottlePath: String
    let hadDLL: Bool
    let hadMode: Bool
    let previousRegistry: RegistryValue
    var installedDLLSHA256: String
}
private struct FileSnapshot {
    let url: URL
    let existed: Bool
    let data: Data?
}

private struct TransactionSnapshot {
    let dll: FileSnapshot
    let mode: FileSnapshot
    let registry: RegistryValue
}

private enum DepthInstaller {
    static let registryKey = "HKCU\\Software\\Wine\\AppDefaults\\GoW.exe\\DllOverrides"
    static let registryValueName = "d3d11"
    static let installedRegistryType = "REG_SZ"
    static let installedRegistryValue = "native,builtin"
    static let supportFolder = "God of War Depth Fix"

    static func runCLI(_ arguments: [String]) -> Bool {
        do {
            guard let modeIndex = arguments.firstIndex(where: { $0 == "--install" || $0 == "--uninstall" }) else {
                throw InstallerError.invalid("Usage: God of War Depth Fix --install GAME --bottle BOTTLE --crossover APP [--yes] | --uninstall GAME --bottle BOTTLE --crossover APP [--yes]")
            }
            let action = arguments[modeIndex]
            func option(_ name: String) throws -> String {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                    throw InstallerError.invalid("Missing required option \(name).")
                }
                return arguments[index + 1]
            }
            let game = URL(fileURLWithPath: try option(action), isDirectory: false)
            let bottle = URL(fileURLWithPath: try option("--bottle"), isDirectory: true)
            let crossover = URL(fileURLWithPath: try option("--crossover"), isDirectory: true)
            let confirmed = arguments.contains("--yes")
            try perform(action: action == "--install" ? .install : .uninstall,
                        gameURL: game, bottleURL: bottle, crossoverURL: crossover,
                        confirmed: confirmed)
            print(action == "--install" ? "Installation completed." : "Uninstallation completed.")
            return true
        } catch {
            fputs("God of War Depth Fix: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    enum Action { case install, uninstall }

    static func perform(action: Action, gameURL: URL, bottleURL: URL, crossoverURL: URL, confirmed: Bool) throws {
        let game = try validateGame(gameURL)
        let bottle = try canonicalExistingPath(validateDirectory(bottleURL, label: "CrossOver bottle"))
        let crossover = try validateCrossOver(crossoverURL)
        try validateBottleForGame(game, selectedBottle: bottle)
        let stateURL = try stateURL(for: game)
        let lockDescriptor = try acquireLock(stateURL: stateURL)
        defer { _ = flock(lockDescriptor, LOCK_UN); _ = close(lockDescriptor) }
        try ensureGameNotRunning(game)
        let wine = crossover.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw InstallerError.invalid("The selected CrossOver application does not contain an executable CrossOver wine at Contents/SharedSupport/CrossOver/bin/wine.")
        }
        let dll = game.deletingLastPathComponent().appendingPathComponent("d3d11.dll")
        let mode = game.deletingLastPathComponent().appendingPathComponent("gow_proxy_depth.txt")
        try rejectSymlink(dll)
        try rejectSymlink(mode)
        try preflightGameFolderWrite(game.deletingLastPathComponent())
        switch action {
        case .install: try install(game: game, bottle: bottle, wine: wine, dll: dll, mode: mode, stateURL: stateURL, confirmed: confirmed)
        case .uninstall: try uninstall(game: game, bottle: bottle, wine: wine, dll: dll, mode: mode, stateURL: stateURL, confirmed: confirmed)
        }
    }

    static func confirmationDetails(action: Action, gameURL: URL, bottleURL: URL) throws -> String {
        let game = try validateGame(gameURL)
        let bottle = try canonicalExistingPath(validateDirectory(bottleURL, label: "CrossOver bottle"))
        try validateBottleForGame(game, selectedBottle: bottle)
        let dll = game.deletingLastPathComponent().appendingPathComponent("d3d11.dll")
        let stateURL = try stateURL(for: game)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let state = try loadState(stateURL)
            guard state.gamePath == game.path, state.bottlePath == bottle.path else {
                throw InstallerError.invalid("Installer recovery data is for a different game path or CrossOver bottle.")
            }
            if case .uninstall = action,
               FileManager.default.fileExists(atPath: dll.path),
               let data = try? Data(contentsOf: dll),
               sha256(data) != state.installedDLLSHA256 {
                return "WARNING: d3d11.dll has been modified since installation. Continuing will replace that modification with the backed-up original."
            }
            return "Your original files and registry setting are backed up. Reinstalling preserves the initial backup."
        }
        if case .install = action,
           FileManager.default.fileExists(atPath: dll.path) {
            return "WARNING: An existing d3d11.dll will be overwritten. Its original contents will be backed up for uninstall."
        }
        return "Only the game's d3d11 override and proxy files beside GoW.exe will be changed."
    }

    private static func validateBottleForGame(_ game: URL, selectedBottle: URL) throws {
        var cursor = game.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.lastPathComponent == "drive_c" {
                let inferred = cursor.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: inferred.appendingPathComponent("cxbottle.conf").path) {
                    let canonical = try canonicalExistingPath(inferred)
                    guard canonical.path == selectedBottle.path else {
                        throw InstallerError.invalid("The game is inside bottle \(canonical.path), but the selected bottle is \(selectedBottle.path). Choose the matching bottle.")
                    }
                    return
                }
            }
            cursor.deleteLastPathComponent()
        }
    }

    private static func acquireLock(stateURL: URL) throws -> Int32 {
        let directory = stateURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw InstallerError.io("Could not create installer recovery folder: \(error.localizedDescription)") }
        let lockURL = directory.appendingPathComponent("operation.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InstallerError.io("Could not open per-game installer lock: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let message = String(cString: strerror(errno))
            _ = close(descriptor)
            throw InstallerError.invalid("Another installer operation is already running for this game. Try again after it finishes. \(message)")
        }
        return descriptor
    }
    private static func preflightGameFolderWrite(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".gow-depth-fix-write-check-\(UUID().uuidString)")
        let descriptor = open(probe.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw InstallerError.io("The game folder is not writable by the current user. No changes were made. Use Finder to copy or restore the proxy files manually; this installer does not change permissions or request administrator access.")
        }
        _ = close(descriptor)
        do { try FileManager.default.removeItem(at: probe) }
        catch {
            throw InstallerError.io("Could not remove the temporary write-check file \(probe.path). Remove it manually before continuing. \(error.localizedDescription)")
        }
    }

    private static func install(game: URL, bottle: URL, wine: URL, dll: URL, mode: URL, stateURL: URL, confirmed: Bool) throws {
        let manager = FileManager.default
        let bundledDLL = Bundle.main.url(forResource: "d3d11", withExtension: "dll")
        let bundledMode = Bundle.main.url(forResource: "gow_proxy_depth", withExtension: "txt")
        guard let sourceDLL = bundledDLL, let sourceMode = bundledMode,
              let dllData = try? Data(contentsOf: sourceDLL), let modeData = try? Data(contentsOf: sourceMode) else {
            throw InstallerError.invalid("Required bundled resources d3d11.dll and gow_proxy_depth.txt are missing from the app Resources folder.")
        }
        let previousState: InstallState?
        if manager.fileExists(atPath: stateURL.path) {
            previousState = try loadState(stateURL)
            guard previousState?.gamePath == game.path, previousState?.bottlePath == bottle.path else { throw InstallerError.invalid("Installer recovery data is for a different game path or CrossOver bottle.") }
        } else {
            previousState = nil
            if (manager.fileExists(atPath: dll.path) || manager.fileExists(atPath: mode.path)) && !confirmed {
                throw InstallerError.invalid("An existing proxy file would be overwritten. Re-run with --yes, or approve the overwrite in the installer.")
            }
        }
        let transaction = try snapshot(game: game, dll: dll, mode: mode, wine: wine, bottle: bottle)
        if previousState == nil {
            try persistInitialBackup(stateURL: stateURL, game: game, bottle: bottle, dll: transaction.dll, mode: transaction.mode, registry: transaction.registry)
        }
        do {
            try atomicWrite(dllData, to: dll)
            try atomicWrite(modeData, to: mode)
            try setRegistry(wine: wine, bottle: bottle, value: RegistryValue(exists: true, type: installedRegistryType, value: installedRegistryValue))
            let old = previousState
            let state = InstallState(gamePath: game.path,
                                     bottlePath: bottle.path,
                                     hadDLL: old?.hadDLL ?? transaction.dll.existed,
                                     hadMode: old?.hadMode ?? transaction.mode.existed,
                                     previousRegistry: old?.previousRegistry ?? transaction.registry,
                                     installedDLLSHA256: sha256(dllData))
            try atomicWrite(try JSONEncoder().encode(state), to: stateURL)
        } catch let operationError {
            do { try restore(transaction, wine: wine, bottle: bottle) }
            catch let rollbackError {
                throw InstallerError.io("Install failed (\(operationError.localizedDescription)); rollback also failed (\(rollbackError.localizedDescription)). Recovery data was retained at \(stateURL.path).")
            }
            if previousState == nil { try? manager.removeItem(at: stateURL.deletingLastPathComponent()) }
            throw InstallerError.io("Install failed and was rolled back: \(operationError.localizedDescription)")
        }
    }

    private static func uninstall(game: URL, bottle: URL, wine: URL, dll: URL, mode: URL, stateURL: URL, confirmed: Bool) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: stateURL.path) else { throw InstallerError.invalid("No saved installation backup exists for this game. Nothing was changed.") }
        let state = try loadState(stateURL)
        guard state.gamePath == game.path, state.bottlePath == bottle.path else { throw InstallerError.invalid("Installer recovery data is for a different game path or CrossOver bottle.") }
        if manager.fileExists(atPath: dll.path), let data = try? Data(contentsOf: dll), sha256(data) != state.installedDLLSHA256, !confirmed {
            throw InstallerError.invalid("d3d11.dll has changed since installation. Uninstall would replace that modification; re-run with --yes, or approve restoration in the installer.")
        }
        let transaction = try snapshot(game: game, dll: dll, mode: mode, wine: wine, bottle: bottle)
        do {
            try restoreFile(from: backupURL(stateURL, name: "original-d3d11.dll"), existed: state.hadDLL, to: dll)
            try restoreFile(from: backupURL(stateURL, name: "original-gow_proxy_depth.txt"), existed: state.hadMode, to: mode)
            try setRegistry(wine: wine, bottle: bottle, value: state.previousRegistry)
            let backupDirectory = stateURL.deletingLastPathComponent()
            let retiredDirectory = backupDirectory.deletingLastPathComponent().appendingPathComponent("restored-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: backupDirectory, to: retiredDirectory)
            try? manager.removeItem(at: retiredDirectory)
        } catch let operationError {
            do { try restore(transaction, wine: wine, bottle: bottle) }
            catch let rollbackError {
                throw InstallerError.io("Uninstall failed (\(operationError.localizedDescription)); rollback also failed (\(rollbackError.localizedDescription)). Recovery data was retained at \(stateURL.path).")
            }
            throw InstallerError.io("Uninstall failed and was rolled back: \(operationError.localizedDescription)")
        }
    }

    private static func snapshot(game: URL, dll: URL, mode: URL, wine: URL, bottle: URL) throws -> TransactionSnapshot {
        func file(_ url: URL) throws -> FileSnapshot {
            let exists = FileManager.default.fileExists(atPath: url.path)
            return FileSnapshot(url: url, existed: exists, data: exists ? try Data(contentsOf: url) : nil)
        }
        return TransactionSnapshot(dll: try file(dll), mode: try file(mode), registry: try queryRegistry(wine: wine, bottle: bottle))
    }

    private static func restore(_ snapshot: TransactionSnapshot, wine: URL, bottle: URL) throws {
        try restoreSnapshotFile(snapshot.dll)
        try restoreSnapshotFile(snapshot.mode)
        try setRegistry(wine: wine, bottle: bottle, value: snapshot.registry)
    }

    private static func restoreSnapshotFile(_ snapshot: FileSnapshot) throws {
        if snapshot.existed, let data = snapshot.data { try atomicWrite(data, to: snapshot.url) }
        else if FileManager.default.fileExists(atPath: snapshot.url.path) { try FileManager.default.removeItem(at: snapshot.url) }
    }

    private static func persistInitialBackup(stateURL: URL, game: URL, bottle: URL, dll: FileSnapshot, mode: FileSnapshot, registry: RegistryValue) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if dll.existed, let data = dll.data { try atomicWrite(data, to: backupURL(stateURL, name: "original-d3d11.dll")) }
        if mode.existed, let data = mode.data { try atomicWrite(data, to: backupURL(stateURL, name: "original-gow_proxy_depth.txt")) }
        let state = InstallState(gamePath: game.path, bottlePath: bottle.path, hadDLL: dll.existed, hadMode: mode.existed, previousRegistry: registry, installedDLLSHA256: "")
        try atomicWrite(try JSONEncoder().encode(state), to: stateURL)
    }

    private static func restoreFile(from backup: URL, existed: Bool, to destination: URL) throws {
        if existed {
            guard FileManager.default.fileExists(atPath: backup.path) else { throw InstallerError.io("Required original-file backup is missing: \(backup.path)") }
            try atomicWrite(Data(contentsOf: backup), to: destination)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }

    private static func backupURL(_ stateURL: URL, name: String) -> URL { stateURL.deletingLastPathComponent().appendingPathComponent(name) }

    private static func queryRegistry(wine: URL, bottle: URL) throws -> RegistryValue {
        let result = try wineCommand(wine: wine, bottle: bottle, arguments: ["reg", "query", registryKey, "/v", registryValueName])
        guard result.status == 0 else {
            let errorText = result.output.lowercased()
            if ["unable to find", "cannot find", "not found", "no such key", "no such file"].contains(where: { errorText.contains($0) }) {
                return RegistryValue(exists: false, type: nil, value: nil)
            }
            throw InstallerError.command("CrossOver could not determine whether the game's d3d11 override exists (exit \(result.status)); no files were changed. Output: \(result.output)")
        }
        let pattern = #"(?m)^[ \t]*d3d11 {4}(REG_[A-Z0-9_]+) {4}(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: result.output, range: NSRange(result.output.startIndex..., in: result.output)),
              let typeRange = Range(match.range(at: 1), in: result.output),
              let valueRange = Range(match.range(at: 2), in: result.output) else {
            throw InstallerError.command("CrossOver returned success querying the d3d11 override but its type/value could not be parsed. No changes were made. Output: \(result.output)")
        }
        let type = String(result.output[typeRange])
        guard type == "REG_SZ" || type == "REG_EXPAND_SZ" else {
            throw InstallerError.command("The existing d3d11 override uses unsupported registry type \(type). No changes were made.")
        }
        return RegistryValue(exists: true, type: type, value: String(result.output[valueRange]))
    }

    private static func setRegistry(wine: URL, bottle: URL, value: RegistryValue) throws {
        if value.exists {
            guard let type = value.type, let content = value.value else { throw InstallerError.io("Saved registry value is incomplete; refusing to alter it.") }
            _ = try wineCommand(wine: wine, bottle: bottle, arguments: ["reg", "add", registryKey, "/v", registryValueName, "/t", type, "/d", content, "/f"], requireSuccess: true)
        } else {
            let result = try wineCommand(wine: wine, bottle: bottle, arguments: ["reg", "delete", registryKey, "/v", registryValueName, "/f"])
            // A missing value is already the desired state; other registry values are untouched.
            if result.status != 0 {
                let current = try queryRegistry(wine: wine, bottle: bottle)
                if current.exists { throw InstallerError.command("CrossOver could not remove the game's d3d11 override: \(result.output)") }
            }
        }
    }

    private static func wineCommand(wine: URL, bottle: URL, arguments: [String], requireSuccess: Bool = false) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = wine
        process.arguments = ["--bottle", bottle.path, "--no-gui"] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { throw InstallerError.command("Could not start selected CrossOver wine: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? "(non-UTF-8 command output)"
        if requireSuccess && process.terminationStatus != 0 {
            throw InstallerError.command("CrossOver registry command failed (exit \(process.terminationStatus)): \(output)")
        }
        return (process.terminationStatus, output)
    }

    private static func validateGame(_ url: URL) throws -> URL {
        let path = url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              path.lastPathComponent.caseInsensitiveCompare("GoW.exe") == .orderedSame else {
            throw InstallerError.invalid("Select an existing GoW.exe game executable.")
        }
        try rejectSymlink(path)
        let canonical = try canonicalExistingPath(path)
        try rejectSymlinkPathComponents(canonical)
        return canonical
    }

    private static func validateDirectory(_ url: URL, label: String) throws -> URL {
        let path = url
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &directory), directory.boolValue else {
            throw InstallerError.invalid("Selected \(label) folder does not exist or is not a directory: \(path.path)")
        }
        if label == "CrossOver bottle",
           !FileManager.default.fileExists(atPath: path.appendingPathComponent("cxbottle.conf").path) ||
           !FileManager.default.fileExists(atPath: path.appendingPathComponent("drive_c").path) {
            throw InstallerError.invalid("The selected folder is not a CrossOver bottle: it must contain cxbottle.conf and drive_c.")
        }
        return path
    }

    private static func validateCrossOver(_ url: URL) throws -> URL {
        let app = try validateDirectory(url, label: "CrossOver application")
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw InstallerError.invalid("Choose the installed CrossOver.app application bundle.")
        }
        return app
    }

    private static func rejectSymlink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw InstallerError.invalid("Refusing to modify symbolic link \(url.path). Choose a regular game folder and files.") }
    }
    private static func rejectSymlinkPathComponents(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            try rejectSymlink(current)
        }
    }
    private static func canonicalExistingPath(_ url: URL) throws -> URL {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InstallerError.io("Could not open selected path for canonicalization: \(url.path). \(String(cString: strerror(errno)))")
        }
        defer { _ = close(descriptor) }
        var path = [CChar](repeating: 0, count: 1024)
        let result = path.withUnsafeMutableBufferPointer {
            fcntl(descriptor, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!))
        }
        guard result >= 0 else {
            throw InstallerError.io("Could not determine the filesystem's canonical path for \(url.path).")
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: url.hasDirectoryPath)
    }

    private static func ensureGameNotRunning(_ game: URL) throws {
        // Wine maps the selected Windows executable as an open file. Checking
        // that exact file also handles case aliases and other installed copies.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", game.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 1 && output.isEmpty { return }
        if process.terminationStatus == 0 {
            throw InstallerError.invalid("The selected GoW.exe is in use. Quit that game and close other applications using its executable before installing or uninstalling.")
        }
        throw InstallerError.io("Could not check whether the selected GoW.exe is in use. No game files were changed. \(output)")
    }

    private static func stateURL(for game: URL) throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw InstallerError.io("Could not locate the current user's Application Support folder.")
        }
        let digest = SHA256.hash(data: Data(game.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return support.appendingPathComponent(supportFolder, isDirectory: true).appendingPathComponent(digest, isDirectory: true).appendingPathComponent("install-state.json")
    }

    private static func loadState(_ url: URL) throws -> InstallState {
        do { return try JSONDecoder().decode(InstallState.self, from: Data(contentsOf: url)) }
        catch { throw InstallerError.io("Could not read installer recovery data at \(url.path): \(error.localizedDescription)") }
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        try rejectSymlink(destination)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw InstallerError.io("Could not write \(destination.path). Check that the game folder is writable; the installer does not change permissions or use administrator privileges. \(error.localizedDescription)")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "God of War Depth Fix"
        alert.informativeText = "Quit God of War before installing or uninstalling.\n\nD3DMetal is recommended in CrossOver for correct lighting. This installer does not change your graphics or HDR settings."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { NSApp.terminate(nil); return }
        let action: DepthInstaller.Action = response == .alertFirstButtonReturn ? .install : .uninstall
        do {
            let game = try chooseGame()
            let bottle = try chooseBottle(for: game)
            let crossover = try chooseCrossOver()
            let actionName: String
            switch action {
            case .install: actionName = "Install"
            case .uninstall: actionName = "Uninstall"
            }
            let confirm = NSAlert()
            confirm.messageText = "\(actionName) God of War Depth Fix?"
            confirm.informativeText = "Game: \(game.path)\nBottle: \(bottle.path)\nCrossOver: \(crossover.path)\n\n\(try DepthInstaller.confirmationDetails(action: action, gameURL: game, bottleURL: bottle))"
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: actionName)
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
            try DepthInstaller.perform(action: action, gameURL: game, bottleURL: bottle, crossoverURL: crossover, confirmed: true)
            show(message: "\(actionName) completed successfully.", informative: action == .install ? "Launch God of War normally through CrossOver. The fix is enabled; gow_proxy_depth.txt beside GoW.exe controls it (2 = on, 0 = off)." : "Your original files and game-specific DLL override have been restored.")
        } catch InstallerError.cancelled {
            NSApp.terminate(nil)
            return
        } catch {
            show(message: "Could not complete the operation", informative: error.localizedDescription)
        }
        NSApp.terminate(nil)
    }

    private func chooseGame() throws -> URL {
        let panel = NSOpenPanel()
        panel.title = "Select GoW.exe"
        panel.message = "Choose the GoW.exe executable inside the selected game's folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let bottles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        if let game = defaultGameExecutable(in: bottles) {
            panel.directoryURL = game.deletingLastPathComponent()
            panel.nameFieldStringValue = game.lastPathComponent
        } else if FileManager.default.fileExists(atPath: bottles.path) {
            panel.directoryURL = bottles
        }
        guard panel.runModal() == .OK, let url = panel.url else { throw InstallerError.cancelled }
        return url
    }

    private func defaultGameExecutable(in bottles: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: bottles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        let relativeLocations = [
            "drive_c/Games/God of War/GoW.exe",
            "drive_c/Program Files (x86)/Steam/steamapps/common/God of War/GoW.exe"
        ]
        for bottle in entries {
            for relativePath in relativeLocations {
                let candidate = bottle.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private func chooseBottle(for game: URL) throws -> URL {
        var cursor = game.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.lastPathComponent == "drive_c", FileManager.default.fileExists(atPath: cursor.deletingLastPathComponent().appendingPathComponent("cxbottle.conf").path) {
                return cursor.deletingLastPathComponent()
            }
            cursor.deleteLastPathComponent()
        }
        let panel = NSOpenPanel()
        panel.title = "Select CrossOver bottle"
        panel.message = "Could not infer a bottle from the game path. Choose the CrossOver bottle folder containing drive_c."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { throw InstallerError.cancelled }
        return url
    }

    private func chooseCrossOver() throws -> URL {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver"),
            URL(fileURLWithPath: "/Applications/CrossOver.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver.app")
        ].compactMap { $0 }
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return found }
        let panel = NSOpenPanel()
        panel.title = "Locate CrossOver.app"
        panel.message = "Choose the installed CrossOver application."
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { throw InstallerError.cancelled }
        return url
    }

    private func show(message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

if CommandLine.arguments.count > 1 {
    exit(DepthInstaller.runCLI(Array(CommandLine.arguments.dropFirst())) ? 0 : 1)
}
let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
