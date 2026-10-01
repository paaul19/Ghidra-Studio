import SwiftUI

// MARK: - Project tree (sidebar & welcome)

struct ProjectTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            if let project = model.project, project.open {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name ?? tr("Proyecto")).font(.headline).lineLimit(1)
                        Text(project.isDefault == true ? tr("Proyecto por defecto") : (project.directory ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Menu {
                        Button(tr("Nuevo proyecto…")) { model.presentNewProject() }
                        Button(tr("Abrir proyecto…")) { model.presentOpenProject() }
                        if project.isDefault != true {
                            Button(tr("Volver al proyecto por defecto")) { model.openDefaultProject() }
                        }
                        Divider()
                        Button(tr("Mostrar en Finder")) {
                            if let dir = project.directory {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                            }
                        }
                        Button(tr("Abrir en Ghidra clásico")) { model.openProjectInClassic() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                List(selection: $selection) {
                    if let tree = project.tree {
                        FolderContents(folder: tree)
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.isEmpty {
                        Button(tr("Nueva carpeta…")) { model.requestNewFolder(parent: "/") }
                        Button(tr("Importar binario…")) { model.presentOpenPanel() }
                    }
                } primaryAction: { ids in
                    guard let id = ids.first, id.hasPrefix("f:") else { return }
                    model.openProgram(domainPath: String(id.dropFirst(2)))
                }

                Divider()
                HStack(spacing: 14) {
                    Button { model.presentOpenPanel() } label: { Image(systemName: "plus") }
                        .help(tr("Importar binario (⌘I)"))
                    Button { model.requestNewFolder(parent: selectedFolder ?? "/") } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help(tr("Nueva carpeta"))
                    Button { model.presentImportPacked() } label: { Image(systemName: "shippingbox.and.arrow.backward") }
                        .help(tr("Importar archivo .gzf"))
                    Spacer()
                    Button { Task { await model.refreshProject() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("Actualizar"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ContentUnavailableView(tr("Sin proyecto"), systemImage: "shippingbox",
                                       description: Text(tr("Crea o abre un proyecto de Ghidra.")))
            }
        }
    }

    private var selectedFolder: String? {
        guard let selection, selection.hasPrefix("d:") else { return nil }
        return String(selection.dropFirst(2))
    }
}

private struct FolderContents: View {
    @Environment(AppModel.self) private var model
    let folder: ProjectFolder

    var body: some View {
        ForEach(folder.folders) { sub in
            DisclosureGroup {
                FolderContents(folder: sub)
            } label: {
                Label(sub.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button(tr("Nueva carpeta…")) { model.requestNewFolder(parent: sub.path) }
                        Button(tr("Renombrar…")) { model.requestRenameItem(path: sub.path, name: sub.name, folder: true) }
                        Divider()
                        Button(tr("Borrar carpeta"), role: .destructive) {
                            model.deleteProjectItem(path: sub.path, name: sub.name, folder: true)
                        }
                    }
            }
            .tag(sub.id)
        }
        ForEach(folder.files) { file in
            ProjectFileRow(file: file)
                .tag(file.id)
        }
        if folder.folders.isEmpty && folder.files.isEmpty && folder.path == "/" {
            Text(tr("El proyecto está vacío. Pulsa + para importar un binario."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProjectFileRow: View {
    @Environment(AppModel.self) private var model
    let file: ProjectFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.program ? "cpu" : "doc")
                .foregroundStyle(file.open ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if file.open {
                        Text(tr("abierto")).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
                Text([file.format, file.processor].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button(tr("Abrir")) { model.openProgram(domainPath: file.path) }
            Button(tr("Renombrar…")) { model.requestRenameItem(path: file.path, name: file.name, folder: false) }
            Menu(tr("Mover a")) {
                ForEach(model.projectFolders, id: \.path) { folder in
                    Button(folder.path) { model.projectAction("moveItem", ["path": file.path, "folder": folder.path]) }
                }
            }
            Divider()
            Button(tr("Borrar"), role: .destructive) {
                model.deleteProjectItem(path: file.path, name: file.name, folder: false)
            }
        }
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ImportRequest

    @State private var specs: [LoadSpecItem] = []
    @State private var selectedSpec: String?
    @State private var folder = "/"
    @State private var analyze = true
    @State private var loading = true
    @State private var useCustomLanguage = false
    @State private var languages: [LanguageItem] = []
    @State private var languageQuery = ""
    @State private var customLanguage: String?
    @State private var customCompiler: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: request.url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Importar %@", "\(request.url.lastPathComponent)")).font(.title3.weight(.semibold))
                    Text(request.url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }

            Form {
                Picker(tr("Carpeta"), selection: $folder) {
                    ForEach(model.projectFolders, id: \.path) { f in
                        Text(f.path).tag(f.path)
                    }
                }
                if loading {
                    LabeledContent(tr("Formato")) { ProgressView().controlSize(.small) }
                } else if specs.isEmpty {
                    LabeledContent(tr("Formato"), value: tr("No reconocido: elige un lenguaje"))
                } else {
                    Picker(tr("Formato y lenguaje"), selection: $selectedSpec) {
                        ForEach(specs) { spec in
                            Text(spec.title + (spec.preferred ? "  ★" : "")).tag(Optional(spec.id))
                        }
                    }
                    .disabled(useCustomLanguage)
                }
                Toggle(tr("Elegir otro procesador / lenguaje"), isOn: $useCustomLanguage)
                if useCustomLanguage {
                    TextField(tr("Buscar (p. ej. ARM, x86, MIPS, 8051)"), text: $languageQuery)
                    List(filteredLanguages, selection: $customLanguage) { lang in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lang.id).font(.callout.monospaced())
                            Text(lang.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(lang.id)
                    }
                    .frame(height: 160)
                    if let lang = languages.first(where: { $0.id == customLanguage }), lang.compilers.count > 1 {
                        Picker(tr("Compilador"), selection: $customCompiler) {
                            ForEach(lang.compilers, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                }
                Toggle(tr("Analizar automáticamente"), isOn: $analyze)
            }
            .formStyle(.grouped)
            .frame(minHeight: useCustomLanguage ? 420 : 220)

            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Importar")) {
                    let spec = useCustomLanguage ? nil : specs.first { $0.id == selectedSpec }
                    model.importFile(request.url, folder: folder, spec: spec,
                                     language: useCustomLanguage ? customLanguage : nil,
                                     compiler: useCustomLanguage ? customCompiler : nil, analyze: analyze)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(loading || (useCustomLanguage && customLanguage == nil) || (!useCustomLanguage && specs.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            specs = (try? await model.engine.call("loadSpecs", ["path": request.url.path])) ?? []
            selectedSpec = (specs.first { $0.preferred } ?? specs.first)?.id
            if specs.isEmpty { useCustomLanguage = true }
            loading = false
        }
        .onChange(of: useCustomLanguage) { _, on in
            if on && languages.isEmpty {
                Task { languages = (try? await model.engine.call("languages")) ?? [] }
            }
        }
        .onChange(of: customLanguage) { _, id in
            customCompiler = languages.first { $0.id == id }?.compilers.first
        }
    }

    private var filteredLanguages: [LanguageItem] {
        guard !languageQuery.isEmpty else { return languages }
        return languages.filter {
            $0.id.localizedCaseInsensitiveContains(languageQuery)
                || $0.description.localizedCaseInsensitiveContains(languageQuery)
        }
    }
}
