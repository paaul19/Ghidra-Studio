import AppKit
import SwiftUI

// MARK: - Ghidra Server & version control

struct ServerView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    Text(tr("Control de versiones")).tag(0)
                    Text(tr("Servidor")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                TaskProgressBar(task: "vc")
            }
            .padding(10)
            Divider()
            if mode == 0 { VersionControlPanel() } else { ServerPanel() }
        }
        .windowMinSize(860, 560)
    }
}

/// Connect to a Ghidra Server, manage repositories and create shared projects.
private struct ServerPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("serverHost") private var host = ""
    @AppStorage("serverPort") private var port = 13100
    @AppStorage("serverUser") private var user = ""
    @State private var password = ""
    @AppStorage("serverKeyFile") private var keyFile = ""
    @State private var connection: ServerConnection?
    @State private var repository: String?
    @State private var users: [RepositoryUser] = []
    @State private var newRepository = ""
    @State private var grantUser = ""
    @State private var grantAccess = "write"
    @State private var newPassword = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.project?.server, status.shared {
                sharedBanner(status)
                Divider()
            }
            Form {
                Section(tr("Conexión")) {
                    TextField(tr("Servidor"), text: $host, prompt: Text("ghidra.ejemplo.org"))
                    TextField(tr("Puerto"), value: $port, format: .number.grouping(.never))
                    TextField(tr("Usuario"), text: $user,
                              prompt: Text(connection?.systemUser ?? NSUserName()))
                        .help(tr("Vacío = tu usuario del sistema. Solo se usa otro nombre si el servidor lo permite (opción -u)."))
                    SecureField(tr("Contraseña"), text: $password)
                    HStack {
                        Text(keyFile.isEmpty ? tr("Sin certificado ni clave") : (keyFile as NSString).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(tr("Certificado PKI o clave SSH…")) {
                            let panel = NSOpenPanel()
                            panel.message = tr("Un almacén .p12/.pfx/.jks (PKI) o una clave privada SSH. La contraseña de arriba lo desbloquea.")
                            panel.showsHiddenFiles = true
                            if panel.runModal() == .OK, let url = panel.url { keyFile = url.path; applyKeyFile() }
                        }
                        if !keyFile.isEmpty { Button(tr("Quitar")) { keyFile = ""; applyKeyFile() } }
                    }
                    .controlSize(.small)
                    HStack {
                        Button(connection == nil ? tr("Conectar") : tr("Volver a conectar")) { connect() }
                            .buttonStyle(.glassProminent)
                            .disabled(host.isEmpty || busy)
                        if busy { ProgressView().controlSize(.small) }
                        if let c = connection {
                            Label(tr("Conectado como %@%@", c.user ?? "—", c.readOnly ? tr(" (solo lectura)") : ""),
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        }
                    }
                }
                if let c = connection {
                    Section(tr("Repositorios")) {
                        if c.repositories.isEmpty {
                            Text(tr("El servidor no tiene repositorios todavía.")).foregroundStyle(.secondary)
                        }
                        ForEach(c.repositories, id: \.self) { name in
                            HStack {
                                Image(systemName: repository == name ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(repository == name ? Color.accentColor : Color.secondary)
                                Text(name)
                                Spacer()
                                Button(tr("Usuarios")) { select(name) }.controlSize(.small)
                                if model.project?.open == true, model.project?.server?.shared != true {
                                    Button(tr("Convertir el proyecto abierto")) { convertProject(name) }.controlSize(.small)
                                        .help(tr("Convierte el proyecto local abierto en uno compartido de este repositorio"))
                                }
                                Button(tr("Crear proyecto compartido…")) { createProject(name) }.controlSize(.small)
                            }
                        }
                        HStack {
                            TextField(tr("Nuevo repositorio"), text: $newRepository)
                            Button(tr("Crear")) { createRepository() }
                                .disabled(newRepository.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                    }
                    if let repository {
                        Section(tr("Usuarios de «%@»", repository)) {
                            ForEach(users) { u in
                                HStack {
                                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                                    Text(u.name)
                                    Spacer()
                                    Text(accessTitle(u.access)).foregroundStyle(.secondary)
                                    Button(tr("Quitar")) { setUser(u.name, "none") }.controlSize(.small)
                                }
                            }
                            HStack {
                                Picker(tr("Dar acceso a"), selection: $grantUser) {
                                    Text("—").tag("")
                                    ForEach(c.users.filter { name in !users.contains { $0.name == name } }, id: \.self) {
                                        Text($0).tag($0)
                                    }
                                }
                                Picker("", selection: $grantAccess) {
                                    Text(tr("Lectura")).tag("read")
                                    Text(tr("Escritura")).tag("write")
                                    Text(tr("Administrador")).tag("admin")
                                }
                                .labelsHidden().fixedSize()
                                Button(tr("Asignar")) { setUser(grantUser, grantAccess) }.disabled(grantUser.isEmpty)
                            }
                        }
                    }
                    Section(tr("Cambiar contraseña")) {
                        HStack {
                            SecureField(tr("Nueva contraseña"), text: $newPassword)
                            Button(tr("Cambiar")) { changePassword() }.disabled(newPassword.count < 6 || busy)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                StatusLine(text: message, isError: failed)
                Spacer()
            }
            .padding(10)
        }
    }

    private func sharedBanner(_ status: ServerStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Proyecto compartido: %@ en %@", status.repository ?? "", status.host ?? "")).font(.callout.weight(.medium))
                Text(status.connected == true
                     ? tr("Conectado como %@ (%@)", status.user ?? "", accessTitle(status.access ?? ""))
                     : tr("Sin conexión con el servidor: escribe la contraseña y pulsa Reconectar."))
                    .font(.caption).foregroundStyle(status.connected == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Spacer()
            if status.connected != true {
                Button(tr("Reconectar")) { reconnect() }.disabled(busy)
            }
        }
        .padding(12)
    }

    private func accessTitle(_ access: String) -> String {
        switch access {
        case "admin": tr("Administrador")
        case "write": tr("Escritura")
        case "read": tr("Lectura")
        default: access
        }
    }

    private func report(_ text: String?, error: Bool = false) {
        message = text
        failed = error
    }

    private var target: [String: Any] { ["host": host, "port": port] }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    private func applyKeyFile() {
        let path = keyFile
        Task { _ = try? await model.engine.call("serverKeyFile", ["path": path], as: JSONValue.self) }
    }

    private func connect() {
        run {
            _ = try? await model.engine.call("serverKeyFile", ["path": keyFile], as: JSONValue.self)
            var params = target
            params["user"] = user
            params["password"] = password
            connection = nil
            let c: ServerConnection = try await model.engine.call("serverConnect", params)
            connection = c
            repository = nil
            users = []
            report(tr("%@ repositorios · %@ usuarios en el servidor", "\(c.repositories.count)", "\(c.users.count)"))
        }
    }

    private func reconnect() {
        run {
            _ = try await model.engine.call("serverReconnect", ["user": user, "password": password], as: ServerStatus.self)
            await model.refreshProject()
            report(tr("Proyecto reconectado."))
        }
    }

    private func select(_ name: String) {
        run {
            var params = target
            params["name"] = name
            users = try await model.engine.call("serverRepositoryUsers", params)
            repository = name
        }
    }

    private func createRepository() {
        run {
            var params = target
            params["name"] = newRepository.trimmingCharacters(in: .whitespaces)
            let list: RepositoryList = try await model.engine.call("serverCreateRepository", params)
            if let c = connection {
                connection = ServerConnection(connected: true, host: c.host, port: c.port, user: c.user, readOnly: c.readOnly,
                                              repositories: list.repositories, users: c.users, systemUser: c.systemUser)
            }
            newRepository = ""
        }
    }

    private func setUser(_ name: String, _ access: String) {
        guard let repository else { return }
        run {
            var params = target
            params["name"] = repository
            params["user"] = name
            params["access"] = access
            users = try await model.engine.call("serverSetUser", params)
            grantUser = ""
        }
    }

    private func changePassword() {
        run {
            var params = target
            params["password"] = newPassword
            _ = try await model.engine.call("serverSetPassword", params, as: Bool.self)
            password = newPassword
            newPassword = ""
            report(tr("Contraseña cambiada."))
        }
    }

    private func convertProject(_ repository: String) {
        guard model.confirm(tr("¿Convertir «%@» en proyecto compartido?", model.project?.name ?? ""),
                            tr("El proyecto quedará ligado al repositorio «%@». Sus archivos siguen siendo privados hasta que los añadas al control de versiones. No se puede deshacer.", repository),
                            action: tr("Convertir")) else { return }
        run {
            guard await model.prepareToQuit() else { return }
            var params = target
            params["repository"] = repository
            let info: ProjectInfo = try await model.engine.call("serverConvert", params)
            model.adoptProject(info)
            report(tr("Proyecto convertido y reabierto."))
        }
    }

    private func createProject(_ repository: String) {
        let panel = NSSavePanel()
        panel.title = tr("Proyecto compartido")
        panel.message = tr("Elige dónde guardar tu copia de trabajo del repositorio «%@»", repository)
        panel.nameFieldStringValue = repository
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent().path
        run {
            guard await model.prepareToQuit() else { return }
            var params = target
            params["repository"] = repository
            params["directory"] = directory
            params["name"] = name
            let info: ProjectInfo = try await model.engine.call("serverCreateProject", params)
            model.adoptProject(info)
            report(tr("Proyecto «%@» creado y abierto.", name))
        }
    }
}

/// Version state of every file in the project and the check-in / check-out actions.
private struct VersionControlPanel: View {
    @Environment(AppModel.self) private var model
    @State private var files: [VCFile] = []
    @State private var selection: VCFile.ID?
    @State private var history: [VCVersion] = []
    @State private var checkouts: [VCCheckout] = []
    @State private var comment = ""
    @State private var keepCheckedOut = true
    @State private var exclusive = false
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private var selected: VCFile? { files.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if model.project?.open != true {
                ContentUnavailableView(tr("Ningún proyecto abierto"), systemImage: "shippingbox")
            } else {
                Table(files, selection: $selection) {
                    TableColumn(tr("Archivo")) { f in
                        HStack(spacing: 6) {
                            Image(systemName: icon(f.state)).foregroundStyle(tint(f.state)).frame(width: 16)
                            Text(f.path).lineLimit(1).truncationMode(.middle)
                            if f.open { Text(tr("abierto")).font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
                        }
                    }
                    TableColumn(tr("Estado")) { f in Text(title(f)).foregroundStyle(tint(f.state)) }
                        .width(min: 120, ideal: 150)
                    TableColumn(tr("Versión")) { f in
                        Text(f.versioned ? "\(f.version ?? 0) / \(f.latest ?? 0)" : "—").monospacedDigit()
                            .foregroundStyle((f.version ?? 0) < (f.latest ?? 0) ? Color.orange : Color.primary)
                    }
                    .width(70)
                    TableColumn(tr("Check-out de")) { f in Text(f.checkedOutBy ?? "").foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 120)
                }
                Divider()
                actions
                if !history.isEmpty {
                    Divider()
                    historyList
                }
                if !checkouts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Check-outs activos")).font(.caption.weight(.semibold))
                        ForEach(checkouts) { c in
                            HStack(spacing: 8) {
                                Image(systemName: c.exclusive ? "lock.fill" : "person.fill").foregroundStyle(.secondary)
                                Text(c.user).frame(width: 90, alignment: .leading)
                                Text("v\(c.version)").font(.callout.monospacedDigit())
                                Text(c.project ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(tr("Terminar")) { terminate(c) }.controlSize(.small)
                                    .help(tr("Solo administradores: anula el check-out de ese usuario"))
                            }
                        }
                    }
                    .padding(10)
                }
                Divider()
                HStack {
                    StatusLine(text: message ?? hint, isError: failed)
                    Spacer()
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("Actualizar"))
                }
                .padding(10)
            }
        }
        .task(id: model.project?.gpr) { await reload() }
        .onChange(of: selection) { _, _ in Task { await loadHistory() } }
    }

    private var hint: String {
        tr("Añade archivos al control de versiones para guardar un historial. En un proyecto compartido las versiones van al servidor.")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(tr("Comentario de la versión"), text: $comment).textFieldStyle(.roundedBorder)
                Toggle(tr("Mantener el check-out"), isOn: $keepCheckedOut).toggleStyle(.checkbox)
                Toggle(tr("Exclusivo"), isOn: $exclusive).toggleStyle(.checkbox)
                    .help(tr("Check-out exclusivo: nadie más puede modificarlo mientras lo tengas"))
            }
            HStack {
                Button(tr("Añadir al control de versiones")) {
                    act("vcAdd", ["comment": comment, "keepCheckedOut": keepCheckedOut])
                }
                .disabled(!(selected?.canAdd ?? false) || busy)
                Button("Check-out") { act("vcCheckout", ["exclusive": exclusive]) }
                    .disabled(!(selected?.canCheckout ?? false) || busy)
                Button("Check-in") { act("vcCheckin", ["comment": comment, "keepCheckedOut": keepCheckedOut]) }
                    .buttonStyle(.glassProminent)
                    .disabled(!(selected?.canCheckin ?? false) || busy)
                Button(tr("Deshacer check-out")) { act("vcUndoCheckout", [:]) }
                    .disabled(!(selected?.checkedOut ?? false) || busy)
                Button(tr("Actualizar a la última")) { act("vcUpdate", [:]) }
                    .disabled(!(selected.map { $0.checkedOut && ($0.version ?? 0) < ($0.latest ?? 0) } ?? false) || busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(10)
    }

    private var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(history) { v in
                    HStack(spacing: 8) {
                        Text("v\(v.version)").font(.callout.monospacedDigit().weight(.semibold)).frame(width: 34, alignment: .leading)
                        Text(v.user ?? "").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: TimeInterval(v.date) / 1000).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                        Text(v.comment ?? "").lineLimit(1)
                        Spacer()
                        Button(tr("Abrir esta versión")) { if let f = selected { model.openVersion(path: f.path, version: v.version) } }
                            .controlSize(.small)
                            .help(tr("Abre esa versión en modo de solo lectura, sin copiarla"))
                        Button(tr("Extraer copia")) { act("vcExtract", ["version": v.version]) }
                            .controlSize(.small)
                            .help(tr("Copia esta versión al proyecto como archivo privado para compararla"))
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 130)
    }

    private func icon(_ state: String) -> String {
        switch state {
        case "private": "doc"
        case "versioned": "lock"
        case "checkedOut": "checkmark.circle"
        case "modified": "pencil.circle.fill"
        case "hijacked": "exclamationmark.triangle.fill"
        default: "doc"
        }
    }

    private func tint(_ state: String) -> Color {
        switch state {
        case "checkedOut": .green
        case "modified": .blue
        case "hijacked": .orange
        default: .secondary
        }
    }

    private func title(_ f: VCFile) -> String {
        switch f.state {
        case "private": tr("Privado")
        case "versioned": tr("Versionado (solo lectura)")
        case "checkedOut": f.exclusive ? tr("Check-out exclusivo") : "Check-out"
        case "modified": tr("Modificado")
        case "hijacked": tr("Secuestrado")
        default: f.state
        }
    }

    private func reload() async {
        guard model.project?.open == true else { files = []; return }
        do {
            let result: VCFiles = try await model.engine.call("vcFiles")
            files = result.files
            if selection == nil { selection = files.first?.id }
        } catch {
            message = error.localizedDescription
            failed = true
        }
    }

    private func loadHistory() async {
        guard let f = selected, f.versioned else { history = []; checkouts = []; return }
        history = (try? await model.engine.call("vcHistory", ["path": f.path])) ?? []
        checkouts = (try? await model.engine.call("vcCheckouts", ["path": f.path])) ?? []
    }

    private func terminate(_ c: VCCheckout) {
        guard let f = selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                checkouts = try await model.engine.call("vcTerminate", ["path": f.path, "id": c.id])
                message = nil
                failed = false
            } catch {
                message = error.localizedDescription
                failed = true
            }
            await reload()
        }
    }

    private func act(_ method: String, _ extra: [String: Any]) {
        guard let f = selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var params = extra
                params["path"] = f.path
                if method == "vcExtract" {
                    let copy: ExtractedVersion = try await model.engine.call(method, params)
                    message = tr("Versión extraída como «%@».", copy.name)
                } else {
                    _ = try await model.engine.call(method, params, as: VCFile.self)
                    message = nil
                    if method == "vcCheckin" || method == "vcAdd" { comment = "" }
                }
                failed = false
            } catch {
                message = error.localizedDescription
                failed = true
            }
            await reload()
            await loadHistory()
            await model.refreshProject()
            if f.open { await model.refreshUndo() }
        }
    }
}
