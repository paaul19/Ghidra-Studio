import AppKit
import SwiftUI

// MARK: - Recently used types

extension AppModel {
    /// The data types applied most recently, newest first (shared by every program).
    var recentTypes: [String] { UserDefaults.standard.stringArray(forKey: "recentTypes") ?? [] }

    func noteType(_ type: String) {
        let name = type.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var list = recentTypes.filter { $0 != name }
        list.insert(name, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: "recentTypes")
        recentTypesVersion += 1
    }

    /// Applies a type at the cursor (or at an address), like choosing it from the classic's "Recently Used".
    func applyType(_ type: String, address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        run("createData", ["address": target, "type": type], namesChanged: false)
    }

    func applyLastType(address: String? = nil) {
        guard let type = recentTypes.first else {
            errorMessage = tr("Todavía no has aplicado ningún tipo.")
            return
        }
        applyType(type, address: address)
    }

    // MARK: Structure field under the cursor

    /// Edits the name, type and comment of the structure field laid out at an address, without the structure editor.
    func requestEditField(address: String? = nil) {
        guard let target = address ?? editTarget else { return }
        Task {
            do {
                let field: JSONRow = try await engine.call("fieldAt", ["address": target])
                let path = field["type"]?.text ?? ""
                let ordinal = field["ordinal"]?.int ?? 0
                formRequest = FormRequest(
                    title: tr("Campo de %@", field["typeName"]?.text ?? ""),
                    message: tr("Offset 0x%@ · %@ bytes. El cambio afecta a todos los lugares donde se usa la estructura.",
                                String(field["offset"]?.int ?? 0, radix: 16), field["length"]?.text ?? ""),
                    fields: [
                        FormField(key: "name", title: tr("Nombre"), value: field["name"]?.text ?? ""),
                        FormField(key: "type", title: tr("Tipo"), value: field["fieldType"]?.text ?? ""),
                        FormField(key: "comment", title: tr("Comentario"), value: field["comment"]?.text ?? "", mono: false),
                    ]) { values in
                        let type = values["type"] ?? ""
                        try await self.edit("editField", ["path": path, "ordinal": ordinal, "type": type,
                                                          "name": values["name"] ?? "", "comment": values["comment"] ?? ""])
                        self.noteType(type)
                        // the open structure shows the old field until it is read again
                        let open = Array(self.expandedData.keys)
                        self.expandedData = [:]
                        open.forEach { self.toggleData($0) }
                    }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Assembler with wildcards

/// Ghidra's wildcard assembler: an instruction with `Q1`-style wildcards, its possible encodings and where they appear.
struct WildAssemblerPanel: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var encodings: [JSONRow] = []
    @State private var hits: [JSONRow] = []
    @State private var total = 0
    @State private var onlySelection = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Ensamblador con comodines")) {
                if busy { ProgressView().controlSize(.small) }
                Toggle(tr("Solo en la selección"), isOn: $onlySelection).disabled(model.programSelection == nil)
                Button(tr("Ensamblar")) { run(search: false) }.disabled(text.isEmpty || busy)
                Button(tr("Buscar en memoria")) { run(search: true) }.disabled(text.isEmpty || busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                TextField(tr("Instrucción, p. ej. mov `Q1`, `Q2/x1.`"), text: $text)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    .onSubmit { run(search: false) }
                Text(tr("Un comodín va entre acentos graves: `Q1` admite cualquier operando, `Q1/regex` solo los que cumplan la expresión, `Q1[..]` un número de cualquier valor y `Q1[10..20]` uno de ese rango. En los patrones, «..» y «.» son bits libres."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(3) }
            }
            .padding(10)
            Divider()
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("Codificaciones: %@ (de %@ combinaciones)", "\(encodings.count)", "\(total)"))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                    GenericTable(rows: encodings, columns: [
                        ColumnSpec(key: "pattern", title: tr("Patrón"), width: 260, mono: true),
                        ColumnSpec(key: "length", title: tr("Bytes"), width: 50),
                        ColumnSpec(key: "wildcards", title: tr("Comodines"), width: 480, mono: true),
                    ], storageKey: "wildEncodings", addressKey: nil)
                }
                .frame(minHeight: 70)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("Apariciones: %@", "\(hits.count)"))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                    GenericTable(rows: hits, columns: [
                        .address(), ColumnSpec(key: "function", title: tr("Función"), width: 150, mono: true),
                        ColumnSpec(key: "bytes", title: "Bytes", width: 120, mono: true),
                        ColumnSpec(key: "code", title: tr("Instrucción"), width: 220, mono: true),
                        ColumnSpec(key: "wildcards", title: tr("Comodines"), width: 260, mono: true),
                    ], storageKey: "wildHits", onOpen: { row in if let a = row["address"]?.string { model.go(a) } })
                }
                .frame(minHeight: 70)
            }
        }
    }

    private func run(search: Bool) {
        busy = true
        message = nil
        var params: [String: Any] = ["address": model.editTarget ?? model.current?.address ?? "0",
                                     "instruction": text, "search": search, "max": 2000]
        if onlySelection, let selection = model.programSelection { params["ranges"] = selection.ranges }
        Task {
            do {
                let result: JSONRow = try await model.engine.call("wildAssemble", params)
                encodings = result["encodings"]?.array.map(\.object) ?? []
                total = result["total"]?.int ?? 0
                if search { hits = result["hits"]?.array.map(\.object) ?? [] }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
