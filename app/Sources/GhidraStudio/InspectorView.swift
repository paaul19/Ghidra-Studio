import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let d = model.functionDetails {
                Section(tr("Función")) {
                    LabeledContent(tr("Nombre")) {
                        Text(d.name).textSelection(.enabled).lineLimit(2)
                    }
                    LabeledContent(tr("Entrada")) {
                        Text(d.entry).monospaced().textSelection(.enabled)
                    }
                    LabeledContent(tr("Tamaño"), value: tr("%@ bytes", "\(d.size)"))
                    if let cc = d.callingConvention, !cc.isEmpty {
                        LabeledContent(tr("Convención"), value: cc)
                    }
                    LabeledContent(tr("Retorno")) { Text(d.returnType).monospaced() }
                    if d.localCount > 0 {
                        LabeledContent(tr("Variables locales"), value: "\(d.localCount)")
                    }
                    if let thunk = d.thunkTarget {
                        LabeledContent(tr("Thunk a"), value: thunk)
                    }
                }

                if !d.parameters.isEmpty {
                    Section(tr("Parámetros")) {
                        ForEach(d.parameters, id: \.self) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(p.name).monospaced()
                                    Spacer()
                                    Text(p.type).monospaced().foregroundStyle(.secondary)
                                }
                                Text(p.storage).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if let comment = d.comment, !comment.isEmpty {
                    Section(tr("Comentario")) { Text(comment).textSelection(.enabled) }
                }

                refSection(tr("Llamada desde"), d.callers)
                refSection(tr("Llama a"), d.callees)
                xrefSection(d.xrefs)
            } else if let location = model.current {
                Section(tr("Ubicación")) {
                    LabeledContent(tr("Dirección")) {
                        Text(location.address).monospaced().textSelection(.enabled)
                    }
                }
                xrefSection(model.locationXrefs)
            }

            if !model.lineRefs.isEmpty, let line = model.selectedAddress {
                Section(tr("Referencias desde %@ · %@", "\(line)", "\(model.lineRefs.count)")) {
                    ForEach(model.lineRefs) { r in
                        NavRow(icon: "arrow.turn.down.right", tint: .teal, title: r.function ?? r.to,
                               detail: "\(r.to) · \(r.type.lowercased()) · op \(r.operand)") {
                            model.go(r.to)
                        }
                        .contextMenu {
                            Button(tr("Quitar referencia"), role: .destructive) { model.deleteReference(from: line, to: r.to) }
                        }
                    }
                }
            }

            if let p = model.program {
                Section(tr("Programa")) {
                    LabeledContent(tr("Formato"), value: p.format)
                    LabeledContent(tr("Procesador"), value: "\(p.processor) · \(p.pointerSize) bits · \(p.endian)")
                    LabeledContent(tr("Lenguaje")) { Text(p.language).monospaced().lineLimit(1).truncationMode(.middle) }
                    LabeledContent(tr("Compilador"), value: p.compiler)
                    LabeledContent("Base") { Text(p.imageBase).monospaced() }
                    LabeledContent(tr("Funciones"), value: "\(p.functionCount)")
                    if let md5 = p.md5 {
                        LabeledContent("MD5") {
                            Text(md5).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let sha = p.sha256 {
                        LabeledContent("SHA-256") {
                            Text(sha).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func refSection(_ title: String, _ refs: [FnRef]) -> some View {
        if !refs.isEmpty {
            Section("\(title) · \(refs.count)") {
                ForEach(refs.prefix(200)) { r in
                    NavRow(icon: r.external ? "shippingbox" : "f.cursive",
                           tint: r.external ? .orange : .purple,
                           title: r.name, detail: r.address) {
                        model.go(r.address)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func xrefSection(_ refs: [XRef]) -> some View {
        Section(tr("Referencias · %@", "\(refs.count)")) {
            if refs.isEmpty {
                Text(tr("Sin referencias entrantes")).foregroundStyle(.secondary)
            }
            ForEach(refs.prefix(300)) { x in
                NavRow(icon: x.type.contains("CALL") ? "phone.arrow.up.right"
                           : x.type.contains("READ") ? "eye"
                           : x.type.contains("WRITE") ? "square.and.pencil" : "arrow.turn.up.right",
                       tint: .blue,
                       title: x.function ?? x.from,
                       detail: "\(x.from) · \(x.type.lowercased())") {
                    model.go(x.from)
                }
            }
        }
    }
}

struct NavRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
