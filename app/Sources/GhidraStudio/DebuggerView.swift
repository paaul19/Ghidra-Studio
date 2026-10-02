import AppKit
import SwiftUI

/// The debugger: a process under LLDB, shown next to (and mapped onto) the program open in Studio.
struct DebuggerView: View {
    @Environment(AppModel.self) private var model

    private var debugger: DebugSession { model.debugger }

    var body: some View {
        VStack(spacing: 0) {
            DebugToolbar()
            Divider()
            if debugger.showsSession {
                DebugSessionView()
            } else {
                DebugSetupView()
            }
        }
        .windowMinSize(1040, 640)
        .sheet(item: model.formBinding("debugger")) { request in FormSheet(request: request) }
        .onAppear { debugger.loadConfig() }
        .onChange(of: model.activeSession) { _, _ in debugger.loadConfig() }
    }
}

// MARK: - Toolbar

private struct DebugToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let d = model.debugger
        HStack(spacing: 8) {
            if d.phase == .replay {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tint)
                Text(tr("Traza grabada")).font(.headline)
                Button(tr("Cerrar traza")) { d.closeTrace() }
                emulateButton
            } else if d.isActive {
                Button { d.resumeExecution() } label: { Label(tr("Continuar"), systemImage: "play.fill") }
                    .disabled(!d.isStopped)
                    .help(tr("Continuar la ejecución"))
                Button { d.pause() } label: { Label(tr("Pausar"), systemImage: "pause.fill") }
                    .disabled(d.phase != .running)
                    .help(tr("Pausar el proceso"))
                Divider().frame(height: 18)
                Button { d.stepInto() } label: { Label(tr("Entrar"), systemImage: "arrow.down.to.line") }
                    .disabled(!d.isStopped)
                    .help(tr("Ejecutar una instrucción, entrando en las llamadas"))
                Button { d.stepOver() } label: { Label(tr("Saltar"), systemImage: "arrow.right.to.line") }
                    .disabled(!d.isStopped)
                    .help(tr("Ejecutar una instrucción, sin entrar en las llamadas"))
                Button { d.stepOut() } label: { Label(tr("Salir"), systemImage: "arrow.up.to.line") }
                    .disabled(!d.isStopped)
                    .help(tr("Ejecutar hasta salir de la función actual"))
                Divider().frame(height: 18)
                Button { d.restart() } label: { Label(tr("Reiniciar"), systemImage: "arrow.clockwise") }
                    .help(tr("Terminar y volver a empezar"))
                Button { d.stop() } label: {
                    Label(d.config.mode == .launch ? tr("Detener") : tr("Soltar"), systemImage: "stop.fill")
                }
                .help(d.config.mode == .launch ? tr("Terminar el proceso") : tr("Dejar de depurar el proceso sin terminarlo"))
                if d.config.mode != .launch {
                    Button(tr("Terminar proceso")) { d.stop(detach: false) }
                }
                if d.canStepBack {
                    Divider().frame(height: 18)
                    Button { d.stepBack() } label: { Label(tr("Atrás"), systemImage: "arrow.uturn.backward") }
                        .disabled(!d.isStopped)
                        .help(tr("Deshacer una instrucción (el destino permite ejecutar hacia atrás)"))
                    Button { d.reverseContinue() } label: { Label(tr("Continuar hacia atrás"), systemImage: "backward.fill") }
                        .disabled(!d.isStopped)
                }
                Divider().frame(height: 18)
                emulateButton
                if d.viewing != nil {
                    Button { d.view(snapshot: nil) } label: { Label(tr("Volver al presente"), systemImage: "forward.end.fill") }
                        .buttonStyle(.glassProminent)
                        .help(tr("Estás viendo un instante anterior de la traza. Vuelve al estado actual del proceso."))
                }
            } else {
                Image(systemName: "ant").foregroundStyle(.tint)
                Text(tr("Depurador")).font(.headline)
            }
            Spacer()
            if d.phase == .starting || d.phase == .running { ProgressView().controlSize(.small) }
            Text(d.status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if d.isActive {
                Toggle(isOn: Binding(get: { d.follow }, set: { d.follow = $0 })) { Image(systemName: "link") }
                    .toggleStyle(.button)
                    .help(tr("Llevar la ventana principal a la instrucción actual en cada parada"))
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emulateButton: some View {
        Button {
            Task { if await model.debugger.emulateFromHere() { openWindow(id: "emulator") } }
        } label: { Label(tr("Emular desde aquí"), systemImage: "cpu") }
            .disabled(!model.debugger.hasState)
            .help(tr("Inicia el emulador de Studio con los registros y la pila de este instante, sin tocar el proceso"))
    }
}

// MARK: - Setup

private struct DebugSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var processes: [ProcessItem] = []
    @State private var filter = ""

    var body: some View {
        @Bindable var d = model.debugger
        HStack(spacing: 0) {
            Form {
                Section {
                    Picker(tr("Modo"), selection: $d.config.mode) {
                        ForEach(DebugConfig.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                switch d.config.mode {
                case .launch:
                    Section(tr("Programa")) {
                        HStack {
                            TextField(tr("Ejecutable"), text: $d.config.program)
                                .font(.system(.body, design: .monospaced))
                            Button(tr("Elegir…")) { chooseProgram() }
                        }
                        TextField(tr("Argumentos"), text: $d.config.arguments)
                            .font(.system(.body, design: .monospaced))
                        TextField(tr("Carpeta de trabajo"), text: $d.config.workingDirectory)
                            .font(.system(.body, design: .monospaced))
                        TextField(tr("Variables de entorno (CLAVE=valor, una por línea)"), text: $d.config.environment,
                                  axis: .vertical)
                            .lineLimit(2...5)
                            .font(.system(.body, design: .monospaced))
                    }
                    Section {
                        Toggle(tr("Parar al empezar, antes de la primera instrucción"), isOn: $d.config.stopAtEntry)
                        Toggle(tr("Cargar siempre en la misma dirección (sin ASLR)"), isOn: $d.config.disableASLR)
                    }
                    Section {
                        if d.needsDebuggableCopy {
                            Label(tr("macOS no permite depurar este ejecutable tal como está firmado."),
                                  systemImage: "lock.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Button(tr("Usar una copia depurable")) { d.useDebuggableCopy() }
                                .disabled(!FileManager.default.isExecutableFile(atPath: d.config.program))
                            Spacer()
                        }
                        Text(tr("Para apps firmadas con protección o binarios del sistema: copia el ejecutable (o la app entera) a la carpeta de Studio y firma la copia para depuración. El original no se toca."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .attach:
                    Section(tr("Proceso")) {
                        HStack {
                            TextField("PID", text: $d.config.pid).frame(width: 110)
                            TextField(tr("Filtrar procesos"), text: $filter)
                            Button { processes = DebugSession.processes() } label: { Image(systemName: "arrow.clockwise") }
                                .help(tr("Actualizar la lista"))
                        }
                        Toggle(tr("Parar al adjuntar"), isOn: $d.config.stopAtEntry)
                    }
                case .remote:
                    Section(tr("Servidor de depuración")) {
                        TextField(tr("host:puerto"), text: $d.config.remote)
                            .font(.system(.body, design: .monospaced))
                        HStack {
                            TextField(tr("Ejecutable local (opcional, para los símbolos)"), text: $d.config.program)
                                .font(.system(.body, design: .monospaced))
                            Button(tr("Elegir…")) { chooseProgram() }
                        }
                        Toggle(tr("Parar al conectar"), isOn: $d.config.stopAtEntry)
                        Text(tr("Se conecta con el protocolo remoto de GDB: gdbserver, debugserver, QEMU (-s), OpenOCD…"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DebugConnectorSection()
                Section {
                    HStack {
                        Button {
                            d.start()
                        } label: {
                            Label(d.config.mode == .launch ? tr("Iniciar depuración") : tr("Conectar"), systemImage: "play.fill")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!canStart)
                        Button(tr("Abrir traza…")) { TraceFiles.open(model.debugger) }
                            .help(tr("Abre una traza guardada para recorrerla sin el proceso"))
                        Spacer()
                        if model.program == nil {
                            Text(tr("Abre el programa en Studio para ver su código mientras depuras."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(tr("Los breakpoints se ponen en el código de la ventana principal (clic en el margen o tecla K)."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480)

            Divider()
            if d.config.mode == .attach {
                processList
            } else {
                lastOutput
            }
        }
        .onAppear { if processes.isEmpty { processes = DebugSession.processes() } }
    }

    private var canStart: Bool {
        let c = model.debugger.config
        switch c.mode {
        case .launch: return FileManager.default.isExecutableFile(atPath: c.program)
        case .attach: return Int(c.pid.trimmingCharacters(in: .whitespaces)) != nil
        case .remote: return c.remote.contains(":")
        }
    }

    private var processList: some View {
        let items = processes.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || "\($0.pid)" == filter }
        return List(items) { p in
            Button {
                model.debugger.config.pid = "\(p.pid)"
            } label: {
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(verbatim: "\(p.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground("\(p.pid)" == model.debugger.config.pid ? Color.accentColor.opacity(0.2) : Color.clear)
        }
        .frame(minWidth: 300)
    }

    private var lastOutput: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Salida de la última sesión")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
            Divider()
            ConsoleText(text: model.debugger.console)
        }
        .frame(minWidth: 320)
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.debugger.config.program = AppModel.resolveBundleExecutable(url).path
    }
}

// MARK: - Session

private struct DebugSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var side = 0
    @State private var bottom = 0

    var body: some View {
        VSplitView {
            HSplitView {
                ThreadsAndStack().frame(minWidth: 200, idealWidth: 250, maxWidth: 380)
                DynamicListing().frame(minWidth: 380)
                VStack(spacing: 0) {
                    Picker("", selection: $side) {
                        Text(tr("Registros")).tag(0)
                        Text(tr("Expresiones")).tag(1)
                        Text("Breakpoints").tag(2)
                        Text(tr("Módulos")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    Divider()
                    switch side {
                    case 0: RegistersPanel()
                    case 1: WatchesPanel()
                    case 2: BreakpointsPanel()
                    default: ModulesPanel()
                    }
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 480)
            }
            .frame(minHeight: 280)
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $bottom) {
                        Text(tr("Consola")).tag(0)
                        Text(tr("Memoria")).tag(1)
                        Text(tr("Tiempo")).tag(2)
                        Text(tr("Más")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                switch bottom {
                case 0: ConsolePanel()
                case 1: MemoryPanel()
                case 2: TimePanel()
                default: DebugExtrasPanel()
                }
            }
            .frame(minHeight: 170, idealHeight: 230)
        }
    }
}

private struct ThreadsAndStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.debugger
        VStack(spacing: 0) {
            PanelTitle(tr("Hilos"))
            List(d.threads) { thread in
                HStack {
                    Image(systemName: thread.id == d.currentThread ? "arrowtriangle.right.fill" : "circle")
                        .font(.caption2).foregroundStyle(thread.id == d.currentThread ? Color.green : Color.secondary)
                    Text(verbatim: thread.name.isEmpty ? "\(thread.id)" : thread.name).lineLimit(1)
                    Spacer()
                    Text(verbatim: "\(thread.id)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { d.select(thread: thread.id) }
            }
            .frame(minHeight: 60, maxHeight: 130)
            Divider()
            PanelTitle(tr("Pila de llamadas"))
            List(Array(d.frames.enumerated()), id: \.element.id) { index, frame in
                VStack(alignment: .leading, spacing: 1) {
                    Text(frame.name.isEmpty ? "0x" + String(frame.pc, radix: 16) : frame.name)
                        .font(.system(.callout, design: .monospaced).weight(index == d.currentFrame ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("0x" + String(frame.pc, radix: 16))
                        if let s = frame.staticAddress { Text("→ " + s).foregroundStyle(.tint) }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture { d.select(frame: index) }
                .listRowBackground(index == d.currentFrame ? Color.accentColor.opacity(0.18) : Color.clear)
                .contextMenu {
                    if let s = frame.staticAddress {
                        Button(tr("Mostrar en la ventana principal")) { model.go(s) }
                    }
                    Button(tr("Copiar dirección")) { model.copyToPasteboard("0x" + String(frame.pc, radix: 16)) }
                }
            }
        }
    }
}

/// Disassembly of the process around the program counter.
private struct DynamicListing: View {
    @Environment(AppModel.self) private var model
    @State private var document: CodeDocument?
    @State private var selected: String?
    @State private var scroll: ScrollRequest?

    var body: some View {
        let d = model.debugger
        ZStack {
            Color(nsColor: Theme.background)
            if let document, !d.instructions.isEmpty {
                CodeTextView(document: document, highlightAddress: selected, scrollRequest: scroll,
                             breakpoints: d.dynamicBreakpoints,
                             pcAddress: d.pc.map { String($0, radix: 16) },
                             onToggleBreakpoint: { text in
                                 if let a = UInt64(text, radix: 16) { d.toggleBreakpoint(dynamic: a) }
                             },
                             isPrimary: false,
                             onNavigate: { _ in },
                             onSelectLine: { selected = $0 },
                             menuActions: { ctx in menu(ctx) })
            } else if d.phase == .running {
                ContentUnavailableView(tr("En ejecución"), systemImage: "play.circle",
                                       description: Text(tr("Pausa el proceso o espera a un breakpoint para ver el código.")))
            } else if d.phase == .replay || d.viewing != nil {
                ContentUnavailableView(tr("Código no grabado"), systemImage: "clock.arrow.circlepath",
                                       description: Text(tr("Este instante está fuera del programa abierto en Studio y la traza no guardó su código.")))
            } else {
                ProgressView()
            }
        }
        .onAppear { rebuild() }
        .onChange(of: d.disassemblyVersion) { _, _ in rebuild() }
        .onChange(of: model.fontSize) { _, _ in rebuild() }
    }

    private func rebuild() {
        let d = model.debugger
        document = DocumentBuilder.dynamic(d.instructions, fontSize: model.fontSize)
        if let pc = d.pc {
            selected = String(pc, radix: 16)
            scroll = ScrollRequest(address: String(pc, radix: 16))
        }
    }

    private func menu(_ ctx: CodeContext) -> [CodeMenuAction] {
        let d = model.debugger
        guard let line = ctx.lineAddress, let address = UInt64(line, radix: 16) else { return [] }
        var a: [CodeMenuAction] = []
        a.append(.init(title: d.dynamicBreakpoints[line] == nil ? tr("Poner breakpoint  (K)") : tr("Quitar breakpoint  (K)"),
                       symbol: "circle.fill") { d.toggleBreakpoint(dynamic: address) })
        a.append(.init(title: tr("Ejecutar hasta aquí"), symbol: "arrow.right.to.line") { d.run(to: address) })
        if let s = d.toStatic(address) {
            a.append(.init(title: tr("Mostrar en la ventana principal"), symbol: "arrow.up.forward.app") { model.go(s) })
        }
        a.append(.init(title: tr("Ver la memoria aquí"), symbol: "memorychip") { d.showMemory("0x" + line) })
        a.append(.init(title: tr("Copiar dirección %@", "0x" + line), symbol: "number") { model.copyToPasteboard("0x" + line) })
        return a
    }
}

private struct RegistersPanel: View {
    @Environment(AppModel.self) private var model
    @State private var editing: String?
    @State private var draft = ""
    @State private var expanded = Set<String>()

    var body: some View {
        let d = model.debugger
        List {
            ForEach(Array(d.registerGroups.enumerated()), id: \.element.id) { index, group in
                DisclosureGroup(isExpanded: Binding(
                    get: { index == 0 ? !expanded.contains("-" + group.name) : expanded.contains(group.name) },
                    set: { open in
                        if index == 0 {
                            if open { expanded.remove("-" + group.name) } else { expanded.insert("-" + group.name) }
                        } else if open {
                            expanded.insert(group.name)
                            d.loadGroup(group.name)
                        } else {
                            expanded.remove(group.name)
                        }
                    })) {
                    ForEach(group.registers) { register in
                        row(register)
                    }
                } label: {
                    Text(group.name).font(.callout.weight(.medium))
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if d.registerGroups.isEmpty {
                Text(d.isStopped ? tr("Sin registros") : tr("Los registros se muestran cuando el proceso está parado."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }

    private func row(_ register: DebugRegister) -> some View {
        HStack {
            Text(register.name).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            if editing == register.name {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit {
                        model.debugger.writeRegister(register.name, draft)
                        editing = nil
                    }
                    .onExitCommand { editing = nil }
                Button("OK") {
                    model.debugger.writeRegister(register.name, draft)
                    editing = nil
                }
                .controlSize(.small)
            } else {
                Text(register.value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(register.changed ? Color.red : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draft = register.value
            editing = register.name
        }
        .contextMenu {
            Button(tr("Cambiar valor…")) {
                draft = register.value
                editing = register.name
            }
            Button(tr("Ver la memoria a la que apunta")) { model.debugger.showMemory(register.value) }
            Button(tr("Copiar valor")) { model.copyToPasteboard(register.value) }
        }
        .help(tr("Doble clic para cambiar el valor"))
    }
}

private struct WatchesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let d = model.debugger
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Expresión, p. ej. $x0 + 8 o *(int *)$sp"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { add() }
                Button(tr("Añadir")) { add() }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
            Divider()
            List(d.watches) { watch in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(watch.expression).font(.system(.callout, design: .monospaced))
                        Text(watch.value.isEmpty ? "—" : watch.value)
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button { d.watches.removeAll { $0.id == watch.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private func add() {
        model.debugger.addWatch(draft)
        draft = ""
    }
}

private struct BreakpointsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var watchAddress = ""
    @State private var watchSize = 4
    @State private var watchKind = "write"

    var body: some View {
        let d = model.debugger
        let mine = d.mappedSession == model.activeSession
        VStack(spacing: 0) {
            List {
                Section(tr("En el programa")) {
                    if model.breakpoints.isEmpty {
                        Text(tr("Haz clic en el margen del código o pulsa K para poner uno."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.breakpoints) { b in
                        let enabled = b.type == BookmarkItem.breakpointEnabled
                        HStack {
                            Toggle("", isOn: Binding(get: { enabled }, set: { on in
                                model.setBreakpoint(address: b.address, state: on ? "enabled" : "disabled")
                            }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name(b.address)).lineLimit(1).truncationMode(.middle)
                                Text(b.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mine, enabled, let dyn = d.toDynamic(b.address), d.isActive {
                                Image(systemName: d.verified[dyn] == true ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                    .foregroundStyle(d.verified[dyn] == true ? Color.green : Color.orange)
                                    .help(d.verified[dyn] == true ? tr("Activo en el proceso") : tr("LLDB no pudo ponerlo"))
                            }
                            if d.conditions[b.address] != nil {
                                Image(systemName: "questionmark.diamond").foregroundStyle(.orange).help(tr("Tiene condición o comandos"))
                            }
                            Button { model.setBreakpoint(address: b.address, state: "none") } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.go(b.address) }
                        .contextMenu {
                            Button(tr("Condición y comandos…")) { model.requestBreakpointRule(b.address) }
                            Button(tr("Activar todos")) { model.setAllBreakpoints(enabled: true) }
                            Button(tr("Desactivar todos")) { model.setAllBreakpoints(enabled: false) }
                        }
                    }
                }
                Section(tr("Puntos de observación (acceso a memoria)")) {
                    HStack(spacing: 6) {
                        TextField(tr("Dirección o expresión"), text: $watchAddress)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Picker("", selection: $watchSize) {
                            Text("1").tag(1); Text("2").tag(2); Text("4").tag(4); Text("8").tag(8)
                        }
                        .labelsHidden()
                        .frame(width: 52)
                        Picker("", selection: $watchKind) {
                            Text(tr("escritura")).tag("write")
                            Text(tr("lectura")).tag("read")
                            Text(tr("ambas")).tag("read_write")
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        Button(tr("Añadir")) {
                            d.addWatchpoint(expression: watchAddress, size: watchSize, kind: watchKind)
                            watchAddress = ""
                        }
                        .disabled(!d.isStopped || watchAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.small)
                    ForEach(d.watchpoints) { w in
                        HStack {
                            Image(systemName: "eye").foregroundStyle(.orange)
                            Text(w.description).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Button { d.removeWatchpoint(w) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
                if !d.extraBreakpoints.isEmpty {
                    Section(tr("Solo en esta sesión")) {
                        ForEach(d.extraBreakpoints.sorted(), id: \.self) { address in
                            HStack {
                                Text("0x" + String(address, radix: 16)).font(.system(.callout, design: .monospaced))
                                Spacer()
                                Button { d.toggleExtra(address) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text(tr("Se guardan en el programa, como los de Ghidra clásico.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Quitar todos")) { model.clearBreakpoints() }.disabled(model.breakpoints.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private func name(_ address: String) -> String {
        guard let v = addressValue(address) else { return address }
        // the function that contains the breakpoint
        let owner = model.functions.last { f in (addressValue(f.address) ?? .max) <= v }
        guard let owner, let start = addressValue(owner.address) else { return address }
        return v == start ? owner.name : "\(owner.name)+0x\(String(v - start, radix: 16))"
    }
}

private struct ModulesPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.debugger
        List(d.modules) { module in
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(module.name).lineLimit(1)
                        if module.id == d.mappedModule {
                            Text(tr("programa abierto · %@", d.slideDescription))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                    }
                    Text("0x" + String(module.base, radix: 16) + "  " + module.path)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if module.id != d.mappedModule {
                    Button(tr("Es este programa")) { d.map(module: module) }
                        .controlSize(.small)
                        .help(tr("Usa este módulo como el programa abierto en Studio: los breakpoints y la posición se traducen con su dirección de carga."))
                }
            }
            .contextMenu {
                Button(tr("Ver la memoria aquí")) { d.showMemory("0x" + String(module.base, radix: 16)) }
                Button(tr("Copiar ruta")) { model.copyToPasteboard(module.path) }
            }
        }
        .listStyle(.inset)
    }
}

private struct MemoryPanel: View {
    @Environment(AppModel.self) private var model
    @State private var document: CodeDocument?
    @State private var writeAddress = ""
    @State private var writeBytes = ""

    var body: some View {
        @Bindable var d = model.debugger
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(tr("Dirección o expresión ($sp, $x0, 0x1000…)"), text: $d.memoryExpression)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 280)
                    .onSubmit { Task { await d.readMemory() } }
                Button(tr("Ir")) { Task { await d.readMemory() } }
                Button("SP") { d.showMemory("$sp") }
                Button("PC") { d.showMemory("$pc") }
                Button { d.showMemory("0x" + String(d.memoryBase &- 256, radix: 16)) } label: { Image(systemName: "chevron.up") }
                    .disabled(d.memoryBytes.isEmpty)
                Button { d.showMemory("0x" + String(d.memoryBase &+ 256, radix: 16)) } label: { Image(systemName: "chevron.down") }
                    .disabled(d.memoryBytes.isEmpty)
                Spacer()
                TextField(tr("Dirección"), text: $writeAddress)
                    .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced)).frame(width: 130)
                TextField(tr("Bytes: 90 90 c3"), text: $writeBytes)
                    .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced)).frame(width: 150)
                Button(tr("Escribir")) { d.writeMemory(address: writeAddress, bytes: writeBytes) }
                    .disabled(!d.isStopped || writeAddress.isEmpty || writeBytes.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            ZStack {
                Color(nsColor: Theme.background)
                if let error = d.memoryError {
                    Text(error).foregroundStyle(.secondary)
                } else if let document {
                    CodeTextView(document: document, highlightAddress: nil, scrollRequest: nil, isPrimary: false,
                                 onNavigate: { _ in }, onSelectLine: { writeAddress = "0x" + $0 },
                                 menuActions: { _ in [] })
                } else {
                    Text(tr("La memoria se muestra cuando el proceso está parado.")).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { rebuild() }
        .onChange(of: d.memoryVersion) { _, _ in rebuild() }
        .onChange(of: model.fontSize) { _, _ in rebuild() }
    }

    private func rebuild() {
        let d = model.debugger
        guard !d.memoryBytes.isEmpty else { document = nil; return }
        let dump = HexDump(start: String(d.memoryBase, radix: 16), bytes: d.memoryBytes, block: nil)
        document = DocumentBuilder.hex(dump, fontSize: model.fontSize)
    }
}

private struct ConsolePanel: View {
    @Environment(AppModel.self) private var model
    @State private var line = ""
    @State private var history: [String] = []
    /// Where the line goes: an LLDB command, or the standard input of the program.
    @State private var toProgram = false

    var body: some View {
        let d = model.debugger
        VStack(spacing: 0) {
            ConsoleText(text: d.console)
            Divider()
            HStack(spacing: 6) {
                if d.acceptsInput {
                    Picker("", selection: $toProgram) {
                        Text("LLDB").tag(false)
                        Text(tr("Programa")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .help(tr("Escribe una orden de LLDB o texto para la entrada estándar del programa"))
                }
                Text(toProgram && d.acceptsInput ? "stdin" : "(lldb)")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                TextField(toProgram && d.acceptsInput ? tr("Texto para el programa (se envía con salto de línea)")
                          : tr("Orden de LLDB: bt, register read, memory read $sp, image list…"), text: $line)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { run() }
                if let last = history.last, line.isEmpty {
                    Button { line = last } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(tr("Repetir la última orden"))
                }
                if toProgram && d.acceptsInput {
                    Button(tr("Enviar")) { run() }
                        .controlSize(.small)
                    Button(tr("Fin de entrada")) { d.endInput() }
                        .controlSize(.small)
                        .help(tr("Cierra la entrada estándar del programa, como ⌃D en una terminal"))
                } else {
                    Button(tr("Ejecutar")) { run() }
                        .controlSize(.small)
                        .disabled(line.trimmingCharacters(in: .whitespaces).isEmpty || !d.isActive)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func run() {
        if toProgram, model.debugger.acceptsInput {
            // an empty line is input too
            model.debugger.sendInput(line)
            line = ""
            return
        }
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        history.append(text)
        model.debugger.runConsole(text)
        line = ""
    }
}

// MARK: - Time

/// The trace: one snapshot per stop. Pick one to see the process as it was then.
private struct TimePanel: View {
    @Environment(AppModel.self) private var model
    @State private var steps = "100"

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        let d = model.debugger
        let count = d.history.count
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { d.view(snapshot: d.viewedIndex - 1) } label: { Image(systemName: "chevron.backward") }
                    .disabled(d.viewedIndex <= 0 || d.recording)
                    .help(tr("Instante anterior"))
                    .accessibilityLabel(tr("Instante anterior"))
                Button { d.view(snapshot: d.viewedIndex + 1) } label: { Image(systemName: "chevron.forward") }
                    .disabled(d.viewedIndex >= count - 1 || d.recording)
                    .help(tr("Instante siguiente"))
                    .accessibilityLabel(tr("Instante siguiente"))
                if count > 1 {
                    Slider(value: Binding(get: { Double(d.viewedIndex) }, set: { d.view(snapshot: Int($0.rounded())) }),
                           in: 0...Double(count - 1), step: 1)
                        .frame(maxWidth: 260)
                        .disabled(d.recording)
                }
                Text(verbatim: count == 0 ? "—" : "\(d.viewedIndex + 1) / \(count)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if d.phase != .replay {
                    Button(tr("Presente")) { d.view(snapshot: nil) }
                        .disabled(d.viewing == nil)
                }
                Spacer()
                if d.phase != .replay {
                    TextField("", text: $steps)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .help(tr("Número de instrucciones a grabar"))
                    if d.recording {
                        Button(tr("Detener grabación")) { d.cancelRecording() }
                    } else {
                        Button(tr("Grabar pasos")) { d.recordSteps(Int(steps) ?? 0) }
                            .disabled(!d.isStopped || (Int(steps) ?? 0) <= 0)
                            .help(tr("Ejecuta ese número de instrucciones una a una y guarda cada instante, para recorrerlas después"))
                    }
                }
                Button(tr("Guardar traza…")) { TraceFiles.save(d) }
                    .disabled(count == 0 || d.recording)
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(d.history) { snapshot in
                    Button {
                        d.view(snapshot: snapshot.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(verbatim: "\(snapshot.id + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(Self.clock.string(from: snapshot.time))
                                .font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Text(snapshot.frames.first?.name ?? "")
                                .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            if let pc = snapshot.pc {
                                Text(verbatim: "0x" + String(pc, radix: 16))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(snapshot.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(snapshot.id)
                    .listRowBackground(snapshot.id == d.viewedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                }
                .listStyle(.inset)
                .onChange(of: d.viewedIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
                .onChange(of: count) { _, _ in if d.viewing == nil { proxy.scrollTo(count - 1, anchor: .bottom) } }
            }
            .overlay {
                if count == 0 {
                    Text(tr("Cada parada del proceso queda grabada aquí. Elige una para ver cómo estaba todo en ese instante."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        }
    }
}

/// Saving and opening traces.
@MainActor
enum TraceFiles {
    private static var directory: URL? {
        UserDefaults.standard.string(forKey: "traceDirectory").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    static func save(_ debugger: DebugSession) {
        let panel = NSSavePanel()
        let name = AppModel.shared.tabs.first { $0.id == debugger.mappedSession }?.name ?? "programa"
        panel.nameFieldStringValue = name + ".studiotrace"
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "traceDirectory")
        do { try debugger.saveTrace(to: url) } catch { AppModel.shared.errorMessage = error.localizedDescription }
    }

    static func open(_ debugger: DebugSession) {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "traceDirectory")
        do { try debugger.loadTrace(from: url) } catch {
            AppModel.shared.errorMessage = tr("No se pudo abrir la traza: %@", error.localizedDescription)
        }
    }
}

/// Monospaced, selectable output that keeps the last line in view.
private struct ConsoleText: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: Theme.background))
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct PanelTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
    }
}
