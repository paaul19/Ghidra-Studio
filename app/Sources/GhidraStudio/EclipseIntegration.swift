import AppKit
import Darwin
import SwiftUI

/// The classic's Eclipse integration: scripts open in Eclipse and a symbol is looked up in its source there.
/// Both go through the GhidraDev plugin, which listens on two local ports.
enum Eclipse {
    static var app: String { UserDefaults.standard.string(forKey: "eclipseApp") ?? "" }
    static var workspace: String { UserDefaults.standard.string(forKey: "eclipseWorkspace") ?? "" }
    static var scriptPort: Int { UserDefaults.standard.object(forKey: "eclipseScriptPort") as? Int ?? 12321 }
    static var symbolPort: Int { UserDefaults.standard.object(forKey: "eclipseSymbolPort") as? Int ?? 12322 }
    static var autoInstall: Bool { UserDefaults.standard.bool(forKey: "eclipseAutoInstall") }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where Eclipse keeps its plugins: <Eclipse.app>/Contents/Eclipse on macOS, whatever part of it was chosen.
    static func installDirectory() throws -> URL {
        guard !app.isEmpty else { throw Failure(message: tr("Todavía no has dicho dónde está Eclipse (Herramientas ▸ Integración con Eclipse…).")) }
        var url = URL(fileURLWithPath: app)
        let name = url.lastPathComponent
        if name.hasSuffix(".app") {
            url = url.appendingPathComponent("Contents/Eclipse")
        } else if name == "Contents" {
            url = url.appendingPathComponent("Eclipse")
        } else if name == "MacOS" || name == "Resources" {
            url = url.deletingLastPathComponent().appendingPathComponent("Eclipse")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(message: tr("La carpeta de Eclipse no existe: %@", url.path))
        }
        return url
    }

    static func executable() throws -> URL {
        let install = try installDirectory()
        let candidates = [install.deletingLastPathComponent().appendingPathComponent("MacOS/eclipse"),
                          install.appendingPathComponent("eclipse")]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure(message: tr("No se encuentra el ejecutable de Eclipse en %@", install.path))
        }
        return found
    }

    static func dropins() throws -> URL {
        let url = try installDirectory().appendingPathComponent("dropins")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// GhidraDev is installed when a "ghidradev" item is in Eclipse's features or dropins.
    static func ghidraDevInstalled() -> Bool {
        guard let install = try? installDirectory() else { return false }
        let fm = FileManager.default
        var folders = [install.appendingPathComponent("features"), install.appendingPathComponent("dropins")]
        let dropins = install.appendingPathComponent("dropins")
        for sub in (try? fm.contentsOfDirectory(at: dropins, includingPropertiesForKeys: nil)) ?? [] {
            folders.append(sub.appendingPathComponent("features"))
        }
        return folders.contains { folder in
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.lowercased().contains("ghidradev") }
        }
    }

    /// Copies the GhidraDev plugin that comes with Ghidra to Eclipse's dropins folder.
    static func installGhidraDev() throws {
        let folder = Bundle.main.resourceURL!.appendingPathComponent("ghidra/Extensions/Eclipse/GhidraDev")
        let zips = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("GhidraDev") && $0.hasSuffix(".zip") }
        guard let zip = zips.first else { throw Failure(message: tr("Ghidra no trae el plugin GhidraDev en %@", folder.path)) }
        let target = try dropins()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -j: the jar goes straight into dropins, as the classic does
        process.arguments = ["-o", "-j", folder.appendingPathComponent(zip).path, "plugins/*ghidradev*", "-d", target.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: tr("No se pudo instalar GhidraDev en %@", target.path))
        }
    }

    /// Sends text to a local port and, when asked, reads one line back. Nil when nothing is listening.
    nonisolated static func exchange(port: Int, text: String, wantsReply: Bool) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array(text.utf8)
        guard bytes.withUnsafeBufferPointer({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else { return nil }
        guard wantsReply else { return "" }
        var reply = [UInt8]()
        var one: UInt8 = 0
        while reply.count < 4096, read(fd, &one, 1) == 1, one != 10 { reply.append(one) }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Talks to GhidraDev; when Eclipse is not running it is started (installing GhidraDev first if needed) and awaited.
    static func send(port: Int, text: String, wantsReply: Bool) async throws -> String {
        if let reply = await Task.detached(operation: { exchange(port: port, text: text, wantsReply: wantsReply) }).value {
            return reply
        }
        let binary = try executable()
        if !ghidraDevInstalled() {
            var install = autoInstall
            if !install {
                let alert = NSAlert()
                alert.messageText = "GhidraDev"
                alert.informativeText = tr("El plugin GhidraDev no está instalado en Eclipse. ¿Instalarlo en su carpeta «dropins»?")
                alert.addButton(withTitle: tr("Instalar"))
                alert.addButton(withTitle: tr("Cancelar"))
                install = alert.runModal() == .alertFirstButtonReturn
            }
            guard install else { throw Failure(message: tr("Sin GhidraDev, Eclipse no puede recibir nada de Ghidra.")) }
            try installGhidraDev()
        }
        let process = Process()
        process.executableURL = binary
        var arguments: [String] = []
        if !workspace.isEmpty { arguments += ["-data", workspace] }
        arguments += ["--launcher.appendVmargs", "-vmargs",
                      "-Dghidra.install.dir=" + Bundle.main.resourceURL!.appendingPathComponent("ghidra").path,
                      "-Dorg.eclipse.equinox.p2.reconciler.dropins.directory=" + (try dropins()).path]
        process.arguments = arguments
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        try process.run()
        // Eclipse takes a while to start listening
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(500))
            if let reply = await Task.detached(operation: { exchange(port: port, text: text, wantsReply: wantsReply) }).value {
                return reply
            }
            if !process.isRunning { break }
        }
        throw Failure(message: tr("No se pudo conectar con Eclipse en el puerto %@. Comprueba en Eclipse las preferencias de GhidraDev.", "\(port)"))
    }
}

