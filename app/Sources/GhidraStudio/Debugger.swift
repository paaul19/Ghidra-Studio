import Foundation
import Observation

// MARK: - Configuration and model

/// How a debug session starts. Saved per program.
struct DebugConfig: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case launch, attach, remote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .launch: tr("Ejecutar")
            case .attach: tr("Adjuntar a un proceso")
            case .remote: tr("Remoto (gdbserver)")
            }
        }
    }

    var mode = Mode.launch
    var program = ""
    var arguments = ""
    var workingDirectory = ""
    /// KEY=VALUE, one per line.
    var environment = ""
    var stopAtEntry = true
    var disableASLR = true
    var pid = ""
    var remote = "localhost:1234"
    /// lldb (default), gdb (gdb's own DAP mode) or custom (any DAP adapter).
    var adapter: String?
    /// Command line of a custom DAP adapter, and the JSON it gets as launch / attach arguments.
    var adapterCommand: String?
    var launchJSON: String?
    /// Debugger commands run before launching or attaching, one per line.
    var initCommands: String?
    /// Shell command run before connecting (an ssh tunnel, adb forward, starting a gdbserver…).
    var preCommand: String?
    /// gdb-remote (default) or kdp-remote.
    var remoteKind: String?

    /// Splits a command line the way a shell would (quotes and backslashes).
    static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for c in line {
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                started = true
            } else if c == " " || c == "\t" || c == "\n" {
                if started || !current.isEmpty { out.append(current) }
                current = ""
                started = false
            } else {
                current.append(c)
            }
        }
        if started || !current.isEmpty { out.append(current) }
        return out
    }
}

enum DebugError: LocalizedError {
    case noAdapter
    case notRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAdapter:
            tr("No se encuentra lldb-dap. El depurador usa LLDB: instala Xcode o las Command Line Tools (xcode-select --install).")
        case .notRunning: tr("No hay ninguna sesión de depuración en marcha.")
        case .failed(let message): message
        }
    }
}

struct DebugThread: Identifiable, Equatable, Codable {
    let id: Int
    let name: String
}

struct DebugFrame: Identifiable, Equatable, Codable {
    let id: Int
    var name: String
    let pc: UInt64
    let moduleID: String?
    /// Address in the program open in Studio, when the frame is inside the mapped module.
    var staticAddress: String?
}

struct DebugRegister: Identifiable, Equatable, Codable {
    let name: String
    var value: String
    var changed = false
    var id: String { name }
}

struct DebugRegisterGroup: Identifiable, Equatable, Codable {
    let name: String
    var reference: Int
    var registers: [DebugRegister] = []
    var loaded = false
    var id: String { name }
}

struct DebugModule: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let path: String
    let base: UInt64
}

struct DebugInstruction: Equatable, Codable {
    let address: UInt64
    let bytes: String
    let text: String
    /// Label of the program open in Studio at this address.
    var label: String?
}

struct DebugWatch: Identifiable, Equatable, Codable {
    var id = UUID()
    var expression: String
    var value = ""
}

/// A piece of the process's memory as it was at one instant.
struct MemoryChunk: Codable, Equatable {
    let base: UInt64
    let data: Data

    func contains(_ address: UInt64) -> Bool { address >= base && address < base &+ UInt64(data.count) }
}

/// The state of the process at one stop: what the trace keeps so that you can go back to it.
struct DebugSnapshot: Codable, Identifiable {
    let id: Int
    let time: Date
    let reason: String
    var thread: Int?
    var threads: [DebugThread]
    var frames: [DebugFrame]
    var registerGroups: [DebugRegisterGroup]
    var instructions: [DebugInstruction]
    var memory: [MemoryChunk]
    var watches: [DebugWatch]
    /// A name given by hand to find the instant again.
    var name: String?

    var pc: UInt64? { frames.first?.pc }
}

/// A recorded session, saved to a file to look at it again without the process.
struct DebugTrace: Codable {
    var version = 1
    let program: String
    let slide: UInt64
    let mapped: Bool
    let modules: [DebugModule]
    let snapshots: [DebugSnapshot]
}

/// A watchpoint: the process stops when the memory is read or written.
struct DebugWatchpoint: Identifiable, Equatable {
    let id: Int
    let description: String
}

struct AddressDescription: Codable {
    let address: String
    let label: String?
    let function: String?
    let entry: String?
    let offset: Int64
}

struct ProcessItem: Identifiable, Hashable {
    let pid: Int
    let name: String
    var id: Int { pid }
}

// MARK: - Debug Adapter Protocol transport

/// Talks to lldb-dap (LLDB's Debug Adapter Protocol server) over stdin / stdout.
@MainActor
final class DAPConnection {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onExit: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var seq = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    private static var cachedAdapter: String??

    /// Path of lldb-dap, from the active developer directory or the Command Line Tools.
    static func adapterPath() -> String? {
        if let cached = cachedAdapter { return cached }
        var found: String?
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "lldb-dap"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: text) { found = text }
        }
        if found == nil {
            found = ["/Library/Developer/CommandLineTools/usr/bin/lldb-dap",
                     "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap",
                     "/opt/homebrew/opt/llvm/bin/lldb-dap", "/usr/local/opt/llvm/bin/lldb-dap"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        cachedAdapter = .some(found)
        return found
    }

    var isRunning: Bool { process != nil }

    /// gdb with DAP support (14 or newer), when it is installed.
    static func gdbPath() -> String? {
        ["/opt/homebrew/bin/gdb", "/usr/local/bin/gdb", "/opt/local/bin/gdb", "/usr/bin/gdb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(executable: String? = nil, arguments: [String] = []) throws {
        guard let path = executable ?? Self.adapterPath() else { throw DebugError.noAdapter }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.didTerminate() }
        }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
    }

    /// Sends a request and waits for its response body. Throws if the adapter reports a failure.
    @discardableResult
    func request(_ command: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard let input else { throw DebugError.notRunning }
        seq += 1
        let id = seq
        let body = try JSONSerialization.data(withJSONObject: ["seq": id, "type": "request", "command": command,
                                                               "arguments": arguments])
        var packet = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!
        packet.append(body)
        let response: Data = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do { try input.write(contentsOf: packet) } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
        if object["success"] as? Bool == false {
            let body = object["body"] as? [String: Any]
            let detail = (body?["error"] as? [String: Any])?["format"] as? String
            throw DebugError.failed(detail ?? object["message"] as? String ?? tr("La orden «%@» falló.", command))
        }
        return object["body"] as? [String: Any] ?? [:]
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        while let header = buffer.range(of: separator) {
            let head = String(decoding: buffer[buffer.startIndex..<header.lowerBound], as: UTF8.self)
            var length = 0
            for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
            guard buffer.distance(from: header.upperBound, to: buffer.endIndex) >= length else { return }
            let end = buffer.index(header.upperBound, offsetBy: length)
            let message = buffer.subdata(in: header.upperBound..<end)
            buffer.removeSubrange(buffer.startIndex..<end)
            handle(message)
        }
    }

    private func handle(_ message: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "response":
            if let id = object["request_seq"] as? Int, let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: message)
            }
        case "event":
            onEvent?(object["event"] as? String ?? "", object["body"] as? [String: Any] ?? [:])
        default:
            break       // reverse requests (runInTerminal…) are not used
        }
    }

    private func didTerminate() {
        process = nil
        input = nil
        pending.values.forEach { $0.resume(throwing: DebugError.notRunning) }
        pending.removeAll()
        onExit?()
    }
}

// MARK: - Session

/// One debug session: a process under LLDB, mapped onto the program open in Studio.
@MainActor
@Observable
final class DebugSession {
    /// `replay`: no process, looking at a trace loaded from a file.
    enum Phase: Equatable { case idle, starting, running, stopped, ended, replay }

    var config = DebugConfig()
    private(set) var phase = Phase.idle
    private(set) var status = ""
    private(set) var processName = ""
    private(set) var exitCode: Int?

    private(set) var threads: [DebugThread] = []
    var currentThread: Int?
    private(set) var frames: [DebugFrame] = []
    private(set) var currentFrame = 0
    private(set) var registerGroups: [DebugRegisterGroup] = []
    private(set) var modules: [DebugModule] = []
    private(set) var instructions: [DebugInstruction] = []
    /// Bumped whenever the disassembly or the memory dump changes, so the views rebuild their documents.
    private(set) var disassemblyVersion = 0
    private(set) var memoryVersion = 0
    var watches: [DebugWatch] = []
    private(set) var console = ""

    var memoryExpression = "$sp"
    private(set) var memoryBase: UInt64 = 0
    private(set) var memoryBytes: [Int] = []
    private(set) var memoryError: String?

