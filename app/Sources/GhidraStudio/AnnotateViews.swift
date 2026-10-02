import AppKit
import SwiftUI

// MARK: - Equates

struct EquatesPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EngineTable(method: "equateTable",
                    columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 220, mono: true),
                              ColumnSpec(key: "value", title: tr("Valor"), width: 110, mono: true),
                              ColumnSpec(key: "decimal", title: "Decimal", width: 100, mono: true),
                              ColumnSpec(key: "references", title: tr("Usos"), width: 60),
                              .address(tr("Primer uso"))],
                    actions: [
                        RowAction(title: tr("Renombrar…")) { row in
                            let name = row["name"]?.text ?? ""
                            model.formRequest = FormRequest(title: tr("Renombrar equate"),
                                                            fields: [FormField(key: "name", title: tr("Nombre nuevo"), value: name)],
                                                            origin: "tools") { values in
                                try await model.edit("renameEquate", ["name": name, "newName": values["name"] ?? ""], namesChanged: false)
                            }
                        },
                        RowAction(title: tr("Quitar"), destructive: true) { row in
                            model.run("removeEquate", ["name": row["name"]?.text ?? ""], namesChanged: false)
                        },
                    ])
    }
}

// MARK: - Comments

struct CommentsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var historyOf: String?

    private let kinds = ColumnSpec(key: "kind", title: tr("Tipo"), width: 80)

    var body: some View {
        VSplitView {
            EngineTable(method: "commentTable",
                        columns: [.address(), kinds, ColumnSpec(key: "comment", title: tr("Comentario"), width: 420),
                                  ColumnSpec(key: "function", title: tr("Función"), width: 180, mono: true)],
                        actions: [
                            RowAction(title: tr("Historial")) { row in historyOf = row["address"]?.text },
                            RowAction(title: tr("Editar…")) { row in
                                model.requestComment(address: row["address"]?.text, kind: row["kind"]?.text ?? "eol")
                            },
                        ])
                .frame(minHeight: 200)
            if let historyOf {
                VStack(spacing: 0) {
                    HStack {
                        Text(tr("Historial de comentarios en %@", historyOf)).font(.caption.weight(.semibold))
                        Spacer()
                        Button(tr("Cerrar")) { self.historyOf = nil }.controlSize(.small)
                    }
                    .padding(8)
                    EngineTable(method: "commentHistory", params: ["address": historyOf],
                                columns: [ColumnSpec(key: "date", title: tr("Fecha"), width: 130), ColumnSpec(key: "user", title: tr("Usuario"), width: 90),
                                          kinds, ColumnSpec(key: "comment", title: tr("Comentario"), width: 420)],
                                addressKey: nil, reloadKey: historyOf)
                }
                .frame(minHeight: 140)
            }
        }
    }
}

// MARK: - Labels

