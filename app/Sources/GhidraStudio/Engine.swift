import Foundation

enum EngineError: LocalizedError {
    case notRunning
    case remote(String)
    case terminated

    var errorDescription: String? {
        switch self {
        case .notRunning: tr("El motor de Ghidra no está en marcha.")
        case .remote(let message): message
        case .terminated: tr("El motor de Ghidra se detuvo inesperadamente.")
        }
    }
}

/// Talks to the headless Ghidra engine (Resources/engine.sh) over line-delimited JSON.
@MainActor
final class Engine {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ghidra Studio", isDirectory: true)
    }

    static var logFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Ghidra Studio/engine.log")
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var isReady = false
    private(set) var version: String?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    func start() throws {
        guard process == nil else { return }
        let resources = Bundle.main.resourceURL!
        let script = resources.appendingPathComponent("engine.sh")
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logFile.path) {
            FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: Self.logFile)
        log?.seekToEndOfFile()
        log?.write("\n=== \(Date()) engine start ===\n".data(using: .utf8)!)

        let p = Process()
        var env = ProcessInfo.processInfo.environment
        env["STUDIO_LANG"] = AppLanguage.effectiveCode
        p.environment = env
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, Self.supportDirectory.path]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log?.write(data) }
        }
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

    func shutdown() {
        guard let process, process.isRunning else { return }
        let req = "{\"id\":0,\"method\":\"shutdown\"}\n".data(using: .utf8)!
        try? input?.write(contentsOf: req)
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning { process.terminate() }
    }

    func waitUntilReady() async throws {
        if isReady { return }
        guard process != nil else { throw EngineError.notRunning }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        try await waitUntilReady()
        guard let input else { throw EngineError.notRunning }
        let id = nextID
        nextID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(0x0A)
        let response: Data = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do { try input.write(contentsOf: data) } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: response).result
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            if event == "ready" {
                isReady = true
                version = obj["version"] as? String
                readyWaiters.forEach { $0.resume() }
                readyWaiters.removeAll()
            }
            onEvent?(event, obj)
        } else if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let error = obj["error"] as? String {
                cont.resume(throwing: EngineError.remote(error))
            } else {
                cont.resume(returning: line)
            }
        }
    }

    private func didTerminate() {
        isReady = false
        process = nil
        input = nil
        pending.values.forEach { $0.resume(throwing: EngineError.terminated) }
        pending.removeAll()
        readyWaiters.forEach { $0.resume(throwing: EngineError.terminated) }
        readyWaiters.removeAll()
        onEvent?("terminated", [:])
    }
}

private struct Envelope<R: Decodable>: Decodable {
    let result: R
}