    /// Navigate the main window to the program counter on every stop.
    var follow = true

    /// The program this session is mapped onto, and how far the module was loaded from its static address.
    private(set) var mappedSession: String?
    private(set) var mappedModule: String?
    private var slide: UInt64 = 0
    private var staticLow: UInt64 = 0
    private var staticHigh: UInt64 = 0
    private var imageBase: UInt64 = 0
    /// File name of the executable the mapped program was imported from.
    private var programFile: String?
    private var addressWidth = 8

    /// Breakpoints the adapter accepted (dynamic address → verified) and ones set outside the mapped module.
    private(set) var verified: [UInt64: Bool] = [:]
    private(set) var extraBreakpoints = Set<UInt64>()
    private(set) var watchpoints: [DebugWatchpoint] = []
    private var staticBreakpoints: [String: Bool] = [:]

    /// Address ranges mapped by hand onto the program (they win over the module's slide).
    var manualMappings: [ManualMapping] = []
    private(set) var regions: [JSONRow] = []
    private(set) var platformText = ""
    private(set) var unwindText = ""
    /// Other traces loaded next to the one on screen.
    private(set) var otherTraces: [LoadedTrace] = []
    private(set) var traceName = ""
    private var helper: Process?
    private var isGDB = false

    private var connection: DAPConnection?
    private var firstStop = true
    private var generation = 0
    private var previousRegisters: [String: String] = [:]
    private var detaching = false

    var isActive: Bool { phase == .starting || phase == .running || phase == .stopped }
    /// Stopped at the present: the process can be controlled and changed.
    var isStopped: Bool { phase == .stopped && viewing == nil }
    /// There is a state on screen (live, an earlier instant, or a loaded trace).
    var hasState: Bool { phase == .stopped || phase == .replay }
    var showsSession: Bool { isActive || phase == .replay }

    // MARK: Trace (time travel)

    /// One snapshot per stop. `viewing` is the instant on screen; nil means the present.
    private(set) var history: [DebugSnapshot] = []
    private(set) var viewing: Int?
    private(set) var recording = false
    private var recordCancelled = false
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    static let maxSnapshots = 5000

    /// The target can run backwards (a record-and-replay server such as rr).
    private(set) var canStepBack = false

    /// Keyboard input of the program being debugged goes through a FIFO.
    private var inputPath: String?
    private var inputHandle: FileHandle?
    var acceptsInput: Bool { inputHandle != nil && isActive }
    /// Set when launching failed because macOS does not allow debugging that binary.
    private(set) var needsDebuggableCopy = false

    /// Dynamic program counter of the selected frame.
    var pc: UInt64? { hasState && frames.indices.contains(currentFrame) ? frames[currentFrame].pc : nil }

    /// The program counter as an address of the program open in Studio.
    var staticPC: String? { pc.flatMap(toStatic) }

    // MARK: Address mapping

