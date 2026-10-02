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
                        Divider()
                        Button(tr("Restaurar un proyecto archivado…")) { model.restoreProject() }
                        Button(tr("Tabla, otros proyectos, check-outs, bibliotecas…")) { model.windowRequest = "projecttools" }
                        if model.projectClipboard != nil {
                            Button(tr("Pegar en la raíz")) { model.pasteProjectItem(into: "/") }
                        }
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
                        Button(tr("Copiar")) { model.projectClipboard = ProjectClip(path: sub.path, folder: true) }
                        if model.projectClipboard != nil {
                            Button(tr("Pegar aquí")) { model.pasteProjectItem(into: sub.path) }
                        }
                        Button(tr("Crear un enlace en la raíz")) { model.linkProjectItem(path: sub.path, folder: true, into: "/") }
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
                    if file.versioned == true {
                        Label("v\(file.version ?? 0)", systemImage: file.checkedOut == true ? "checkmark.circle" : "lock")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(file.checkedOut == true ? Color.green : Color.secondary)
                            .help(file.checkedOut == true ? tr("En control de versiones, con check-out")
                                                         : tr("En control de versiones: haz check-out para modificarlo"))
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
            Button(tr("Copiar")) { model.projectClipboard = ProjectClip(path: file.path, folder: false) }
            Menu(tr("Crear un enlace en")) {
                ForEach(model.projectFolders, id: \.path) { folder in
                    Button(folder.path) { model.linkProjectItem(path: file.path, folder: false, into: folder.path) }
                }
            }
            Button(tr("Solo lectura: poner")) { model.setReadOnly(path: file.path, true) }
            Button(tr("Solo lectura: quitar")) { model.setReadOnly(path: file.path, false) }
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
    @State private var showLoaderOptions = false
    @State private var loaderOptions: [LoaderOption] = []
    @State private var defaults: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: request.isLocalFile ? NSWorkspace.shared.icon(forFile: request.source)
                                                   : NSWorkspace.shared.icon(for: .data))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Importar %@", "\(request.name)")).font(.title3.weight(.semibold))
                    Text(request.isLocalFile ? (request.source as NSString).deletingLastPathComponent
                                             : tr("Dentro de un contenedor"))
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
                    .frame(height: 140)
                    if let lang = languages.first(where: { $0.id == customLanguage }), lang.compilers.count > 1 {
                        Picker(tr("Compilador"), selection: $customCompiler) {
                            ForEach(lang.compilers, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                }
                Toggle(tr("Analizar automáticamente"), isOn: $analyze)
                if !loaderOptions.isEmpty {
                    Toggle(tr("Opciones del cargador"), isOn: $showLoaderOptions)
                    if showLoaderOptions {
                        ForEach($loaderOptions) { $opt in
                            if opt.type == "bool" {
                                Toggle(opt.name, isOn: Binding(get: { opt.value == "true" },
                                                               set: { opt.value = $0 ? "true" : "false" }))
                                    .toggleStyle(.checkbox)
                            } else {
                                TextField(opt.name, text: $opt.value)
                                    .font(.body.monospaced())
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: useCustomLanguage || showLoaderOptions ? 460 : 250)

            HStack {
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Importar")) {
                    let spec = useCustomLanguage ? nil : specs.first { $0.id == selectedSpec }
                    var args: [String: String] = [:]
                    for o in loaderOptions where defaults[o.arg] != o.value { args[o.arg] = o.value }
                    model.importFile(request, folder: folder, spec: spec,
                                     language: useCustomLanguage ? customLanguage : nil,
                                     compiler: useCustomLanguage ? customCompiler : nil, analyze: analyze,
                                     loaderArgs: args)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(loading || (useCustomLanguage && customLanguage == nil) || (!useCustomLanguage && specs.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 580)
        .task {
            specs = (try? await model.engine.call("loadSpecs", ["path": request.source])) ?? []
            selectedSpec = (specs.first { $0.preferred } ?? specs.first)?.id
            if specs.isEmpty { useCustomLanguage = true }
            loading = false
        }
        .task(id: selectedSpec) {
            guard let spec = specs.first(where: { $0.id == selectedSpec }) else { return }
            loaderOptions = (try? await model.engine.call("loaderOptions", ["path": request.source, "loader": spec.loader])) ?? []
            defaults = Dictionary(uniqueKeysWithValues: loaderOptions.map { ($0.arg, $0.value) })
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

// MARK: - Container browser (zip, firmware, disk images, dyld cache…)

struct ContainerBrowserSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ContainerRequest
    @State private var root: FSListing?
    @State private var inspected: FSEntry?
    @State private var selection: FSEntry.ID?
    @State private var entriesByID: [String: FSEntry] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.url.lastPathComponent).font(.title3.weight(.semibold))
                    Text(root?.type ?? tr("Abriendo contenedor…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            List(selection: $selection) {
                if let root {
                    ForEach(root.entries) { entry in
                        FSEntryRow(entry: entry, register: { entriesByID[$0.id] = $0 }, selection: $selection) { picked in
                            dismiss()
                            model.importRequest = ImportRequest(entry: picked)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(height: 360)
            HStack {
                Button(tr("Importar el archivo entero")) {
                    model.importRequest = ImportRequest(url: request.url)
                    dismiss()
                }
                Button(tr("Información, vista previa y extraer…")) {
                    if let id = selection { inspected = entriesByID[id] }
                }
                .disabled(selection == nil)
                ContainerActionsMenu(container: request.url.path, containerName: request.url.lastPathComponent,
                                     entry: selection.flatMap { entriesByID[$0] })
                Button(tr("Por lotes…")) {
                    dismiss()
                    model.batchRequest = BatchRequest(urls: [request.url])
                }
                .help(tr("Importar todos los programas del contenedor con el importador por lotes"))
                Spacer()
                Button(tr("Cancelar"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Importar selección")) {
                    if let id = selection, let entry = entriesByID[id] {
                        dismiss()
                        model.importRequest = ImportRequest(entry: entry)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selection.flatMap { entriesByID[$0] }.map(\.directory) ?? true)
            }
        }
        .padding(22)
        .frame(width: 760)
        .sheet(item: $inspected) { entry in FSFileSheet(entry: entry) }
        .task {
            root = try? await model.engine.call("fsList", ["path": request.url.path])
            for e in root?.entries ?? [] { entriesByID[e.id] = e }
        }
    }
}

private struct FSEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: FSEntry
    let register: (FSEntry) -> Void
    @Binding var selection: FSEntry.ID?
    let open: (FSEntry) -> Void
    @State private var expanded = false
    @State private var children: [FSEntry]?

    var body: some View {
        if entry.directory {
            DisclosureGroup(isExpanded: $expanded) {
                if let children {
                    ForEach(children) { FSEntryRow(entry: $0, register: register, selection: $selection, open: open) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Label(entry.name, systemImage: "folder.fill")
            }
            .tag(entry.id)
            .onChange(of: expanded) { _, isOpen in
                guard isOpen, children == nil else { return }
                Task {
                    let listing: FSListing? = try? await model.engine.call("fsList", ["path": entry.fsrl])
                    children = listing?.entries ?? []
                    children?.forEach(register)
                }
            }
        } else {
            HStack {
                Label(entry.name, systemImage: "doc")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Button(tr("Importar")) { open(entry) }
                    .controlSize(.small)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(entry) }
            .onTapGesture { selection = entry.id }
            .tag(entry.id)
        }
    }
}