struct LabelsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var wholeProgram = false

    var body: some View {
        let address = model.editTarget ?? ""
        VSplitView {
            VStack(spacing: 0) {
                PanelHeader(tr("Etiquetas en %@", address)) {
                    Button(tr("Añadir…")) { model.requestLabel(address: address) }
                    Button(tr("Punto de entrada")) { model.run("setEntryPoint", ["address": address, "on": true], namesChanged: false) }
                        .help(tr("Marca esta dirección como punto de entrada externo"))
                    Button(tr("Quitar punto de entrada")) { model.run("setEntryPoint", ["address": address, "on": false], namesChanged: false) }
                }
                EngineTable(method: "labelsAt", params: ["address": address],
                            columns: [ColumnSpec(key: "name", title: tr("Nombre"), width: 220, mono: true),
                                      ColumnSpec(key: "namespace", title: "Namespace", width: 140),
                                      ColumnSpec(key: "primary", title: tr("Primaria"), width: 70),
                                      ColumnSpec(key: "pinned", title: tr("Fijada"), width: 60),
                                      ColumnSpec(key: "entry", title: tr("Entrada"), width: 60),
                                      ColumnSpec(key: "source", title: tr("Origen"), width: 110),
                                      ColumnSpec(key: "type", title: tr("Tipo"), width: 90)],
                            addressKey: nil,
                            actions: [
                                RowAction(title: tr("Hacer primaria")) { row in
                                    model.run("setPrimaryLabel", ["address": address, "name": row["name"]?.text ?? ""])
                                },
                                RowAction(title: tr("Fijar / soltar")) { row in
                                    model.run("setPinned", ["address": address, "name": row["name"]?.text ?? "",
                                                           "pinned": !(row["pinned"]?.bool ?? false)], namesChanged: false)
                                },
                                RowAction(title: tr("Quitar"), destructive: true) { row in
                                    model.run("deleteLabel", ["address": address, "name": row["name"]?.text ?? ""])
                                },
                            ],
                            reloadKey: address)
            }
            .frame(minHeight: 160)
            VStack(spacing: 0) {
                PanelHeader(tr("Historial de etiquetas")) {
                    Toggle(tr("Todo el programa"), isOn: $wholeProgram).toggleStyle(.checkbox)
                }
                EngineTable(method: "labelHistory", params: wholeProgram ? [:] : ["address": address],
                            columns: [.address(), ColumnSpec(key: "label", title: tr("Etiqueta"), width: 240, mono: true),
                                      ColumnSpec(key: "action", title: tr("Acción"), width: 100),
                                      ColumnSpec(key: "user", title: tr("Usuario"), width: 90),
                                      ColumnSpec(key: "date", title: tr("Fecha"), width: 130)],
                            reloadKey: "\(address)|\(wholeProgram)")
            }
            .frame(minHeight: 160)
        }
    }
}

// MARK: - References

struct ReferencesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSONRow = [:]

    var body: some View {
        let address = model.editTarget ?? ""
        VStack(spacing: 0) {
            PanelHeader("\(info["address"]?.text ?? address)  \(info["mnemonic"]?.text ?? "") \(info["operands"]?.array.map(\.text).joined(separator: ", ") ?? "")") {
                Button(tr("Añadir referencia…")) { add(address) }
            }
            GenericTable(rows: info["references"]?.array.map(\.object) ?? [],
                         columns: [ColumnSpec(key: "operand", title: tr("Operando"), width: 70),
                                   ColumnSpec(key: "target", title: tr("Destino"), width: 200, mono: true),
                                   ColumnSpec(key: "label", title: tr("Etiqueta"), width: 180, mono: true),
                                   ColumnSpec(key: "type", title: tr("Tipo"), width: 150),
                                   ColumnSpec(key: "kind", title: tr("Clase"), width: 80),
                                   ColumnSpec(key: "primary", title: tr("Primaria"), width: 70),
                                   ColumnSpec(key: "source", title: tr("Origen"), width: 100)],
                         storageKey: "referencesOf", addressKey: "to",
                         actions: [
                            RowAction(title: tr("Hacer primaria")) { row in change(row, ["primary": true]) },
                            RowAction(title: tr("Cambiar tipo…")) { row in
                                let types = (info["memoryTypes"]?.array ?? []).map(\.text) + (info["dataTypes"]?.array ?? []).map(\.text)
                                model.formRequest = FormRequest(title: tr("Tipo de referencia"),
                                                                fields: [FormField(key: "type", title: tr("Tipo"), kind: .choice(types),
                                                                                   value: row["type"]?.text ?? "")],
                                                                origin: "tools") { values in
                                    try await model.edit("editReference", params(row).merging(["type": values["type"] ?? ""]) { _, n in n },
                                                         namesChanged: false)
                                }
                            },
                            RowAction(title: tr("Borrar"), destructive: true) { row in change(row, ["delete": true]) },
                         ])
        }
        .task(id: "\(address)|\(model.editCount)|\(model.undo?.undoName ?? "")") {
            info = (try? await model.engine.call("referencesOf", ["address": address])) ?? [:]
        }
    }

    private func params(_ row: JSONRow) -> [String: Any] {
        ["address": row["from"]?.text ?? "", "to": row["to"]?.text ?? "", "operand": row["operand"]?.int ?? -1]
    }

    private func change(_ row: JSONRow, _ extra: [String: Any]) {
        model.run("editReference", params(row).merging(extra) { _, n in n }, namesChanged: false)
    }

    private func add(_ address: String) {
        let types = [""] + (info["memoryTypes"]?.array ?? []).map(\.text) + (info["dataTypes"]?.array ?? []).map(\.text)
        let operands = info["operands"]?.array ?? []
        let registers = [""] + (info["registers"]?.array ?? []).map(\.text)
        model.formRequest = FormRequest(
            title: tr("Añadir referencia"),
            message: tr("Desde %@", address),
            fields: [
                FormField(key: "kind", title: tr("Clase"), kind: .choice(["memory", "offset", "stack", "register", "external"]), value: "memory"),
                FormField(key: "operand", title: tr("Operando"),
                          kind: .choice(["-1"] + operands.indices.map(String.init)), value: operands.isEmpty ? "-1" : "0"),
                FormField(key: "to", title: tr("Dirección de destino (memoria, offset, externa)")),
                FormField(key: "type", title: tr("Tipo (vacío: DATA)"), kind: .choice(types), value: ""),
                FormField(key: "offset", title: tr("Offset (clase offset) u offset de pila (clase stack)"), value: "0"),
                FormField(key: "register", title: tr("Registro (clase register)"), kind: .choice(registers), value: ""),
                FormField(key: "library", title: tr("Biblioteca (clase external)")),
                FormField(key: "label", title: tr("Símbolo externo (clase external)")),
                FormField(key: "primary", title: tr("Primaria"), kind: .toggle, value: "true"),
            ],
            actionTitle: tr("Añadir"), origin: "tools") { values in
                let text = values["offset"] ?? "0"
                let negative = text.hasPrefix("-")
                let digits = text.replacingOccurrences(of: "-", with: "")
                let magnitude = digits.hasPrefix("0x") ? Int(digits.dropFirst(2), radix: 16) ?? 0 : Int(digits) ?? 0
                try await model.edit("addReferenceEx", [
                    "address": address, "kind": values["kind"] ?? "memory", "operand": Int(values["operand"] ?? "-1") ?? -1,
                    "to": values["to"] ?? "", "type": values["type"] ?? "", "offset": negative ? -magnitude : magnitude,
                    "register": values["register"] ?? "", "library": values["library"] ?? "", "label": values["label"] ?? "",
                    "primary": values["primary"] == "true",
                ], namesChanged: false)
            }
    }
}

