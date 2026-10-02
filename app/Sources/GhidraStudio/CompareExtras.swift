import AppKit
import SwiftUI

// MARK: - Version Tracking: functions of both programs

struct VTFunctionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source: [JSONRow] = []
    @State private var destination: [JSONRow] = []
    @State private var side = 0
    @State private var only = "all"
    @State private var error: String?
    /// Called with (source address, destination address) to start a manual match.
    let onMatch: (String, String) -> Void
    @State private var chosenSource: String?
    @State private var chosenDestination: String?

    private var columns: [ColumnSpec] {
        [ColumnSpec(key: "name", title: tr("Nombre"), width: 240, mono: true), .address(),
         ColumnSpec(key: "stateText", title: tr("Estado"), width: 150), ColumnSpec(key: "size", title: tr("Tamaño"), width: 60),
         ColumnSpec(key: "signature", title: tr("Firma"), width: 320, mono: true)]
    }

    private func rows(_ list: [JSONRow]) -> [JSONRow] {
        list.filter { only == "all" || $0["state"]?.text == only }.map { row in
            var r = row
            switch row["state"]?.text {
            case "accepted": r["stateText"] = .string(tr("Con coincidencia aceptada"))
            case "candidate": r["stateText"] = .string(tr("Con candidatas"))
            default: r["stateText"] = .string(tr("Sin coincidencia"))
            }
            return r
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $side) {
                    Text(tr("Origen (%@)", "\(source.count)")).tag(0)
                    Text(tr("Destino (%@)", "\(destination.count)")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $only) {
                    Text(tr("Todas")).tag("all")
                    Text(tr("Sin coincidencia")).tag("unmatched")
                    Text(tr("Con candidatas")).tag("candidate")
                    Text(tr("Aceptadas")).tag("accepted")
                }
                .labelsHidden().fixedSize()
                Spacer()
                Text("\(chosenSource ?? "—")  →  \(chosenDestination ?? "—")").font(.caption.monospaced()).foregroundStyle(.secondary)
                Button(tr("Coincidencia manual")) {
                    if let a = chosenSource, let b = chosenDestination { onMatch(a, b); dismiss() }
                }
                .disabled(chosenSource == nil || chosenDestination == nil)
                .help(tr("Elige una función en cada lado (con «Elegir») y crea la coincidencia entre las dos"))
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            GenericTable(rows: rows(side == 0 ? source : destination), columns: columns, storageKey: "vtFunctions", addressKey: nil,
                         actions: [RowAction(title: tr("Elegir")) { row in
                             if side == 0 { chosenSource = row["address"]?.text } else { chosenDestination = row["address"]?.text }
                         }],
                         onOpen: { row in if side == 1, let a = row["address"]?.string { model.go(a) } })
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .frame(width: 940, height: 560)
        .task {
            do {
                let result: JSONRow = try await model.engine.call("vtFunctions")
                source = result["source"]?.array.map(\.object) ?? []
                destination = result["destination"]?.array.map(\.object) ?? []
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - BSim extras

struct BSimExtrasSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let database: String
    let executables: [JSONRow]
    @State private var tab = 0
    @State private var similarity = 0.7
    @State private var rows: [JSONRow] = []
    @State private var features: [JSONRow] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text(tr("Vista general")).tag(0)
                    Text(tr("Características de la función")).tag(1)
                    Text(tr("Ejecutables")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            switch tab {
            case 0:
                HStack {
                    Text(tr("Similitud ≥ %@", String(format: "%.2f", similarity))).monospacedDigit()
                    Slider(value: $similarity, in: 0...1, step: 0.05).frame(width: 160)
                    Button(tr("Consultar todo el programa")) { overview() }.disabled(busy || model.program == nil)
                    Spacer()
                }
                .padding(10)
                GenericTable(rows: rows,
                             columns: [ColumnSpec(key: "name", title: tr("Función"), width: 240, mono: true), .address(),
                                       ColumnSpec(key: "hits", title: tr("Parecidas en la base"), width: 130),
                                       ColumnSpec(key: "selfSignificance", title: tr("Significancia propia"), width: 130)],
                             storageKey: "bsimOverview")
            case 1:
                HStack {
                    Text(tr("Lo que BSim extrae de %@ para compararla", model.functionDetails?.name ?? "—")).font(.callout)
                    Spacer()
                    Button(tr("Calcular")) { loadFeatures() }.disabled(busy || model.functionDetails == nil)
                }
                .padding(10)
                GenericTable(rows: features,
                             columns: [ColumnSpec(key: "hash", title: "Hash", width: 90, mono: true),
                                       ColumnSpec(key: "kind", title: tr("Clase"), width: 90),
                                       ColumnSpec(key: "text", title: tr("De dónde sale"), width: 620, mono: true)],
                             storageKey: "bsimFeatures", addressKey: nil)
            default:
                GenericTable(rows: executables,
                             columns: [ColumnSpec(key: "name", title: tr("Ejecutable"), width: 220, mono: true),
                                       ColumnSpec(key: "architecture", title: tr("Arquitectura"), width: 160),
                                       ColumnSpec(key: "compiler", title: tr("Compilador"), width: 100),
                                       ColumnSpec(key: "md5", title: "MD5", width: 260, mono: true)],
                             storageKey: "bsimExecutables", addressKey: nil,
                             actions: [RowAction(title: tr("Abrir en Studio")) { row in open(row) }],
                             onOpen: { row in open(row) })
            }
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .frame(width: 900, height: 560)
    }

    private func overview() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result: JSONRow = try await model.engine.call("bsimOverview", ["database": database, "similarity": similarity])
                rows = result["rows"]?.array.map(\.object) ?? []
                message = tr("%@ funciones consultadas, %@ con parecidas", result["queried"]?.text ?? "0", result["withMatches"]?.text ?? "0")
            } catch { message = error.localizedDescription }
        }
    }

    private func loadFeatures() {
        guard let entry = model.functionDetails?.entry else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                features = try await model.engine.call("bsimFeatures", ["address": entry])
                message = tr("%@ características", "\(features.count)")
            } catch { message = error.localizedDescription }
        }
    }

    /// Opens the program of the project that the executable of a result came from.
    private func open(_ row: JSONRow) {
        Task {
            do {
                let found: [JSONRow] = try await model.engine.call("projectFind", ["md5": row["md5"]?.text ?? "", "name": row["name"]?.text ?? ""])
                guard let path = (found.first { $0["exact"]?.bool == true } ?? found.first)?["path"]?.string else {
                    message = tr("Ese ejecutable no está en el proyecto abierto.")
                    return
                }
                model.openProgram(domainPath: path)
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

// MARK: - Function ID debugging

struct FidDebugSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The database selected in the window (for statistics, repack and read-only copies).
    let database: String?
    @State private var tab = 0
    @State private var hash: JSONRow = [:]
    @State private var rows: [JSONRow] = []
    @State private var kind = "name"
    @State private var value = ""
    @State private var stats: JSONRow = [:]
    @State private var message: String?

    private var columns: [ColumnSpec] {
        [ColumnSpec(key: "name", title: tr("Nombre"), width: 260, mono: true),
         ColumnSpec(key: "library", title: tr("Biblioteca"), width: 200),
         ColumnSpec(key: "database", title: tr("Base de datos"), width: 130),
         ColumnSpec(key: "size", title: tr("Unidades"), width: 60),
         ColumnSpec(key: "fullHash", title: tr("Hash completo"), width: 140, mono: true),
         ColumnSpec(key: "specificHash", title: tr("Hash específico"), width: 140, mono: true),
         ColumnSpec(key: "specificMatch", title: tr("Específico igual"), width: 100),
         ColumnSpec(key: "domainPath", title: tr("Ruta"), width: 200),
         ColumnSpec(key: "excluded", title: tr("Excluida"), width: 60),
         ColumnSpec(key: "forced", title: tr("Forzada"), width: 60)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text(tr("Hash de la función actual")).tag(0)
                    Text(tr("Buscar en las bases")).tag(1)
                    Text(tr("Estadísticas y copias")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button(tr("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            switch tab {
            case 0:
                VStack(alignment: .leading, spacing: 4) {
                    if hash.isEmpty {
                        Text(tr("Coloca el cursor en una función del programa.")).foregroundStyle(.secondary)
                    } else {
                        Text("\(hash["function"]?.text ?? "") · \(hash["address"]?.text ?? "")").font(.headline)
                        Text(tr("Hash completo %@ (%@ unidades) · hash específico %@ (+%@)", hash["fullHash"]?.text ?? "",
                                hash["codeUnits"]?.text ?? "", hash["specificHash"]?.text ?? "", hash["specificSize"]?.text ?? ""))
                            .font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                GenericTable(rows: hash["matches"]?.array.map(\.object) ?? [], columns: columns, storageKey: "fidDebug", addressKey: nil)
            case 1:
                HStack {
                    Picker("", selection: $kind) {
                        Text(tr("Nombre contiene")).tag("name")
                        Text(tr("Nombre (expresión regular)")).tag("regex")
                        Text(tr("Ruta contiene")).tag("path")
                        Text(tr("Hash completo")).tag("fullHash")
                        Text(tr("Hash específico")).tag("specificHash")
                    }
                    .labelsHidden().fixedSize()
                    TextField(tr("Valor"), text: $value).textFieldStyle(.roundedBorder).font(.body.monospaced()).onSubmit(search)
                    Button(tr("Buscar"), action: search).disabled(value.isEmpty)
                }
                .padding(10)
                GenericTable(rows: rows, columns: columns, storageKey: "fidSearch", addressKey: nil)
            default:
                VStack(alignment: .leading, spacing: 8) {
                    if let database {
                        Text((database as NSString).lastPathComponent).font(.headline)
                        Text(tr("%@ funciones · %@ hashes distintos · %@ excluidas · %@ forzadas", stats["functions"]?.text ?? "—",
                                stats["distinctHashes"]?.text ?? "—", stats["excluded"]?.text ?? "—", stats["forced"]?.text ?? "—"))
                            .font(.callout)
                        HStack {
                            Button(tr("Guardar copia de solo lectura (.fidbf)…")) { save("fidReadOnly", ext: "fidbf") }
                            Button(tr("Reempaquetar en un archivo nuevo (.fidb)…")) { save("fidRepack", ext: "fidb") }
                                .disabled(database.hasSuffix(".fidbf"))
                        }
                    } else {
                        Text(tr("Elige una base de datos en la ventana de Function ID.")).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                GenericTable(rows: stats["libraries"]?.array.map(\.object) ?? [],
                             columns: [ColumnSpec(key: "family", title: tr("Familia"), width: 200),
                                       ColumnSpec(key: "version", title: tr("Versión"), width: 90),
                                       ColumnSpec(key: "variant", title: tr("Variante"), width: 110),
                                       ColumnSpec(key: "functions", title: tr("Funciones"), width: 80),
                                       ColumnSpec(key: "language", title: tr("Lenguaje"), width: 170, mono: true),
                                       ColumnSpec(key: "compiler", title: tr("Compilador"), width: 90),
                                       ColumnSpec(key: "ghidra", title: "Ghidra", width: 70)],
                             storageKey: "fidStats", addressKey: nil)
            }
            if let message {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .frame(width: 980, height: 560)
        .task(id: tab) {
            if tab == 0, model.program != nil, let address = model.editTarget {
                do { hash = try await model.engine.call("fidHash", ["address": address]) } catch {
                    hash = [:]
                    message = error.localizedDescription
                }
            }
            if tab == 2, let database {
                do { stats = try await model.engine.call("fidStatistics", ["path": database]) } catch { message = error.localizedDescription }
            }
        }
    }

    private func search() {
        Task {
            do {
                rows = try await model.engine.call("fidSearch", ["kind": kind, "value": value])
                message = tr("%@ resultados", "\(rows.count)")
            } catch { message = error.localizedDescription }
        }
    }

    private func save(_ method: String, ext: String) {
        guard let database else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ((database as NSString).lastPathComponent as NSString).deletingPathExtension + "-copia." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                // the save panel already asked before replacing
                try? FileManager.default.removeItem(at: url)
                let result: JSONRow = try await model.engine.call(method, ["path": database, "output": url.path])
                message = tr("Guardado en %@", result["path"]?.text ?? url.path)
            } catch { message = error.localizedDescription }
        }
    }
}