    func hex(_ value: UInt64) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: max(0, addressWidth - s.count)) + s
    }

    func toStatic(_ dynamic: UInt64) -> String? {
        for m in manualMappings where dynamic >= m.dynamicBase && dynamic < m.dynamicBase &+ m.length {
            return hex(dynamic &- m.dynamicBase &+ m.staticBase)
        }
        guard mappedModule != nil else { return nil }
        let value = dynamic &- slide
        guard value >= staticLow, value <= staticHigh else { return nil }
        return hex(value)
    }

    func toDynamic(_ address: String) -> UInt64? {
        if let value = addressValue(address) {
            for m in manualMappings where value >= m.staticBase && value < m.staticBase &+ m.length {
                return value &- m.staticBase &+ m.dynamicBase
            }
        }
        guard mappedModule != nil, let value = addressValue(address) else { return nil }
        return value &+ slide
    }

    var slideDescription: String {
        let signed = Int64(bitPattern: slide)
        return signed >= 0 ? "+0x" + String(signed, radix: 16) : "-0x" + String(-signed, radix: 16)
    }

    /// Breakpoints as dynamic addresses, for the dynamic listing (address → enabled).
    var dynamicBreakpoints: [String: Bool] {
        var out: [String: Bool] = [:]
        for (address, enabled) in staticBreakpoints {
            if let d = toDynamic(address) { out[String(d, radix: 16)] = enabled }
        }
        for d in extraBreakpoints { out[String(d, radix: 16)] = true }
        return out
    }

    // MARK: Starting and stopping

    private var model: AppModel { AppModel.shared }

    private static func key(for program: String) -> String { "debugConfig|" + program }

    /// Loads the configuration saved for the current program (or a fresh one pointing at its file).
    func loadConfig() {
        guard !isActive, let program = model.program else { return }
        if let data = UserDefaults.standard.data(forKey: Self.key(for: program.name)),
           let saved = try? JSONDecoder().decode(DebugConfig.self, from: data) {
            config = saved
        } else {
            var fresh = DebugConfig()
            if FileManager.default.isExecutableFile(atPath: program.path) { fresh.program = program.path }
            config = fresh
        }
    }

    private func saveConfig() {
        guard let program = model.program, let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(for: program.name))
    }

    func start() {
        guard !isActive else { return }
        saveConfig()
        reset()
        phase = .starting
        status = tr("Iniciando LLDB…")
        mappedSession = model.activeSession
        if let program = model.program {
            staticLow = program.minAddress.flatMap(addressValue) ?? 0
            staticHigh = program.maxAddress.flatMap(addressValue) ?? .max
            imageBase = addressValue(program.imageBase) ?? staticLow
            addressWidth = max(4, program.minAddress.map { ($0.split(separator: ":").last ?? "").count } ?? 8)
            programFile = (program.path as NSString).lastPathComponent
        }
        staticBreakpoints = model.breakpointMap
        needsDebuggableCopy = false
        let connection = DAPConnection()
        self.connection = connection
        connection.onEvent = { [weak self] event, body in self?.handle(event, body) }
        connection.onExit = { [weak self] in self?.adapterExited() }
        let adapter = config.adapter ?? "lldb"
        isGDB = adapter == "gdb"
        let userCommands = (config.initCommands ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            do {
                if let pre = config.preCommand, !pre.trimmingCharacters(in: .whitespaces).isEmpty {
                    // e.g. an ssh tunnel or "adb forward": it stays running for the whole session
                    status = tr("Ejecutando el comando previo…")
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    p.arguments = ["-lc", pre]
                    p.standardOutput = Pipe()
                    p.standardError = Pipe()
                    try p.run()
                    helper = p
                    try? await Task.sleep(for: .milliseconds(1500))
                    status = tr("Iniciando el depurador…")
                }
                switch adapter {
                case "gdb":
                    guard let gdb = DAPConnection.gdbPath() else {
                        throw DebugError.failed(tr("No se encontró gdb. Instálalo (por ejemplo con Homebrew) para usar este conector."))
                    }
                    try connection.start(executable: gdb, arguments: ["-i", "dap"])
                case "custom":
                    let parts = DebugConfig.split(config.adapterCommand ?? "")
                    guard let exe = parts.first, FileManager.default.isExecutableFile(atPath: exe) else {
                        throw DebugError.failed(tr("Indica la ruta del adaptador DAP."))
                    }
                    try connection.start(executable: exe, arguments: Array(parts.dropFirst()))
                default:
                    try connection.start()
                }
                try await connection.request("initialize", [
                    "adapterID": adapter == "lldb" ? "lldb-dap" : adapter, "clientID": "ghidra-studio", "clientName": "Ghidra Studio",
                    "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
                    "supportsMemoryReferences": true,
                ])
                // a custom adapter gets exactly the arguments written for it
                if adapter == "custom", let text = config.launchJSON, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                        throw DebugError.failed(tr("Los argumentos del adaptador no son un objeto JSON válido."))
                    }
                    try await connection.request(config.mode == .launch ? "launch" : "attach", object)
                    return
                }
                if isGDB {
                    switch config.mode {
                    case .launch:
                        var args: [String: Any] = ["program": config.program, "args": DebugConfig.split(config.arguments),
                                                   "stopAtBeginningOfMainSubprogram": false]
                        if !config.workingDirectory.isEmpty { args["cwd"] = config.workingDirectory }
                        var env: [String: String] = [:]
                        for line in config.environment.split(separator: "\n") {
                            if let eq = line.firstIndex(of: "=") { env[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
                        }
                        if !env.isEmpty { args["env"] = env }
                        try await connection.request("launch", args)
                    case .attach:
                        guard let pid = Int(config.pid.trimmingCharacters(in: .whitespaces)) else {
                            throw DebugError.failed(tr("Elige el proceso al que adjuntar."))
                        }
                        try await connection.request("attach", ["pid": pid])
                    case .remote:
                        var args: [String: Any] = ["target": config.remote]
                        if !config.program.isEmpty { args["program"] = config.program }
                        try await connection.request("attach", args)
                    }
                    return
                }
                // the response to launch / attach only comes after configurationDone (sent on "initialized")
                switch config.mode {
                case .launch:
                    var args: [String: Any] = [
                        "program": config.program, "args": DebugConfig.split(config.arguments),
                        "stopOnEntry": true, "disableASLR": config.disableASLR,
                    ]
                    if !config.workingDirectory.isEmpty { args["cwd"] = config.workingDirectory }
                    let env = config.environment.split(separator: "\n").map(String.init).filter { $0.contains("=") }
                    if !env.isEmpty { args["env"] = env }
                    var commands = userCommands
                    if let fifo = openInput() {
                        // LLDB gives the program this file as its standard input
                        commands.append("settings set target.input-path \"\(fifo)\"")
                    }
                    if !commands.isEmpty { args["initCommands"] = commands }
                    try await connection.request("launch", args)
                case .attach:
                    guard let pid = Int(config.pid.trimmingCharacters(in: .whitespaces)) else {
                        throw DebugError.failed(tr("Elige el proceso al que adjuntar."))
                    }
                    var args: [String: Any] = ["pid": pid, "stopOnEntry": true]
                    if !userCommands.isEmpty { args["initCommands"] = userCommands }
                    try await connection.request("attach", args)
                case .remote:
                    var args: [String: Any] = ["attachCommands": [(config.remoteKind ?? "gdb-remote") + " " + config.remote],
                                               "stopOnEntry": true]
                    if !userCommands.isEmpty { args["initCommands"] = userCommands }
                    if !config.program.isEmpty { args["program"] = config.program }
                    try await connection.request("attach", args)
                }
            } catch {
                let message = error.localizedDescription
                if config.mode == .launch, message.contains("Not allowed to attach") || message.contains("attach failed") {
                    needsDebuggableCopy = true
                    fail(tr("macOS no permite depurar este ejecutable tal como está firmado. Puedes depurar una copia firmada para depuración."))
                } else {
                    fail(message)
                }
            }
        }
    }

    // MARK: Program input

    /// Creates the FIFO the program will read its standard input from. Returns its path.
    private func openInput() -> String? {
        closeInput()
        let path = NSTemporaryDirectory() + "studio-debug-\(UUID().uuidString.prefix(8)).in"
        guard mkfifo(path, 0o600) == 0 else { return nil }
        // read-write so that opening does not wait for the other end
        let fd = open(path, O_RDWR)
        guard fd >= 0 else {
            unlink(path)
            return nil
        }
        inputPath = path
        inputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return path
    }

    private func closeInput() {
        try? inputHandle?.close()
        inputHandle = nil
        if let inputPath { unlink(inputPath) }
        inputPath = nil
    }

    /// Sends a line to the program's standard input.
    func sendInput(_ text: String) {
        guard let inputHandle, isActive else { return }
        log(text + "\n")
        try? inputHandle.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Ends the program's standard input (what ⌃D does in a terminal).
    func endInput() {
        guard inputHandle != nil else { return }
        log(tr("[fin de la entrada]") + "\n")
        try? inputHandle?.close()
        inputHandle = nil
    }

    // MARK: Debuggable copy

    /// Copies an executable (or the app that contains it) and signs the copy so that it can be debugged.
    /// The original is not touched. Returns the path of the executable inside the copy.
    static func makeDebuggableCopy(of path: String) throws -> String {
        let fm = FileManager.default
        var source = URL(fileURLWithPath: path)
        var inner = ""
        // inside an app: copy the whole bundle, the program needs its resources
        if let range = path.range(of: ".app/Contents/MacOS/") {
            source = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
            inner = "Contents/MacOS/" + String(path[range.upperBound...])
        }
        let folder = Engine.supportDirectory.appendingPathComponent("Debug Copies", isDirectory: true)
            .appendingPathComponent(String(format: "%08x", abs(path.hashValue) & 0xffffffff), isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        let entitlements = folder.appendingPathComponent("debug.entitlements")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
        """.utf8).write(to: entitlements)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path]
            + (inner.isEmpty ? [] : ["--deep"]) + [copy.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DebugError.failed(tr("No se pudo firmar la copia: %@", text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return inner.isEmpty ? copy.path : copy.appendingPathComponent(inner).path
    }

    /// Replaces the program to launch with a debuggable copy of it.
    func useDebuggableCopy() {
        do {
            config.program = try Self.makeDebuggableCopy(of: config.program)
            needsDebuggableCopy = false
            status = tr("Copia depurable lista.")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func reset() {
        generation += 1
        threads = []; frames = []; currentFrame = 0; currentThread = nil
        registerGroups = []; modules = []; instructions = []
        memoryBytes = []; memoryError = nil
        verified = [:]; extraBreakpoints = []; watchpoints = []
        console = ""; exitCode = nil; processName = ""
        mappedModule = nil; slide = 0
        firstStop = true; previousRegisters = [:]; detaching = false
        history = []; viewing = nil; recording = false; recordCancelled = false; canStepBack = false
        regions = []; platformText = ""; unwindText = ""; traceName = ""
        disassemblyVersion += 1; memoryVersion += 1
    }

    private func stopHelper() {
        helper?.terminate()
        helper = nil
    }

    private func fail(_ message: String) {
        log(message + "\n")
        status = message
        connection?.stop()
        connection = nil
        closeInput()
        stopHelper()
        phase = .ended
        model.errorMessage = message
    }

    /// Kills the process (or detaches from it, when it was attached to).
    func stop(detach: Bool? = nil) {
        guard let connection, isActive else { return }
        let leave = detach ?? (config.mode != .launch)
        detaching = true
        status = leave ? tr("Soltando el proceso…") : tr("Deteniendo…")
        Task {
            _ = try? await connection.request("disconnect", ["terminateDebuggee": !leave])
            try? await Task.sleep(for: .milliseconds(300))
            connection.stop()
        }
    }

    func restart() {
        guard isActive else { start(); return }
        stop()
        Task {
            for _ in 0..<50 where isActive { try? await Task.sleep(for: .milliseconds(100)) }
            start()
        }
    }

    private func adapterExited() {
        guard phase != .idle, phase != .ended, phase != .replay else { return }
        connection = nil
        generation += 1
        closeInput()
        stopHelper()
        stopWaiters.forEach { $0.resume(returning: false) }
        stopWaiters = []
        recording = false
        phase = .ended
        status = exitCode.map { tr("El proceso terminó con código %@.", "\($0)") }
            ?? (detaching ? tr("Sesión terminada.") : tr("LLDB se cerró."))
        frames = []; threads = []
        disassemblyVersion += 1
    }

    // MARK: Events

    private func handle(_ event: String, _ body: [String: Any]) {
        switch event {
        case "initialized":
            Task { _ = try? await connection?.request("configurationDone") }
        case "stopped":
            Task { await didStop(body) }
        case "continued":
            if phase == .stopped || phase == .starting {
                generation += 1
                phase = .running
                status = tr("En ejecución")
            }
        case "process":
            processName = body["name"] as? String ?? ""
        case "output":
            let category = body["category"] as? String ?? "console"
            // the commands that set up the program's input are plumbing, not output
            if category != "telemetry", let text = body["output"] as? String,
               !text.contains("target.input-path"), !text.hasPrefix("Running initCommands") { log(text) }
        case "exited":
            exitCode = body["exitCode"] as? Int
        case "terminated":
            connection?.stop()
        case "module":
            if phase == .stopped { Task { await loadModules() } }
        case "capabilities":
            if let caps = body["capabilities"] as? [String: Any], let back = caps["supportsStepBack"] as? Bool {
                canStepBack = back
            }
        default:
            break
        }
    }

    private func log(_ text: String) {
        console += text.replacingOccurrences(of: "\r\n", with: "\n")
        if console.count > 200_000 { console = String(console.suffix(150_000)) }
    }

    private func didStop(_ body: [String: Any]) async {
        guard let connection else { return }
        generation += 1
        let token = generation
        currentThread = body["threadId"] as? Int ?? currentThread
        let reason = body["description"] as? String ?? body["reason"] as? String ?? ""
        if firstStop {
            firstStop = false
            await loadModules()
            await syncBreakpoints()
            if !config.stopAtEntry {
                _ = try? await connection.request("continue", ["threadId": currentThread ?? 0])
                phase = .running
                status = tr("En ejecución")
                return
            }
        }
        guard token == generation else { return }
        viewing = nil
        phase = .stopped
        status = tr("Detenido: %@", reason)
        await refresh(token: token)
        guard token == generation else { return }
        record(reason: reason)
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.resume(returning: true) }
    }

    // MARK: Trace

    /// Adds the state on screen to the trace.
    private func record(reason: String) {
        guard history.count < Self.maxSnapshots, !frames.isEmpty else { return }
        var memory: [MemoryChunk] = []
        if !memoryBytes.isEmpty { memory.append(MemoryChunk(base: memoryBase, data: Data(memoryBytes.map { UInt8($0) }))) }
        if let stack = stackChunk, !memory.contains(stack) { memory.append(stack) }
        history.append(DebugSnapshot(id: history.count, time: Date(), reason: reason, thread: currentThread, threads: threads,
                                     frames: frames, registerGroups: registerGroups,
                                     instructions: recording ? [] : instructions, memory: memory, watches: watches))
    }

    /// Replaces the last snapshot (after the state was changed by hand).
    private func rerecord() {
        guard viewing == nil, let last = history.last else { return }
        history.removeLast()
        record(reason: last.reason)
    }

    /// Shows the state the process had at an earlier stop (nil: back to the present).
    func view(snapshot index: Int?) {
        guard hasState, !recording else { return }
        let target = index.flatMap { $0 >= history.count - 1 && phase == .stopped ? nil : $0 }
        guard let i = target ?? (phase == .replay ? index : nil) ?? history.indices.last, history.indices.contains(i) else { return }
        viewing = (phase == .stopped && i == history.count - 1) ? nil : i
        let s = history[i]
        generation += 1
        threads = s.threads
        currentThread = s.thread
        frames = s.frames
        for f in frames.indices { frames[f].staticAddress = toStatic(frames[f].pc) }
        currentFrame = 0
        // registers that differ from the instant before are the ones that changed
        var before: [String: String] = [:]
        if i > 0 { for g in history[i - 1].registerGroups { for r in g.registers { before[r.name] = r.value } } }
        registerGroups = s.registerGroups.map { group in
            var g = group
            g.registers = g.registers.map { DebugRegister(name: $0.name, value: $0.value,
                                                           changed: before[$0.name] != nil && before[$0.name] != $0.value) }
            return g
        }
        watches = s.watches
        instructions = s.instructions
        disassemblyVersion += 1
        showRecordedMemory()
        status = viewing == nil ? tr("Detenido: %@", s.reason)
            : tr("Instante %@ de %@: %@", "\(i + 1)", "\(history.count)", s.reason)
        let token = generation
        Task {
            // the code is the same at any instant: read it from the process when the snapshot did not keep it
            if instructions.isEmpty, let pc = s.pc {
                if phase == .stopped { await disassemble(around: pc, token: token) }
                if instructions.isEmpty { await staticDisassemble(around: pc, token: token) }
            }
            if follow, let address = frames.first?.staticAddress, model.activeSession == mappedSession, token == generation {
                await model.navigate(to: address, recordHistory: false)
            }
        }
    }

    var viewedIndex: Int { viewing ?? max(0, history.count - 1) }

    /// Without the process, the code comes from the program open in Studio (shown at its dynamic addresses).
    private func staticDisassemble(around pc: UInt64, token: Int) async {
        guard let session = mappedSession, let address = toStatic(pc),
              model.tabs.contains(where: { $0.id == session }) else { return }
        let listing: Listing? = try? await model.engine.call("listing", ["address": address, "count": 400, "session": session])
        guard let listing, token == generation else { return }
        instructions = listing.rows.filter { $0.kind == "code" }.compactMap { row in
            guard let value = addressValue(row.address) else { return nil }
            let operands = row.operands.map(\.text).joined(separator: ", ")
            return DebugInstruction(address: value &+ slide, bytes: row.bytes,
                                    text: operands.isEmpty ? row.mnemonic : row.mnemonic + " " + operands, label: row.label)
        }
        disassemblyVersion += 1
    }

    /// The value a register had at the instant on screen.
    private func recordedRegister(_ name: String) -> UInt64? {
        for g in registerGroups {
            if let r = g.registers.first(where: { $0.name == name }) {
                return Self.parse(String(r.value.split(separator: " ").first ?? ""))
            }
        }
        return nil
    }

    /// Memory panel for an earlier instant: only what the trace recorded can be shown.
    private func showRecordedMemory() {
        guard history.indices.contains(viewedIndex) else { return }
        let text = memoryExpression.trimmingCharacters(in: .whitespaces)
        var address = Self.parse(text)
        if address == nil, text.hasPrefix("$") { address = recordedRegister(String(text.dropFirst())) }
        if address == nil, text.allSatisfy(\.isHexDigit), text.count >= 6 { address = UInt64(text, radix: 16) }
        let chunks = history[viewedIndex].memory
        if let address, let chunk = chunks.first(where: { $0.contains(address) }) {
            let offset = Int(address - chunk.base)
            memoryBase = address
            memoryBytes = chunk.data.dropFirst(offset).map(Int.init)
            memoryError = nil
        } else {
            memoryBytes = []
            memoryError = tr("Esa memoria no se grabó en este instante. La traza guarda la pila y lo que mostraba el panel de memoria.")
        }
        memoryVersion += 1
    }

    /// Steps `count` instructions one by one, keeping a snapshot of each, to go through them afterwards.
    func recordSteps(_ count: Int) {
        guard isStopped, !recording, count > 0 else { return }
        recording = true
        recordCancelled = false
        let wasFollowing = follow
        follow = false
        Task {
            var done = 0
            while done < count, !recordCancelled, isStopped, history.count < Self.maxSnapshots {
                guard await stepAndWait() else { break }
                done += 1
                status = tr("Grabando: %@ de %@ instrucciones", "\(done)", "\(count)")
            }
            recording = false
            follow = wasFollowing
            // the recorded snapshots are light; bring the present fully up to date
            if phase == .stopped {
                let token = generation
                await showFrame(token: token)
                rerecord()
                status = tr("Grabadas %@ instrucciones", "\(done)")
            }
        }
    }

    func cancelRecording() { recordCancelled = true }

    private func stepAndWait() async -> Bool {
        guard let connection, isStopped, let thread = currentThread else { return false }
        generation += 1
        phase = .running
        return await withCheckedContinuation { cont in
            stopWaiters.append(cont)
            Task {
                do {
                    try await connection.request("stepIn", ["threadId": thread, "granularity": "instruction"])
                } catch {
                    if let i = stopWaiters.indices.last {
                        stopWaiters.remove(at: i).resume(returning: false)
                    }
                }
            }
        }
    }

    /// Saves the trace to a file.
    func saveTrace(to url: URL) throws {
        let program = model.tabs.first { $0.id == mappedSession }?.name ?? processName
        let trace = DebugTrace(program: program, slide: slide, mapped: mappedModule != nil, modules: modules,
                               snapshots: history)
        try JSONEncoder().encode(trace).write(to: url)
    }

    /// Opens a saved trace to go through it without the process, against the program open in Studio.
    func loadTrace(from url: URL) throws {
        guard !isActive else { return }
        let trace = try JSONDecoder().decode(DebugTrace.self, from: Data(contentsOf: url))
        reset()
        mappedSession = model.activeSession
        if let program = model.program {
            staticLow = program.minAddress.flatMap(addressValue) ?? 0
            staticHigh = program.maxAddress.flatMap(addressValue) ?? .max
            imageBase = addressValue(program.imageBase) ?? staticLow
            addressWidth = max(4, program.minAddress.map { ($0.split(separator: ":").last ?? "").count } ?? 8)
        }
        modules = trace.modules
        slide = trace.slide
        mappedModule = trace.mapped ? (trace.modules.first { $0.name == trace.program }?.id ?? trace.modules.first?.id) : nil
        history = trace.snapshots
        traceName = url.deletingPathExtension().lastPathComponent
        console = tr("Traza de «%@»: %@ instantes.", trace.program, "\(trace.snapshots.count)") + "\n"
        phase = .replay
        view(snapshot: history.indices.last)
    }

    func closeTrace() {
        guard phase == .replay else { return }
        reset()
        phase = .idle
        status = ""
    }

    /// The stack around the stack pointer, kept in every snapshot.
    private var stackChunk: MemoryChunk?

    // MARK: Emulation

    /// Starts Studio's emulator from the state on screen: same registers, same stack, same place.
    func emulateFromHere() async -> Bool {
        guard hasState, let session = mappedSession, let frame = frames.first, let address = frame.staticAddress else {
            model.errorMessage = tr("La instrucción actual no pertenece al programa abierto en Studio.")
            return false
        }
        let low = staticLow &+ slide, high = staticHigh &+ slide
        // pointers into the module are moved back to the addresses the program has in Studio
        func rebase(_ value: UInt64) -> UInt64 { slide != 0 && value >= low && value <= high ? value &- slide : value }
        var registers: [String: String] = [:]
        for register in registerGroups.first?.registers ?? [] {
            guard let value = Self.parse(String(register.value.split(separator: " ").first ?? "")) else { continue }
            registers[register.name] = "0x" + String(rebase(value), radix: 16)
        }
        var chunks: [MemoryChunk] = history.indices.contains(viewedIndex) ? history[viewedIndex].memory : []
        if isStopped, let connection {
            // live: also what the registers point to (heap, more stack)
            var seen = Set(chunks.map(\.base))
            for register in registerGroups.first?.registers ?? [] {
                guard let value = Self.parse(String(register.value.split(separator: " ").first ?? "")), value > 0x10000,
                      !(value >= low && value <= high), !seen.contains(value), seen.count < 48 else { continue }
                seen.insert(value)
                if let body = try? await connection.request("readMemory", ["memoryReference": "0x" + String(value, radix: 16),
                                                                           "count": 512]),
                   let data = (body["data"] as? String).flatMap({ Data(base64Encoded: $0) }), !data.isEmpty {
                    chunks.append(MemoryChunk(base: value, data: data))
                }
            }
        }
        let memory: [[String]] = chunks.map { chunk in
            var bytes = [UInt8](chunk.data)
            if slide != 0 {
                // rebase pointer-sized words too (return addresses on the stack)
                var i = 0
                while i + 8 <= bytes.count {
                    let word = bytes[i..<i + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
                    let moved = rebase(word)
                    if moved != word { for k in 0..<8 { bytes[i + k] = UInt8((moved >> (8 * UInt64(k))) & 0xff) } }
                    i += 8
                }
            }
            return ["0x" + String(chunk.base, radix: 16), bytes.map { String(format: "%02x", $0) }.joined()]
        }
        do {
            _ = try await model.engine.call("emuStartFrom", ["address": address, "registers": registers, "memory": memory,
                                                             "session": session], as: EmuState.self)
            model.emulatorRevision += 1
            return true
        } catch {
            model.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Reloads everything shown while the process is stopped.
    private func refresh(token: Int) async {
        guard let connection else { return }
        do {
            let list = try await connection.request("threads")["threads"] as? [[String: Any]] ?? []
            guard token == generation else { return }
            threads = list.compactMap { t in (t["id"] as? Int).map { DebugThread(id: $0, name: t["name"] as? String ?? "") } }
            if currentThread == nil || !threads.contains(where: { $0.id == currentThread }) { currentThread = threads.first?.id }
            try await loadFrames(token: token)
        } catch {
            log(error.localizedDescription + "\n")
        }
    }

    private func loadFrames(token: Int) async throws {
        guard let connection, let thread = currentThread else { return }
        let list = try await connection.request("stackTrace", ["threadId": thread, "levels": 64])["stackFrames"]
            as? [[String: Any]] ?? []
        guard token == generation else { return }
        var result: [DebugFrame] = []
        for f in list {
            guard let id = f["id"] as? Int,
                  let pc = (f["instructionPointerReference"] as? String).flatMap(Self.parse) else { continue }
            let module = f["moduleId"] as? String ?? (f["moduleId"] as? Int).map(String.init)
            result.append(DebugFrame(id: id, name: f["name"] as? String ?? "", pc: pc, moduleID: module,
                                     staticAddress: toStatic(pc)))
        }
        frames = result
        currentFrame = 0
        await nameFrames(token: token)
        await showFrame(token: token)
    }

    /// Uses the names of the program open in Studio (which the user may have changed) for the mapped frames.
    private func nameFrames(token: Int) async {
        let statics = frames.compactMap(\.staticAddress)
        guard !statics.isEmpty, let names = await describe(statics), token == generation else { return }
        for i in frames.indices {
            guard let address = frames[i].staticAddress, let d = names[address], let function = d.function else { continue }
            frames[i].name = d.offset == 0 ? function : "\(function)+0x\(String(d.offset, radix: 16))"
        }
    }

    private func describe(_ addresses: [String]) async -> [String: AddressDescription]? {
        guard let session = mappedSession, model.tabs.contains(where: { $0.id == session }) else { return nil }
        let list: [AddressDescription]? = try? await model.engine.call("describeAddresses",
                                                                      ["addresses": addresses, "session": session])
        guard let list else { return nil }
        return Dictionary(list.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Registers, disassembly, memory and watches for the selected frame.
    private func showFrame(token: Int) async {
        guard frames.indices.contains(currentFrame) else { return }
        let frame = frames[currentFrame]
        if recording {
            // recording steps: only what a snapshot needs
            await loadRegisters(frame: frame.id, token: token)
            await readStack()
            return
        }
        async let registers: Void = loadRegisters(frame: frame.id, token: token)
        async let listing: Void = disassemble(around: frame.pc, token: token)
        _ = await (registers, listing)
        await readMemory()
        await readStack()
        await evaluateWatches()
        guard token == generation else { return }
        if follow, let address = frame.staticAddress, model.activeSession == mappedSession {
            await model.navigate(to: address, recordHistory: false)
        }
    }

    func select(thread: Int) {
        guard isStopped, thread != currentThread else { return }
        currentThread = thread
        let token = generation
        Task { try? await loadFrames(token: token) }
    }

    func select(frame: Int) {
        guard hasState, frames.indices.contains(frame) else { return }
        currentFrame = frame
        guard isStopped else {
            // an earlier instant: only the place changes, the registers kept are those of the innermost frame
            if follow, let address = frames[frame].staticAddress, model.activeSession == mappedSession { model.go(address) }
            return
        }
        let token = generation
        Task { await showFrame(token: token) }
    }

    /// Reads the stack around the stack pointer, for the trace.
    private func readStack() async {
        guard let connection, let sp = recordedRegister("sp") ?? recordedRegister("rsp") ?? recordedRegister("esp") else {
            stackChunk = nil
            return
        }
        let body = try? await connection.request("readMemory", ["memoryReference": "0x" + String(sp, radix: 16), "count": 512])
        let data = (body?["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        stackChunk = data.isEmpty ? nil : MemoryChunk(base: sp, data: data)
    }

    // MARK: Registers

    private func loadRegisters(frame: Int, token: Int) async {
        guard let connection else { return }
        do {
            let scopes = try await connection.request("scopes", ["frameId": frame])["scopes"] as? [[String: Any]] ?? []
            guard let scope = scopes.first(where: { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains("regist") }),
                  let reference = scope["variablesReference"] as? Int else { return }
            let list = try await connection.request("variables", ["variablesReference": reference])["variables"]
                as? [[String: Any]] ?? []
            guard token == generation else { return }
            let wasLoaded = Set(registerGroups.filter(\.loaded).map(\.name))
            var groups = list.compactMap { g -> DebugRegisterGroup? in
                guard let name = g["name"] as? String, let ref = g["variablesReference"] as? Int, ref > 0 else { return nil }
                return DebugRegisterGroup(name: name, reference: ref)
            }
            // the first group (general purpose) is always shown; the others when they were open before
            for i in groups.indices where i == 0 || wasLoaded.contains(groups[i].name) {
                groups[i].registers = try await registers(reference: groups[i].reference)
                groups[i].loaded = true
            }
            guard token == generation else { return }
            registerGroups = groups
            for group in groups { for r in group.registers { previousRegisters[r.name] = r.value } }
        } catch {
            log(error.localizedDescription + "\n")
        }
    }

    private func registers(reference: Int) async throws -> [DebugRegister] {
        guard let connection else { return [] }
        let list = try await connection.request("variables", ["variablesReference": reference])["variables"]
            as? [[String: Any]] ?? []
        return list.compactMap { v in
            guard let name = v["name"] as? String else { return nil }
            let value = v["value"] as? String ?? ""
            let before = previousRegisters[name]
            return DebugRegister(name: name, value: value, changed: before != nil && before != value)
        }
    }

    func loadGroup(_ name: String) {
        guard isStopped, let i = registerGroups.firstIndex(where: { $0.name == name }), !registerGroups[i].loaded else { return }
        let token = generation
        Task {
            guard let list = try? await registers(reference: registerGroups[i].reference), token == generation,
                  registerGroups.indices.contains(i) else { return }
            registerGroups[i].registers = list
            registerGroups[i].loaded = true
            for r in list { previousRegisters[r.name] = r.value }
        }
    }

    func writeRegister(_ name: String, _ value: String) {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard isStopped, !text.isEmpty else { return }
        Task {
            await command("register write \(name) \(text)", echo: true)
            await reloadAfterWrite()
        }
    }

    /// After changing registers or memory by hand: re-read what is on screen (the program counter may have moved).
    private func reloadAfterWrite() async {
        guard isStopped else { return }
        let token = generation
        try? await loadFrames(token: token)
        rerecord()
    }

    // MARK: Disassembly

    private func disassemble(around address: UInt64, token: Int) async {
        guard let connection else { return }
        do {
            let list = try await connection.request("disassemble", [
                "memoryReference": "0x" + String(address, radix: 16), "instructionOffset": -24, "instructionCount": 120,
            ])["instructions"] as? [[String: Any]] ?? []
            guard token == generation else { return }
            var result = list.compactMap { i -> DebugInstruction? in
                guard let a = (i["address"] as? String).flatMap(Self.parse) else { return nil }
                return DebugInstruction(address: a, bytes: i["instructionBytes"] as? String ?? "",
                                        text: (i["instruction"] as? String ?? "").trimmingCharacters(in: .whitespaces))
            }
            // unreadable memory before the function comes back as filler; drop it
            result.removeAll { $0.bytes.isEmpty && $0.address != address }
            // addresses that appear as operands (call and jump targets), to show them with the program's names
            var targets: [Int: String] = [:]
            for i in result.indices {
                guard let r = result[i].text.range(of: #"0x[0-9a-fA-F]{5,16}"#, options: .regularExpression),
                      let value = UInt64(result[i].text[r].dropFirst(2), radix: 16), let s = toStatic(value) else { continue }
                targets[i] = s
            }
            let statics = result.compactMap { toStatic($0.address) } + targets.values
            if !statics.isEmpty, let names = await describe(statics), token == generation {
                for i in result.indices {
                    if let s = toStatic(result[i].address), let label = names[s]?.label { result[i].label = label }
                    if let s = targets[i], let d = names[s], let name = d.label ?? d.function {
                        let shown = d.label != nil || d.offset == 0 ? name : "\(name)+0x\(String(d.offset, radix: 16))"
                        let code = result[i].text.split(separator: ";", maxSplits: 1).first.map(String.init) ?? result[i].text
                        result[i] = DebugInstruction(address: result[i].address, bytes: result[i].bytes,
                                                     text: code.trimmingCharacters(in: .whitespaces) + " ; " + shown,
                                                     label: result[i].label)
                    }
                }
            }
            instructions = result
            disassemblyVersion += 1
        } catch {
            instructions = []
            disassemblyVersion += 1
        }
    }

    // MARK: Memory

    private static func parse(_ text: String) -> UInt64? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt64(t.dropFirst(2), radix: 16) }
        return UInt64(t)
    }

    /// Value of an expression (a register like $sp, a number, C syntax) in the selected frame.
    private func evaluate(_ expression: String) async throws -> String {
        guard let connection else { throw DebugError.notRunning }
        var args: [String: Any] = ["expression": expression, "context": "watch"]
        if frames.indices.contains(currentFrame) { args["frameId"] = frames[currentFrame].id }
        return try await connection.request("evaluate", args)["result"] as? String ?? ""
    }

    func readMemory() async {
        if hasState, !isStopped {
            showRecordedMemory()
            return
        }
        guard let connection, isStopped else { return }
        let text = memoryExpression.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            var address = Self.parse(text)
            if address == nil, text.allSatisfy(\.isHexDigit), text.count >= 6 { address = UInt64(text, radix: 16) }
            if address == nil {
                let value = try await evaluate(text)
                // pointers print as "0x… <symbol>", integers as decimal
                address = Self.parse(String(value.split(separator: " ").first ?? ""))
            }
            guard let address else { throw DebugError.failed(tr("«%@» no es una dirección.", text)) }
            let body = try await connection.request("readMemory", ["memoryReference": "0x" + String(address, radix: 16),
                                                                   "count": 512])
            let data = (body["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            if data.isEmpty { throw DebugError.failed(tr("No se puede leer la memoria en %@.", "0x" + String(address, radix: 16))) }
            memoryBase = address
            memoryBytes = data.map(Int.init)
            memoryError = nil
        } catch {
            memoryBytes = []
            memoryError = error.localizedDescription
        }
        memoryVersion += 1
    }

    func showMemory(_ expression: String) {
        memoryExpression = expression
        Task { await readMemory() }
    }

    func writeMemory(address: String, bytes: String) {
        let parts = bytes.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        let values = parts.compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        guard isStopped, !values.isEmpty, values.count == parts.count else {
            model.errorMessage = tr("Escribe los bytes en hexadecimal, separados por espacios.")
            return
        }
        Task {
            await command("memory write \(address) " + values.map { String(format: "0x%02x", $0) }.joined(separator: " "),
                          echo: true)
            await readMemory()
            if let pc { await disassemble(around: pc, token: generation) }
        }
    }

    // MARK: Watches

    func addWatch(_ expression: String) {
        let text = expression.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        watches.append(DebugWatch(expression: text))
        Task { await evaluateWatches() }
    }

    private func evaluateWatches() async {
        guard isStopped else { return }
        for watch in watches {
            let value = (try? await evaluate(watch.expression)) ?? "—"
            if let i = watches.firstIndex(where: { $0.id == watch.id }) { watches[i].value = value }
        }
    }

    // MARK: Modules and mapping

    private func loadModules() async {
        guard let connection else { return }
        let list = (try? await connection.request("modules"))?["modules"] as? [[String: Any]] ?? []
        modules = list.compactMap { m in
            let id = m["id"] as? String ?? (m["id"] as? Int).map(String.init)
            guard let id, let base = (m["addressRange"] as? String).flatMap(Self.parse) else { return nil }
            return DebugModule(id: id, name: m["name"] as? String ?? "", path: m["path"] as? String ?? "", base: base)
        }
        if mappedModule == nil || !modules.contains(where: { $0.id == mappedModule }) {
            // only a module that is the program open in Studio is mapped: debugging something else
            // (another executable, a system process) must not get that program's breakpoints
            let names = Set([model.tabs.first { $0.id == mappedSession }?.name, programFile].compactMap { $0 })
            if let match = modules.first(where: { names.contains($0.name) }) { map(module: match, sync: false) }
        }
    }

    /// Declares that `module` is the program open in Studio: its load address fixes the slide.
    func map(module: DebugModule, sync: Bool = true) {
        guard mappedSession != nil else { return }
        mappedModule = module.id
        slide = module.base &- imageBase
        for i in frames.indices { frames[i].staticAddress = toStatic(frames[i].pc) }
        guard sync else { return }
        Task {
            await syncBreakpoints()
            if isStopped { try? await loadFrames(token: generation) }
        }
    }

    // MARK: Breakpoints

    /// Called when the breakpoints of the program change (they are bookmarks of the program).
    func breakpointsChanged() {
        guard isActive, model.activeSession == mappedSession else { return }
        staticBreakpoints = model.breakpointMap
        Task { await syncBreakpoints() }
    }

    func toggleExtra(_ address: UInt64) {
        if extraBreakpoints.contains(address) { extraBreakpoints.remove(address) } else { extraBreakpoints.insert(address) }
        Task { await syncBreakpoints() }
    }

    /// Toggles a breakpoint at a dynamic address: in the program when it maps, otherwise only in this session.
    func toggleBreakpoint(dynamic address: UInt64) {
        if let s = toStatic(address), model.activeSession == mappedSession {
            model.toggleBreakpoint(address: s)
        } else {
            toggleExtra(address)
        }
    }

    private func syncBreakpoints() async {
        guard let connection, isActive else { return }
        var addresses = staticBreakpoints.filter(\.value).compactMap { toDynamic($0.key) }
        addresses += extraBreakpoints
        addresses = Array(Set(addresses)).sorted()
        let rules = conditions
        let body = try? await connection.request("setInstructionBreakpoints", [
            "breakpoints": addresses.map { address -> [String: Any] in
                var item: [String: Any] = ["instructionReference": "0x" + String(address, radix: 16)]
                if let rule = toStatic(address).flatMap({ rules[$0] }) {
                    if !rule.condition.isEmpty { item["condition"] = rule.condition }
                    if !rule.hitCount.isEmpty { item["hitCondition"] = rule.hitCount }
                }
                return item
            },
        ])
        let result = body?["breakpoints"] as? [[String: Any]] ?? []
        var status: [UInt64: Bool] = [:]
        for (i, address) in addresses.enumerated() {
            status[address] = i < result.count ? (result[i]["verified"] as? Bool ?? false) : false
            // commands to run at the stop are LLDB's own (the DAP protocol has none)
            if !isGDB, i < result.count, let id = result[i]["id"] as? Int,
               let rule = toStatic(address).flatMap({ rules[$0] }), !rule.commands.isEmpty {
                let lines = rule.commands.split(separator: "\n").map { "-o \"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
                await command("breakpoint command add \(lines.joined(separator: " ")) \(id)", echo: false)
            }
        }
        verified = status
    }

    /// Stops the process when `size` bytes at an address are read or written.
    func addWatchpoint(expression: String, size: Int, kind: String) {
        let text = expression.trimmingCharacters(in: .whitespaces)
        guard isStopped, !text.isEmpty else { return }
        Task {
            let result = await command("watchpoint set expression -w \(kind) -s \(size) -- \(text)", echo: true)
            // "Watchpoint created: Watchpoint 1: addr = 0x16fdff000 size = 4 state = enabled type = w"
            guard let range = result.range(of: #"Watchpoint (\d+): addr = (0x[0-9a-fA-F]+) size = (\d+)"#, options: .regularExpression)
            else {
                model.errorMessage = result.isEmpty ? tr("LLDB no pudo crear el punto de observación.") : result
                return
            }
            let parts = result[range].split(whereSeparator: { " :=".contains($0) }).map(String.init)
            guard parts.count >= 2, let id = Int(parts[1]) else { return }
            let address = parts.first { $0.hasPrefix("0x") } ?? text
            let label = kind == "write" ? tr("escritura") : kind == "read" ? tr("lectura") : tr("ambas")
            watchpoints.append(DebugWatchpoint(id: id, description: "\(address) · \(size) bytes · \(label)"))
        }
    }

    func removeWatchpoint(_ watchpoint: DebugWatchpoint) {
        watchpoints.removeAll { $0.id == watchpoint.id }
        Task { await command("watchpoint delete \(watchpoint.id)", echo: true) }
    }

    /// Ends the session at once (the app is quitting).
    func terminate() {
        connection?.stop()
        closeInput()
    }

    // MARK: Control

    private func resume(_ request: String, _ extra: [String: Any] = [:]) {
        guard let connection, isStopped, let thread = currentThread else { return }
        var args = extra
        args["threadId"] = thread
        generation += 1
        phase = .running
        status = tr("En ejecución")
        Task {
            do { try await connection.request(request, args) } catch { log(error.localizedDescription + "\n") }
        }
    }

    func resumeExecution() { resume("continue") }
    func stepInto() { resume("stepIn", ["granularity": "instruction"]) }
    func stepOver() { resume("next", ["granularity": "instruction"]) }
    func stepOut() { resume("stepOut") }
    /// Backwards, when the target can (record-and-replay servers).
    func stepBack() { resume("stepBack", ["granularity": "instruction"]) }
    func reverseContinue() { resume("reverseContinue") }

    func pause() {
        guard let connection, phase == .running else { return }
        Task { _ = try? await connection.request("pause", ["threadId": currentThread ?? threads.first?.id ?? 0]) }
    }

    /// Runs until `address` (a one-shot breakpoint).
    func run(to address: UInt64) {
        guard isStopped else { return }
        Task {
            await command("breakpoint set -a 0x\(String(address, radix: 16)) -o true", echo: false)
            resumeExecution()
        }
    }

    func run(toStatic address: String) {
        guard let d = toDynamic(address) else {
            model.errorMessage = tr("Esa dirección no pertenece al módulo que se está depurando.")
            return
        }
        run(to: d)
    }

    // MARK: Console

    /// Runs an LLDB command and returns what it printed.
    @discardableResult
    private func command(_ text: String, echo: Bool) async -> String {
        guard let connection else { return "" }
        if echo { log("(lldb) \(text)\n") }
        do {
            let result = try await connection.request("evaluate", ["expression": (isGDB ? "" : "`") + text, "context": "repl"])["result"]
                as? String ?? ""
            if echo, !result.isEmpty { log(result.hasSuffix("\n") ? result : result + "\n") }
            return result
        } catch {
            if echo { log(error.localizedDescription + "\n") }
            return ""
        }
    }

    func runConsole(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard isActive, !line.isEmpty else { return }
        Task {
            await command(line, echo: true)
            // a command may have changed registers, memory or the selected frame
            if isStopped { await reloadAfterWrite() }
        }
    }

    // MARK: Processes

    /// Processes of the current user, for "attach".
    static func processes() -> [ProcessItem] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-x", "-o", "pid=,comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<space]) else { return nil }
            let path = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            return ProcessItem(pid: pid, name: (path as NSString).lastPathComponent)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Extras: regions, platform, manual mappings, conditions, snapshots and traces

struct ManualMapping: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var dynamicBase: UInt64
    var staticBase: UInt64
    var length: UInt64
}

struct BreakpointRule: Codable, Hashable {
    var condition = ""
    var hitCount = ""
    /// Debugger commands run when the breakpoint is hit, one per line.
    var commands = ""
    var isEmpty: Bool { condition.isEmpty && hitCount.isEmpty && commands.isEmpty }
}

struct LoadedTrace: Identifiable {
    let id = UUID()
    let name: String
    let trace: DebugTrace
}

/// What changed between two instants.
struct SnapshotDifference: Identifiable {
    let id = UUID()
    let kind: String
    let what: String
    let before: String
    let after: String
}

extension DebugSession {
    private var rulesKey: String { "breakpointRules|" + (model.program?.name ?? "") }

    /// Condition, hit count and commands of each breakpoint, by static address.
    var conditions: [String: BreakpointRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: rulesKey),
                  let rules = try? JSONDecoder().decode([String: BreakpointRule].self, from: data) else { return [:] }
            return rules
        }
        set {
            let kept = newValue.filter { !$0.value.isEmpty }
            if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: rulesKey) }
            if isActive { Task { await syncBreakpoints() } }
        }
    }

    // MARK: regions, platform, unwind

    /// The memory map of the process, from the debugger.
    func loadRegions() {
        guard isStopped else { return }
        Task {
            let text = await command(isGDB ? "info proc mappings" : "memory region --all", echo: false)
            var out: [JSONRow] = []
            for line in text.split(separator: "\n") {
                // "[0x0000000100000000-0x0000000100004000) r-x __TEXT"
                guard let open = line.firstIndex(of: "["), let dash = line.firstIndex(of: "-"), let close = line.firstIndex(of: ")"),
                      open < dash, dash < close else { continue }
                let lo = String(line[line.index(after: open)..<dash]), hi = String(line[line.index(after: dash)..<close])
                let rest = line[line.index(after: close)...].split(separator: " ", maxSplits: 1).map(String.init)
                guard let start = Self.parse(lo), let end = Self.parse(hi), end > start else { continue }
                let perms = rest.first ?? ""
                guard perms != "---" || rest.count > 1 else { continue }
                var row: JSONRow = ["start": .string(hex(start)), "end": .string(hex(end - 1)),
                                    "size": .number(Double(end - start)), "perms": .string(perms),
                                    "name": .string(rest.count > 1 ? rest[1] : "")]
                if let s = toStatic(start) { row["address"] = .string(s) }
                out.append(row)
            }
            regions = out
            if out.isEmpty, !text.isEmpty { platformText = text }
        }
    }

    func loadPlatform() {
        guard isActive else { return }
        Task {
            if isGDB {
                platformText = await command("info inferiors", echo: false) + "\n" + (await command("show architecture", echo: false))
            } else {
                platformText = await command("platform status", echo: false) + "\n" + (await command("target list", echo: false))
                    + "\n" + (await command("process status", echo: false))
            }
        }
    }

    /// How the debugger unwinds the selected frame (CFA and saved-register rules).
    func loadUnwind() {
        guard isStopped, let pc else { return }
        Task {
            unwindText = isGDB ? await command("info frame", echo: false)
                : await command("image show-unwind --address 0x\(String(pc, radix: 16))", echo: false)
        }
    }

    // MARK: mappings

    func addMapping(name: String, dynamicBase: UInt64, staticBase: UInt64, length: UInt64) {
        manualMappings.append(ManualMapping(name: name, dynamicBase: dynamicBase, staticBase: staticBase, length: length))
        for i in frames.indices { frames[i].staticAddress = toStatic(frames[i].pc) }
        if isActive { Task { await syncBreakpoints() } }
    }

    func removeMapping(_ mapping: ManualMapping) {
        manualMappings.removeAll { $0.id == mapping.id }
        for i in frames.indices { frames[i].staticAddress = toStatic(frames[i].pc) }
        if isActive { Task { await syncBreakpoints() } }
    }

    /// One row per module: where it is loaded and whether it is the program in Studio.
    var mappingRows: [JSONRow] {
        var rows: [JSONRow] = modules.map { m in
            ["name": .string(m.name), "dynamic": .string(hex(m.base)),
             "static": .string(m.id == mappedModule ? hex(imageBase) : ""),
             "slide": .string(m.id == mappedModule ? slideDescription : ""),
             "kind": .string(m.id == mappedModule ? tr("Programa abierto") : tr("Módulo")), "path": .string(m.path)]
        }
        rows += manualMappings.map { m in
            ["name": .string(m.name), "dynamic": .string(hex(m.dynamicBase)), "static": .string(hex(m.staticBase)),
             "slide": .string("0x" + String(m.length, radix: 16)), "kind": .string(tr("Manual")), "path": .string(m.id.uuidString)]
        }
        return rows
    }

    // MARK: snapshots

    func rename(snapshot index: Int, _ name: String) {
        guard history.indices.contains(index) else { return }
        history[index].name = name.isEmpty ? nil : name
    }

    /// Registers and recorded memory that differ between two instants.
    func compare(_ a: DebugSnapshot, _ b: DebugSnapshot) -> [SnapshotDifference] {
        var out: [SnapshotDifference] = []
        var before: [String: String] = [:]
        for g in a.registerGroups { for r in g.registers { before[r.name] = r.value } }
        for g in b.registerGroups {
            for r in g.registers where before[r.name] != nil && before[r.name] != r.value {
                out.append(SnapshotDifference(kind: tr("Registro"), what: r.name, before: before[r.name] ?? "", after: r.value))
            }
        }
        if a.pc != b.pc {
            out.insert(SnapshotDifference(kind: "PC", what: tr("Contador de programa"), before: a.pc.map(hex) ?? "—",
                                          after: b.pc.map(hex) ?? "—"), at: 0)
        }
        for chunkB in b.memory {
            for chunkA in a.memory {
                let lo = max(chunkA.base, chunkB.base)
                let hi = min(chunkA.base &+ UInt64(chunkA.data.count), chunkB.base &+ UInt64(chunkB.data.count))
                guard hi > lo else { continue }
                var address = lo
                while address < hi, out.count < 4000 {
                    let x = chunkA.data[chunkA.data.startIndex + Int(address - chunkA.base)]
                    let y = chunkB.data[chunkB.data.startIndex + Int(address - chunkB.base)]
                    if x != y {
                        // gather the run of changed bytes
                        var end = address, old = "", new = ""
                        while end < hi, end - address < 16 {
                            let p = chunkA.data[chunkA.data.startIndex + Int(end - chunkA.base)]
                            let q = chunkB.data[chunkB.data.startIndex + Int(end - chunkB.base)]
                            if p == q { break }
                            old += String(format: "%02x ", p); new += String(format: "%02x ", q)
                            end += 1
                        }
                        out.append(SnapshotDifference(kind: tr("Memoria"), what: hex(address), before: old, after: new))
                        address = end
                    } else {
                        address += 1
                    }
                }
            }
        }
        return out
    }

    /// Reads every writable region of the process into the instant on screen (up to a limit).
    func captureAllMemory(limit: Int = 64 << 20) async -> Int {
        guard let connection, isStopped, !history.isEmpty else { return 0 }
        if regions.isEmpty {
            loadRegions()
            for _ in 0..<30 where regions.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        }
        var total = 0
        var chunks = history[history.count - 1].memory
        for region in regions where (region["perms"]?.text ?? "").contains("w") {
            guard let start = addressValue(region["start"]?.text ?? ""), let size = region["size"]?.int, size > 0 else { continue }
            var offset = 0
            while offset < size, total < limit {
                let count = min(1 << 20, size - offset)
                let body = try? await connection.request("readMemory", ["memoryReference": "0x" + String(start + UInt64(offset), radix: 16),
                                                                        "count": count])
                guard let data = (body?["data"] as? String).flatMap({ Data(base64Encoded: $0) }), !data.isEmpty else { break }
                chunks.append(MemoryChunk(base: start + UInt64(offset), data: data))
                total += data.count
                offset += data.count
            }
            if total >= limit { break }
        }
        history[history.count - 1].memory = chunks
        return total
    }

    /// Writes the recorded memory of an instant into the program open in Studio, where it maps.
    func copyToProgram(snapshot: DebugSnapshot) async -> Int {
        var written = 0
        for chunk in snapshot.memory {
            var offset = 0
            while offset < chunk.data.count {
                let count = min(2048, chunk.data.count - offset)
                let address = chunk.base &+ UInt64(offset)
                if let s = toStatic(address), toStatic(address &+ UInt64(count - 1)) != nil {
                    let bytes = chunk.data[(chunk.data.startIndex + offset)..<(chunk.data.startIndex + offset + count)]
                        .map { String(format: "%02x", $0) }.joined(separator: " ")
                    if (try? await model.engine.call("patchBytes", ["address": s, "bytes": bytes], as: JSONValue.self)) != nil {
                        written += count
                    }
                }
                offset += count
            }
        }
        await model.afterEdit(namesChanged: false)
        return written
    }

    /// The instant as text: frames, registers, code and memory.
    func export(snapshot s: DebugSnapshot) -> String {
        var out = "\(s.name ?? "") \(s.reason)  \(s.time)\n\n" + tr("Pila") + "\n"
        for f in s.frames { out += "  \(hex(f.pc))  \(f.name)\n" }
        for g in s.registerGroups where !g.registers.isEmpty {
            out += "\n\(g.name)\n"
            for r in g.registers { out += "  \(r.name) = \(r.value)\n" }
        }
        if !s.instructions.isEmpty {
            out += "\n" + tr("Código") + "\n"
            for i in s.instructions { out += "  \(hex(i.address))  \(i.bytes.padding(toLength: 24, withPad: " ", startingAt: 0)) \(i.text)\n" }
        }
        for chunk in s.memory {
            out += "\n" + tr("Memoria") + " \(hex(chunk.base)) (\(chunk.data.count) bytes)\n"
            for row in stride(from: 0, to: min(chunk.data.count, 1 << 16), by: 16) {
                let slice = chunk.data[(chunk.data.startIndex + row)..<(chunk.data.startIndex + min(row + 16, chunk.data.count))]
                out += "  \(hex(chunk.base &+ UInt64(row)))  " + slice.map { String(format: "%02x", $0) }.joined(separator: " ") + "\n"
            }
        }
        return out
    }

    // MARK: several traces

    /// Loads another trace next to the one on screen.
    func loadOtherTrace(from url: URL) throws {
        let trace = try JSONDecoder().decode(DebugTrace.self, from: Data(contentsOf: url))
        otherTraces.append(LoadedTrace(name: url.deletingPathExtension().lastPathComponent, trace: trace))
    }

    func closeOtherTrace(_ trace: LoadedTrace) { otherTraces.removeAll { $0.id == trace.id } }

    /// Puts another loaded trace on screen; the one that was there joins the others.
    func switchTrace(to other: LoadedTrace) {
        guard phase == .replay else { return }
        let current = LoadedTrace(name: traceName.isEmpty ? tr("Traza") : traceName,
                                  trace: DebugTrace(program: other.trace.program, slide: slide, mapped: mappedModule != nil,
                                                    modules: modules, snapshots: history))
        otherTraces.removeAll { $0.id == other.id }
        otherTraces.append(current)
        modules = other.trace.modules
        slide = other.trace.slide
        mappedModule = other.trace.mapped ? (other.trace.modules.first { $0.name == other.trace.program }?.id
                                             ?? other.trace.modules.first?.id) : nil
        history = other.trace.snapshots
        traceName = other.name
        viewing = nil
        view(snapshot: history.indices.last)
    }

    var snapshots: [DebugSnapshot] { history }

    // MARK: values under the mouse

    /// The value of a register or variable name, for the pop-up of the code views while stopped.
    func hoverValue(_ word: String) async -> String? {
        guard isStopped else {
            // looking at a recorded instant: only registers are known
            for g in registerGroups { if let r = g.registers.first(where: { $0.name == word }) { return r.value } }
            return nil
        }
        for g in registerGroups { if let r = g.registers.first(where: { $0.name == word }) { return r.value } }
        guard word.first?.isLetter == true || word.first == "_" else { return nil }
        let value = try? await evaluate(word)
        return value.flatMap { $0.isEmpty || $0.contains("error:") ? nil : $0 }
    }
}