// MARK: - Register values

struct RegisterValuesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var register = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Valores fijados de registros, por rangos")) {
                TextField(tr("Registro"), text: $register).textFieldStyle(.roundedBorder).frame(width: 110)
                Button(tr("Fijar valor…")) {
                    if let a = model.editTarget { model.requestSetRegister(start: a, end: nil) }
                }
            }
            EngineTable(method: "registerValues", params: ["register": register],
                        columns: [ColumnSpec(key: "register", title: tr("Registro"), width: 100, mono: true),
                                  .address(tr("Desde")), .address(tr("Hasta"), key: "end"),
                                  ColumnSpec(key: "value", title: tr("Valor"), width: 160, mono: true),
                                  ColumnSpec(key: "context", title: tr("Contexto"), width: 70)],
                        endKey: "end",
                        actions: [RowAction(title: tr("Quitar"), destructive: true) { row in
                            model.run("clearRegisterValue", ["register": row["register"]?.text ?? "", "address": row["address"]?.text ?? "",
                                                             "end": row["end"]?.text ?? ""], namesChanged: false)
                        }],
                        reloadKey: register)
        }
    }
}

// MARK: - Function tags

struct FunctionTagsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PanelHeader(tr("Etiquetas de función")) {
                    Button(tr("Nueva…")) { edit(nil) }
                    if let fn = model.current?.function, let selected {
                        Button(tr("Poner a la función actual")) {
                            model.run("setFunctionTag", ["address": fn, "tag": selected, "on": true], namesChanged: false)
                        }
                        Button(tr("Quitársela")) {
                            model.run("setFunctionTag", ["address": fn, "tag": selected, "on": false], namesChanged: false)
                        }
                    }
                }
                EngineTable(method: "functionTags",
                            columns: [ColumnSpec(key: "name", title: tr("Etiqueta"), width: 180),
                                      ColumnSpec(key: "uses", title: tr("Funciones"), width: 80),
                                      ColumnSpec(key: "comment", title: tr("Comentario"), width: 260)],
                            addressKey: nil,
                            actions: [
                                RowAction(title: tr("Ver funciones")) { row in selected = row["name"]?.text },
                                RowAction(title: tr("Editar…")) { row in edit(row) },
                                RowAction(title: tr("Borrar"), destructive: true) { row in
                                    model.run("editFunctionTag", ["name": row["name"]?.text ?? "", "delete": true], namesChanged: false)
                                },
                            ],
                            onOpen: { row in selected = row["name"]?.text })
            }
            .frame(minWidth: 420)
            VStack(spacing: 0) {
                PanelHeader(selected.map { tr("Funciones con «%@»", $0) } ?? tr("Elige una etiqueta")) { EmptyView() }
                if let selected {
                    EngineTable(method: "functionsWithTag", params: ["name": selected],
                                columns: [.address(), ColumnSpec(key: "name", title: tr("Función"), width: 240, mono: true)],
                                reloadKey: selected)
                } else {
                    Spacer()
                }
            }
            .frame(minWidth: 300)
        }
    }

    private func edit(_ row: JSONRow?) {
        let name = row?["name"]?.text ?? ""
        model.formRequest = FormRequest(
            title: row == nil ? tr("Nueva etiqueta de función") : tr("Editar etiqueta de función"),
            fields: [FormField(key: "name", title: tr("Nombre"), value: name, mono: false),
                     FormField(key: "comment", title: tr("Comentario"), value: row?["comment"]?.text ?? "", mono: false)],
            origin: "tools") { values in
                try await model.edit("editFunctionTag", ["name": row == nil ? (values["name"] ?? "") : name,
                                                        "newName": values["name"] ?? "", "comment": values["comment"] ?? ""],
                                     namesChanged: false)
            }
    }
}