extension AppModel {
    /// Opens a script in Eclipse's editor (GhidraDev's script editor port).
    func editInEclipse(_ path: String) {
        Task {
            do { _ = try await Eclipse.send(port: Eclipse.scriptPort, text: "open_" + path, wantsReply: false) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// Asks Eclipse (CDT) to show the source of the symbol under the cursor: the classic's Go To Symbol Source.
    func lookupSourceInEclipse() {
        let word = CodeNSTextView.current?.contextProvider?().word
        let name = word.flatMap { $0.isEmpty ? nil : $0 } ?? functionDetails?.name
        guard var symbol = name else {
            errorMessage = tr("Pon el cursor sobre un símbolo.")
            return
        }
        if let cut = symbol.range(of: "::", options: .backwards) { symbol = String(symbol[cut.upperBound...]) }
        Task {
            do {
                // symbols of C code often carry a leading underscore the source does not have
                var text = symbol
                var reply = ""
                while true {
                    reply = try await Eclipse.send(port: Eclipse.symbolPort, text: text + "\n", wantsReply: true)
                    guard text.hasPrefix("_") else { break }
                    text.removeFirst()
                }
                if !reply.isEmpty { statusMessage = reply }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func requestEclipseSettings() {
        formRequest = FormRequest(
            title: tr("Integración con Eclipse"),
            message: tr("Eclipse con el plugin GhidraDev abre los scripts y busca el código fuente de los símbolos. Estado: %@",
                        Eclipse.app.isEmpty ? tr("sin configurar") : Eclipse.ghidraDevInstalled() ? tr("GhidraDev instalado") : tr("GhidraDev no instalado")),
            fields: [
                FormField(key: "app", title: tr("Eclipse (Eclipse.app o su carpeta)"), value: Eclipse.app, placeholder: "/Applications/Eclipse.app"),
                FormField(key: "workspace", title: tr("Carpeta de trabajo (opcional)"), value: Eclipse.workspace),
                FormField(key: "scriptPort", title: tr("Puerto del editor de scripts"), value: "\(Eclipse.scriptPort)"),
                FormField(key: "symbolPort", title: tr("Puerto de búsqueda de símbolos"), value: "\(Eclipse.symbolPort)"),
                FormField(key: "auto", title: tr("Instalar GhidraDev sin preguntar cuando falte"), kind: .toggle,
                          value: Eclipse.autoInstall ? "true" : "false"),
                FormField(key: "install", title: tr("Instalar GhidraDev ahora"), kind: .toggle, value: "false"),
            ],
            actionTitle: tr("Guardar")) { values in
                let defaults = UserDefaults.standard
                defaults.set((values["app"] ?? "").trimmingCharacters(in: .whitespaces), forKey: "eclipseApp")
                defaults.set((values["workspace"] ?? "").trimmingCharacters(in: .whitespaces), forKey: "eclipseWorkspace")
                guard let script = Int(values["scriptPort"] ?? ""), let symbol = Int(values["symbolPort"] ?? ""),
                      (1...65535).contains(script), (1...65535).contains(symbol) else {
                    throw EngineError.remote(tr("Los puertos tienen que ser números entre 1 y 65535."))
                }
                defaults.set(script, forKey: "eclipseScriptPort")
                defaults.set(symbol, forKey: "eclipseSymbolPort")
                defaults.set(values["auto"] == "true", forKey: "eclipseAutoInstall")
                if values["install"] == "true" { try Eclipse.installGhidraDev() }
            }
    }
}
