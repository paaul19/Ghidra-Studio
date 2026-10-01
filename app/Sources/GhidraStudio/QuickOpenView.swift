import SwiftUI

struct QuickOpenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @State private var remoteHits: [SearchHit] = []
    @FocusState private var focused: Bool

    private struct Result: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let address: String
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Result] = []
        if !q.isEmpty, let _ = addressValue(q.lowercased().hasPrefix("0x") ? String(q.dropFirst(2)) : q) {
            out.append(Result(id: "addr:\(q)", icon: "number", tint: .gray, title: tr("Ir a la dirección %@", "\(q)"),
                              detail: tr("Dirección"), address: q))
        }
        let fns = q.isEmpty ? Array(model.functions.prefix(60))
            : model.functions.filter { $0.name.localizedCaseInsensitiveContains(q) }
                .sorted { rank($0.name, q) < rank($1.name, q) }
                .prefix(60).map { $0 }
        out += fns.map { Result(id: "f:\($0.address)", icon: $0.thunk ? "arrow.turn.down.right" : "f.cursive",
                                tint: .purple, title: $0.name, detail: $0.address, address: $0.address) }
        let known = Set(out.map(\.address))
        out += remoteHits.filter { !known.contains($0.address) }.prefix(40).map {
            Result(id: "s:\($0.id)", icon: "tag", tint: .blue, title: $0.name,
                   detail: "\($0.kind.lowercased()) · \($0.address)", address: $0.address)
        }
        if q.count >= 3 {
            out += model.strings.filter { $0.value.localizedCaseInsensitiveContains(q) }.prefix(25).map {
                Result(id: "str:\($0.address)", icon: "textformat.abc", tint: .green, title: "\"\($0.value)\"",
                       detail: $0.address, address: $0.address)
            }
        }
        return out
    }

    private func rank(_ name: String, _ q: String) -> Int {
        let n = name.lowercased(), l = q.lowercased()
        if n == l { return 0 }
        if n.hasPrefix(l) || n.hasPrefix("_" + l) { return 1 }
        return 2 + name.count
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField(tr("Buscar función, símbolo, cadena o dirección"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { choose(items) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .foregroundStyle(index == selection ? Color.white : item.tint)
                                .frame(width: 18)
                            Text(item.title).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(index == selection ? Color.white.opacity(0.85) : Color.secondary)
                        }
                        .foregroundStyle(index == selection ? Color.white : Color.primary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(index == selection ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = index; choose(items) }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: selection) { _, value in proxy.scrollTo(value) }
            }
            if items.isEmpty {
                Text(tr("Sin resultados"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 440)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { remoteHits = []; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            remoteHits = await model.search(q)
        }
        .onExitCommand { dismiss() }
    }

    private func choose(_ items: [Result]) {
        guard items.indices.contains(selection) else { return }
        let address = items[selection].address
        dismiss()
        model.go(address)
    }
}

struct EditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: EditRequest
    @State private var text = ""
    @State private var commentKind = "eol"

    private var isComment: Bool { request.kind == .comment }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title)
                .font(.title3.weight(.semibold))
            Text(request.address.hasPrefix("/") ? request.address : tr("Dirección %@", "\(request.address)"))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if isComment {
                Picker(tr("Tipo"), selection: $commentKind) {
                    Text(tr("Fin de línea")).tag("eol")
                    Text(tr("Previo")).tag("pre")
                    Text(tr("Cabecera")).tag("plate")
                    Text(tr("Posterior")).tag("post")
                    Text(tr("Repetible")).tag("repeatable")
                }
                .pickerStyle(.segmented)
            }
            Text(request.prompt).font(.callout).foregroundStyle(.secondary)
            if request.multiline {
                TextEditor(text: $text)
                    .font(request.monospaced ? .body.monospaced() : .body)
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(request.monospaced ? .body.monospaced() : .body)
                    .onSubmit(save)
            }
            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Aceptar"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            text = request.initialText
            commentKind = request.commentKind
        }
    }

    private func save() {
        model.commit(request, text: text, commentKind: commentKind)
        dismiss()
    }
}