// MARK: - Function extras

struct FunctionExtrasPanel: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSONRow = [:]
    @State private var error: String?

    var body: some View {
        let fn = model.current?.function ?? ""
        VStack(spacing: 0) {
            if fn.isEmpty || info.isEmpty {
                ContentUnavailableView(tr("Sin función"), systemImage: "f.cursive",
                                       description: Text(error ?? tr("Coloca el cursor dentro de una función.")))
            } else {
                Form {
                    Section(info["name"]?.text ?? fn) {
                        LabeledContent(tr("Thunk de")) {
                            Text(info["thunk"]?.text.isEmpty == false ? info["thunk"]!.text : "—").font(.callout.monospaced())
                            Button(tr("Cambiar…")) { model.requestThunk() }
                        }
                        LabeledContent(tr("Bytes que libera de la pila (purge)")) {
                            Text(info["purge"]?.text.isEmpty == false ? info["purge"]!.text : "—").font(.callout.monospaced())
                            Button(tr("Cambiar…")) { ask(tr("Purge"), "purge", info["purge"]?.text ?? "") }
                        }
                        LabeledContent("Call fixup") {
                            Text(info["callFixup"]?.text.isEmpty == false ? info["callFixup"]!.text : "—").font(.callout.monospaced())
                            Button(tr("Cambiar…")) { fixup() }
                        }
                        LabeledContent(tr("Almacenamiento personalizado")) {
                            Text(info["customStorage"]?.bool == true ? tr("Sí") : tr("No"))
                        }
                    }
                    Section(tr("Dónde vive cada parámetro")) {
                        LabeledContent(tr("Retorno")) {
                            Text(info["returnStorage"]?.text ?? "").font(.callout.monospaced())
                            Button(tr("Cambiar…")) { storage(-1, info["returnStorage"]?.text ?? "") }
                        }
                        ForEach(Array((info["parameters"]?.array ?? []).enumerated()), id: \.offset) { _, p in
                            let o = p.object
                            LabeledContent("\(o["type"]?.text ?? "") \(o["name"]?.text ?? "")") {
                                Text(o["storage"]?.text ?? "").font(.callout.monospaced())
                                Button(tr("Cambiar…")) { storage(o["ordinal"]?.int ?? 0, o["storage"]?.text ?? "") }
                            }
                        }
                        Text(tr("Escribe el almacenamiento como lo muestra Ghidra: x0:8, Stack[0x10]:4 o varias piezas separadas por comas."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button(tr("Recrear la función")) { model.run("recreateFunction", ["address": fn]) }
                        Button(tr("Cambio de profundidad de pila en la instrucción del cursor…")) { model.requestStackDepthChange() }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task(id: "\(fn)|\(model.editCount)|\(model.undo?.undoName ?? "")") {
            guard !fn.isEmpty else { info = [:]; return }
            do { info = try await model.engine.call("functionExtras", ["address": fn]); error = nil }
            catch { info = [:]; self.error = error.localizedDescription }
        }
    }

    private func ask(_ title: String, _ key: String, _ value: String) {
        let fn = model.current?.function ?? ""
        model.formRequest = FormRequest(title: title, fields: [FormField(key: "v", title: tr("Valor (vacío: desconocido)"), value: value)],
                                        origin: "tools") { values in
            try await model.edit("setFunctionExtras", ["address": fn, key: values["v"] ?? ""], namesChanged: false)
        }
    }

    private func fixup() {
        let fn = model.current?.function ?? ""
        let names = [""] + (info["callFixups"]?.array ?? []).map(\.text)
        model.formRequest = FormRequest(title: "Call fixup",
                                        fields: [FormField(key: "v", title: "Call fixup", kind: .choice(names), value: info["callFixup"]?.text ?? "")],
                                        origin: "tools") { values in
            try await model.edit("setFunctionExtras", ["address": fn, "callFixup": values["v"] ?? ""], namesChanged: false)
        }
    }

    private func storage(_ ordinal: Int, _ value: String) {
        let fn = model.current?.function ?? ""
        model.formRequest = FormRequest(title: tr("Almacenamiento"),
                                        message: tr("Activa el almacenamiento personalizado de la función."),
                                        fields: [FormField(key: "v", title: tr("Almacenamiento"), value: value, placeholder: "x0:8")],
                                        origin: "tools") { values in
            try await model.edit("setParameterStorage", ["address": fn, "ordinal": ordinal, "storage": values["v"] ?? ""])
        }
    }
}

// MARK: - Instruction info

struct InstructionPanel: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSONRow = [:]
    @State private var pseudo: [JSONRow] = []

    var body: some View {
        let address = model.editTarget ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if info.isEmpty {
                    Text(tr("No hay una instrucción en %@. Abajo, lo que saldría al desensamblar aquí.", address))
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(info["address"]?.text ?? "")  \(info["text"]?.text ?? "")").font(.system(.title3, design: .monospaced))
                        Spacer()
                        Button(tr("Modificar flujo, fallthrough o longitud…")) { model.requestInstructionOverrides() }
                    }
                    grid([(tr("Longitud"), info["length"]?.text ?? ""), (tr("Tipo de flujo"), info["flowType"]?.text ?? ""),
                          (tr("Flujo forzado"), info["flowOverride"]?.text ?? ""),
                          ("Fallthrough", (info["fallthrough"]?.text ?? "—") + (info["fallthroughOverridden"]?.bool == true ? " (" + tr("forzado") + ")" : "")),
                          (tr("Huecos de retardo"), info["delaySlots"]?.text ?? ""), (tr("Prototipo"), info["prototype"]?.text ?? "")])
                    section(tr("Operandos"), (info["operands"]?.array ?? []).map { o in
                        "\(o.object["index"]?.text ?? ""): \(o.object["text"]?.text ?? "")   [\(o.object["type"]?.text ?? "")]   \(o.object["objects"]?.text ?? "")"
                    })
                    section(tr("Entradas"), [(info["inputs"]?.text ?? "")])
                    section(tr("Resultados"), [(info["results"]?.text ?? "")])
                    section("P-code", (info["pcode"]?.array ?? []).map(\.text))
                }
                section(tr("Vista desensamblada (sin cambiar el programa)"),
                        pseudo.map { "\($0["address"]?.text ?? "")  \(($0["bytes"]?.text ?? "").padding(toLength: 24, withPad: " ", startingAt: 0)) \($0["text"]?.text ?? "")" })
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(address)|\(model.editCount)") {
            info = (try? await model.engine.call("instructionInfo", ["address": address])) ?? [:]
            pseudo = (try? await model.engine.call("pseudoDisassemble", ["address": address, "count": 24])) ?? []
        }
    }

    private func grid(_ items: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary)
                    Text(item.1).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(lines.isEmpty ? "—" : lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }
}

// MARK: - Data settings

struct DataSettingsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSONRow = [:]
    @State private var asDefault = false
    @State private var error: String?

    var body: some View {
        let address = model.editTarget ?? ""
        VStack(spacing: 0) {
            if info.isEmpty {
                ContentUnavailableView(tr("Sin dato"), systemImage: "tablecells",
                                       description: Text(error ?? tr("Coloca el cursor sobre un dato definido.")))
            } else {
                Form {
                    Section("\(info["address"]?.text ?? "")  \(info["type"]?.text ?? "")") {
                        LabeledContent(tr("Valor")) { Text(info["value"]?.text ?? "").font(.callout.monospaced()).textSelection(.enabled) }
                        Toggle(tr("Aplicar a todos los datos de este tipo (ajuste por defecto)"), isOn: $asDefault)
                    }
                    Section(tr("Ajustes")) {
                        ForEach(Array((info["settings"]?.array ?? []).enumerated()), id: \.offset) { _, item in
                            setting(item.object, address)
                        }
                    }
                    Section {
                        HStack {
                            Button(tr("Ciclar byte → word → dword → qword")) { model.cycleData("byte") }
                            Button(tr("Ciclar float → double")) { model.cycleData("float") }
                            Button(tr("Ciclar char → cadena → unicode")) { model.cycleData("string") }
                        }
                        Button(tr("Parchear dato…")) { model.requestPatchData() }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task(id: "\(address)|\(model.editCount)|\(model.undo?.undoName ?? "")") {
            do { info = try await model.engine.call("dataSettings", ["address": address]); error = nil }
            catch { info = [:]; self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func setting(_ s: JSONRow, _ address: String) -> some View {
        let name = s["name"]?.text ?? ""
        let value = s["value"]?.text ?? ""
        let choices = (s["choices"]?.array ?? []).map(\.text)
        if s["type"]?.text == "boolean" {
            Toggle(name, isOn: Binding(get: { value == "true" }, set: { set(address, name, $0 ? "true" : "false") }))
        } else if !choices.isEmpty {
            Picker(name, selection: Binding(get: { value }, set: { set(address, name, $0) })) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
                if !choices.contains(value) { Text(value).tag(value) }
            }
        } else {
            LabeledContent(name) {
                Text(value).font(.callout.monospaced())
                Button(tr("Cambiar…")) {
                    model.formRequest = FormRequest(title: name, fields: [FormField(key: "v", title: tr("Valor"), value: value)],
                                                    origin: "tools") { values in
                        try await model.edit("setDataSetting", ["address": address, "name": name, "value": values["v"] ?? "",
                                                                "default": asDefault], namesChanged: false)
                    }
                }
            }
        }
    }

    private func set(_ address: String, _ name: String, _ value: String) {
        model.run("setDataSetting", ["address": address, "name": name, "value": value, "default": asDefault], namesChanged: false)
    }
}

// MARK: - Program options and properties

struct ProgramOptionsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var lists: [String] = []
    @State private var list = ""
    @State private var showProperties = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Opciones y propiedades del programa")) {
                Picker("", selection: $list) {
                    ForEach(lists, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 220)
                Toggle(tr("Mapas de propiedades"), isOn: $showProperties).toggleStyle(.checkbox)
                Button(tr("Cambiar lenguaje…")) { model.requestSetLanguage() }
            }
            if showProperties {
                EngineTable(method: "properties",
                            columns: [ColumnSpec(key: "name", title: tr("Propiedad"), width: 240),
                                      ColumnSpec(key: "count", title: tr("Valores"), width: 90), .address(tr("Primera"))])
            } else if !list.isEmpty {
                EngineTable(method: "programOptions", params: ["list": list],
                            columns: [ColumnSpec(key: "name", title: tr("Opción"), width: 300),
                                      ColumnSpec(key: "value", title: tr("Valor"), width: 320, mono: true),
                                      ColumnSpec(key: "description", title: tr("Descripción"), width: 400)],
                            addressKey: nil,
                            actions: [RowAction(title: tr("Cambiar…")) { row in change(row) }],
                            onOpen: { row in change(row) },
                            reloadKey: list)
            } else {
                Spacer()
            }
        }
        .task(id: model.activeSession) {
            lists = (try? await model.engine.call("optionLists")) ?? []
            if !lists.contains(list) { list = lists.first { $0 == "Program Information" } ?? lists.first ?? "" }
        }
    }

    private func change(_ row: JSONRow) {
        let name = row["name"]?.text ?? ""
        guard row["type"]?.text != "readonly" else {
            model.errorMessage = tr("Esa opción es solo informativa.")
            return
        }
        let field = row["type"]?.text == "boolean"
            ? FormField(key: "v", title: name, kind: .toggle, value: row["value"]?.text ?? "false")
            : FormField(key: "v", title: tr("Valor"), value: row["value"]?.text ?? "")
        model.formRequest = FormRequest(title: name, message: row["description"]?.text, fields: [field], origin: "tools") { values in
            try await model.edit("setProgramOption", ["list": list, "name": name, "value": values["v"] ?? ""], namesChanged: false)
        }
    }
}

// MARK: - Program tree editor

struct ProgramTreePanel: View {
    @Environment(AppModel.self) private var model
    @State private var tree = ""
    @State private var selected: String?
    @State private var busy = false

    private func flatten(_ groups: [TreeGroup], depth: Int, parent: String) -> [(TreeGroup, Int, String)] {
        groups.flatMap { [($0, depth, parent)] + flatten($0.children, depth: depth + 1, parent: $0.name) }
    }

    var body: some View {
        let trees = model.programTree
        let root = trees.first { $0.name == tree } ?? trees.first
        let rows = root.map { flatten($0.children, depth: 0, parent: $0.name) } ?? []
        let current = rows.first { $0.0.name == selected }
        VStack(spacing: 0) {
            PanelHeader(tr("Árbol del programa")) {
                Picker("", selection: $tree) {
                    ForEach(trees) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().frame(width: 180)
                Button(tr("Árbol nuevo…")) { ask(tr("Árbol nuevo"), tr("Nombre")) { ["action": "createTree", "newName": $0] } }
                Button(tr("Renombrar árbol…")) { ask(tr("Renombrar árbol"), tr("Nombre")) { ["action": "renameTree", "tree": tree, "newName": $0] } }
                Button(tr("Borrar árbol")) { act(["action": "deleteTree", "tree": tree]) }.disabled(trees.count < 2)
                if busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 6) {
                let folder = current.map { $0.0.module ? $0.0.name : $0.2 } ?? root?.name ?? ""
                Button(tr("Carpeta nueva…")) { ask(tr("Carpeta nueva en «%@»", folder), tr("Nombre")) { ["action": "createFolder", "tree": tree, "parent": folder, "newName": $0] } }
                Button(tr("Fragmento nuevo…")) { ask(tr("Fragmento nuevo en «%@»", folder), tr("Nombre")) { ["action": "createFragment", "tree": tree, "parent": folder, "newName": $0] } }
                Button(tr("Renombrar…")) {
                    if let c = current { ask(tr("Renombrar «%@»", c.0.name), tr("Nombre")) { ["action": "rename", "tree": tree, "name": c.0.name, "newName": $0] } }
                }
                .disabled(current == nil)
                Button(tr("Borrar")) { if let c = current { act(["action": "delete", "tree": tree, "name": c.0.name, "parent": c.2]) } }
                    .disabled(current == nil)
                Button(tr("Mover aquí la selección")) { moveSelection(current?.0) }
                    .disabled(current == nil || current?.0.module == true)
                    .help(tr("Mueve el código seleccionado en el programa (o la función actual) a este fragmento"))
                Spacer()
                Menu(tr("Organizar")) {
                    Button(tr("Por subrutinas")) { act(["action": "organize", "tree": tree, "newName": "subroutine"]) }
                    Button(tr("Por dominancia")) { act(["action": "organize", "tree": tree, "newName": "dominance"]) }
                    Button(tr("Por profundidad de complejidad")) { act(["action": "organize", "tree": tree, "newName": "complexity"]) }
                }
                .fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            List(rows, id: \.0.name, selection: $selected) { group, depth, _ in
                HStack(spacing: 6) {
                    Image(systemName: group.module ? "folder" : "doc.text")
                        .foregroundStyle(group.module ? Color.accentColor : Color.secondary)
                    Text(group.name).lineLimit(1)
                    Spacer()
                    if let start = group.start, let end = group.end {
                        Text("\(start) – \(end)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(depth) * 14)
                .contextMenu {
                    if let start = group.start { Button(tr("Ir a %@", start)) { model.go(start) } }
                    if let start = group.start, let end = group.end {
                        Button(tr("Seleccionar sus direcciones")) { model.selectLines(start: start, end: end) }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear { if tree.isEmpty { tree = trees.first?.name ?? "" } }
        .onChange(of: trees.map(\.name)) { _, names in if !names.contains(tree) { tree = names.first ?? "" } }
    }

    private func act(_ params: [String: Any]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.engine.call("treeAction", params, as: JSONValue.self)
                model.programTree = (try? await model.engine.call("programTree")) ?? model.programTree
                await model.refreshUndo()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func ask(_ title: String, _ label: String, _ params: @escaping (String) -> [String: Any]) {
        model.formRequest = FormRequest(title: title, fields: [FormField(key: "v", title: label, mono: false)], origin: "tools") { values in
            _ = try await model.engine.call("treeAction", params(values["v"] ?? ""), as: JSONValue.self)
            model.programTree = (try? await model.engine.call("programTree")) ?? model.programTree
            await model.refreshUndo()
        }
    }

    private func moveSelection(_ group: TreeGroup?) {
        guard let group else { return }
        var ranges = model.programSelection?.ranges ?? []
        if ranges.isEmpty, let fn = model.functionDetails {
            ranges = [[fn.entry, fn.entry]]
            if let a = model.editTarget { ranges = [[a, a]] }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                for pair in ranges where pair.count == 2 {
                    _ = try await model.engine.call("treeAction", ["action": "moveRange", "tree": tree, "name": group.name,
                                                                  "start": pair[0], "end": pair[1]], as: JSONValue.self)
                }
                model.programTree = (try? await model.engine.call("programTree")) ?? model.programTree
                await model.refreshUndo()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Bookmarks window

struct BookmarksPanel: View {
    @Environment(AppModel.self) private var model
    @State private var type = ""

    var body: some View {
        let all = model.bookmarks.filter { !$0.isBreakpoint }
        let types = Array(Set(all.map(\.type))).sorted()
        let rows: [JSONRow] = all.filter { type.isEmpty || $0.type == type }.map {
            ["address": .string($0.address), "type": .string($0.type), "category": .string($0.category), "comment": .string($0.comment)]
        }
        VStack(spacing: 0) {
            PanelHeader(tr("Marcadores")) {
                Picker(tr("Tipo"), selection: $type) {
                    Text(tr("Todos")).tag("")
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 200)
                Button(tr("Añadir en el cursor…")) { model.requestBookmark() }
            }
            GenericTable(rows: rows,
                         columns: [.address(), ColumnSpec(key: "type", title: tr("Tipo"), width: 90),
                                   ColumnSpec(key: "category", title: tr("Categoría"), width: 180),
                                   ColumnSpec(key: "comment", title: tr("Descripción"), width: 420)],
                         storageKey: "bookmarks",
                         actions: [
                            RowAction(title: tr("Editar…")) { row in
                                let address = row["address"]?.text ?? ""
                                model.formRequest = FormRequest(
                                    title: tr("Editar marcador"),
                                    fields: [FormField(key: "category", title: tr("Categoría"), value: row["category"]?.text ?? "", mono: false),
                                             FormField(key: "comment", title: tr("Descripción"), value: row["comment"]?.text ?? "", mono: false)],
                                    origin: "tools") { values in
                                        try await model.edit("addBookmark", ["address": address, "category": values["category"] ?? "",
                                                                             "comment": values["comment"] ?? ""], namesChanged: false)
                                    }
                            },
                            RowAction(title: tr("Quitar"), destructive: true) { row in
                                model.perform("deleteBookmark", address: row["address"]?.text ?? "", namesChanged: false)
                            },
                         ])
        }
    }
}

/// Title strip of a panel with its buttons on the right.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer()
            trailing()
        }
        .controlSize(.small)
        .padding(10)
    }
}
