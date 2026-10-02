import AppKit
import SwiftUI

// MARK: - Connector settings (setup form)

/// Which debugger runs the session and how it reaches the target.
struct DebugConnectorSection: View {
    @Environment(AppModel.self) private var model

    private struct Preset {
        let title: String
        let help: String
        let remote: String
        let kind: String
        let pre: String
        let commands: String
    }

    private static var presets: [Preset] {
        [Preset(title: "gdbserver / QEMU / OpenOCD", help: tr("En el otro lado: gdbserver :1234 ./programa, o qemu -s -S."),
                remote: "localhost:1234", kind: "gdb-remote", pre: "", commands: ""),
         Preset(title: tr("Remoto por SSH"), help: tr("Arranca gdbserver en la máquina remota y trae su puerto con un túnel."),
                remote: "localhost:1234", kind: "gdb-remote",
                pre: "ssh -f -L 1234:localhost:1234 usuario@host 'gdbserver :1234 ./programa'", commands: ""),
         Preset(title: "Android (adb)", help: tr("Redirige el puerto del dispositivo; en él debe correr lldb-server o gdbserver."),
                remote: "localhost:1234", kind: "gdb-remote", pre: "adb forward tcp:1234 tcp:1234",
                commands: "platform select remote-android"),
         Preset(title: "Wine", help: tr("winedbg --gdb --no-start programa.exe imprime el puerto en el que escucha."),
                remote: "localhost:1234", kind: "gdb-remote", pre: "", commands: ""),
         Preset(title: tr("Kernel (QEMU o KDP)"), help: tr("QEMU con -s -S usa gdb-remote; un kernel de macOS con KDP usa kdp-remote y la IP."),
                remote: "localhost:1234", kind: "gdb-remote", pre: "", commands: ""),
         Preset(title: tr("rr (ejecución hacia atrás)"), help: tr("rr replay -s 1234 sirve la grabación; los pasos hacia atrás funcionan de verdad."),
                remote: "localhost:1234", kind: "gdb-remote", pre: "", commands: "")]
    }

    var body: some View {
        @Bindable var d = model.debugger
        Section(tr("Conector")) {
            Picker(tr("Depurador"), selection: Binding(get: { d.config.adapter ?? "lldb" }, set: { d.config.adapter = $0 })) {
                Text("LLDB").tag("lldb")
                Text(DAPConnection.gdbPath() == nil ? tr("GDB (no instalado)") : "GDB").tag("gdb")
                Text(tr("Otro adaptador DAP")).tag("custom")
            }
            if d.config.adapter == "custom" {
                TextField(tr("Comando del adaptador (ruta y argumentos)"), text: Binding(get: { d.config.adapterCommand ?? "" },
                                                                                          set: { d.config.adapterCommand = $0 }))
                    .font(.system(.body, design: .monospaced))
                TextField(tr("Argumentos de launch/attach en JSON"), text: Binding(get: { d.config.launchJSON ?? "" },
                                                                                    set: { d.config.launchJSON = $0 }), axis: .vertical)
                    .font(.system(.callout, design: .monospaced)).lineLimit(2...6)
                Text(tr("Cualquier depurador que hable DAP: el de Java (java-debug), Delve, debugpy… Los paneles muestran lo que el adaptador ofrezca."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if d.config.mode == .remote {
                Menu(tr("Preajustes de conexión")) {
                    ForEach(Self.presets, id: \.title) { p in
                        Button(p.title) {
                            d.config.remote = p.remote
                            d.config.remoteKind = p.kind
                            d.config.preCommand = p.pre
                            d.config.initCommands = p.commands
                            model.statusMessage = p.help
                        }
                    }
                }
                Picker(tr("Protocolo"), selection: Binding(get: { d.config.remoteKind ?? "gdb-remote" }, set: { d.config.remoteKind = $0 })) {
                    Text("gdb-remote").tag("gdb-remote")
                    Text("kdp-remote").tag("kdp-remote")
                }
                TextField(tr("Comando previo (túnel ssh, adb forward…)"), text: Binding(get: { d.config.preCommand ?? "" },
                                                                                       set: { d.config.preCommand = $0 }))
                    .font(.system(.body, design: .monospaced))
            }
            TextField(tr("Comandos del depurador al iniciar (uno por línea)"), text: Binding(get: { d.config.initCommands ?? "" },
                                                                                             set: { d.config.initCommands = $0 }),
                      axis: .vertical)
                .font(.system(.callout, design: .monospaced)).lineLimit(1...5)
        }
    }
}

// MARK: - Extras panel of a session

struct DebugExtrasPanel: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var compareWith: Int?
    @State private var note: String?

    private var d: DebugSession { model.debugger }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text(tr("Regiones")).tag(0)
                    Text(tr("Mapeos")).tag(1)
                    Text(tr("Objetos")).tag(2)
                    Text(tr("Plataforma y pila")).tag(3)
                    Text(tr("Instantes")).tag(4)
                    Text(tr("Memoria en el tiempo")).tag(5)
                    Text(tr("Trazas")).tag(6)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            switch tab {
            case 0: regions
            case 1: mappings
            case 2: objects
            case 3: platform
            case 4: snapshots
            case 5: MemoryOverTime()
            default: traces
            }
        }
    }

    // MARK: regions

    private var regions: some View {
        VStack(spacing: 0) {
            GenericTable(rows: d.regions,
                         columns: [ColumnSpec(key: "start", title: tr("Inicio"), width: 140, mono: true),
                                   ColumnSpec(key: "end", title: tr("Fin"), width: 140, mono: true),
                                   ColumnSpec(key: "size", title: tr("Tamaño"), width: 100),
                                   ColumnSpec(key: "perms", title: tr("Permisos"), width: 70, mono: true),
                                   ColumnSpec(key: "name", title: tr("Nombre"), width: 260),
                                   .address(tr("En el programa"))],
                         storageKey: "debugRegions",
                         actions: [RowAction(title: tr("Ver la memoria")) { row in d.showMemory("0x" + (row["start"]?.text ?? "")) }])
                .task(id: "\(d.isStopped)") { if d.regions.isEmpty { d.loadRegions() } }
            HStack {
                Button(tr("Actualizar")) { d.loadRegions() }.disabled(!d.isStopped)
                Spacer()
            }
            .controlSize(.small).padding(6)
        }
    }

    // MARK: mappings

    private var mappings: some View {
        VStack(spacing: 0) {
            GenericTable(rows: d.mappingRows,
                         columns: [ColumnSpec(key: "name", title: tr("Módulo"), width: 220),
                                   ColumnSpec(key: "dynamic", title: tr("Dirección en el proceso"), width: 160, mono: true),
                                   ColumnSpec(key: "static", title: tr("Dirección en el programa"), width: 160, mono: true),
                                   ColumnSpec(key: "slide", title: tr("Desplazamiento o tamaño"), width: 150, mono: true),
                                   ColumnSpec(key: "kind", title: tr("Clase"), width: 130)],
                         storageKey: "debugMappings", addressKey: nil,
                         actions: [RowAction(title: tr("Usar como el programa abierto")) { row in
                             if let m = d.modules.first(where: { $0.path == row["path"]?.text }) { d.map(module: m) }
                         }, RowAction(title: tr("Quitar el mapeo manual"), destructive: true) { row in
                             if let m = d.manualMappings.first(where: { $0.id.uuidString == row["path"]?.text }) { d.removeMapping(m) }
                         }])
            HStack {
                Button(tr("Añadir un mapeo manual…")) { requestMapping() }
                Text(tr("Para memoria que no es un módulo (código descifrado, una sección movida): une un rango del proceso con uno del programa."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .controlSize(.small).padding(6)
        }
    }

    private func value(_ text: String) -> UInt64? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return UInt64(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16)
    }

    private func requestMapping() {
        model.formRequest = FormRequest(
            title: tr("Mapeo manual"),
            fields: [FormField(key: "name", title: tr("Nombre"), value: tr("Mapeo"), mono: false),
                     FormField(key: "dynamic", title: tr("Dirección en el proceso"), value: d.pc.map { "0x" + String($0, radix: 16) } ?? ""),
                     FormField(key: "static", title: tr("Dirección en el programa"), value: model.editTarget ?? ""),
                     FormField(key: "length", title: tr("Tamaño en bytes (hex)"), value: "0x1000")],
            actionTitle: tr("Añadir"), origin: "debugger") { values in
                guard let dynamic = value(values["dynamic"] ?? ""), let staticBase = value(values["static"] ?? ""),
                      let length = value(values["length"] ?? ""), length > 0 else {
                    throw EngineError.remote(tr("Escribe las direcciones y el tamaño en hexadecimal."))
                }
                d.addMapping(name: values["name"] ?? "", dynamicBase: dynamic, staticBase: staticBase, length: length)
            }
    }

    // MARK: objects

    private struct ObjectNode: Identifiable {
        let id: String
        let title: String
        var detail = ""
        var children: [ObjectNode]? = nil
        var address: String? = nil
    }

    private var objectTree: [ObjectNode] {
        let threads = d.threads.map { t in
            ObjectNode(id: "t\(t.id)", title: tr("Hilo %@", "\(t.id)"), detail: t.name,
                       children: t.id == d.currentThread ? d.frames.enumerated().map { i, f in
                           ObjectNode(id: "t\(t.id)f\(i)", title: "#\(i) \(f.name)", detail: d.hex(f.pc), address: f.staticAddress)
                       } : nil)
        }
        let registers = d.registerGroups.map { g in
            ObjectNode(id: "g" + g.name, title: g.name, detail: "\(g.registers.count)",
                       children: g.registers.map { ObjectNode(id: "r" + g.name + $0.name, title: $0.name, detail: $0.value) })
        }
        let modules = d.modules.map { ObjectNode(id: "m" + $0.id, title: $0.name, detail: d.hex($0.base)) }
        let breakpoints = d.dynamicBreakpoints.keys.sorted().map { ObjectNode(id: "b" + $0, title: $0, detail: d.dynamicBreakpoints[$0] == true ? tr("activo") : tr("desactivado")) }
        let regions = d.regions.map { ObjectNode(id: "x" + ($0["start"]?.text ?? ""), title: "\($0["start"]?.text ?? "") – \($0["end"]?.text ?? "")",
                                                 detail: "\($0["perms"]?.text ?? "") \($0["name"]?.text ?? "")", address: $0["address"]?.string) }
        return [ObjectNode(id: "process", title: d.processName.isEmpty ? tr("Proceso") : d.processName, detail: d.status, children: [
            ObjectNode(id: "threads", title: tr("Hilos"), detail: "\(threads.count)", children: threads),
            ObjectNode(id: "registers", title: tr("Registros"), detail: "\(registers.count)", children: registers),
            ObjectNode(id: "modules", title: tr("Módulos"), detail: "\(modules.count)", children: modules),
            ObjectNode(id: "breakpoints", title: "Breakpoints", detail: "\(breakpoints.count)", children: breakpoints),
            ObjectNode(id: "memory", title: tr("Regiones de memoria"), detail: "\(regions.count)", children: regions),
        ])]
    }

    private var objects: some View {
        List(objectTree, children: \.children) { node in
            HStack {
                Text(node.title).font(.system(.callout, design: .monospaced)).lineLimit(1)
                Spacer()
                Text(node.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let a = node.address { model.go(a) } }
        }
    }

    // MARK: platform and unwind

    private var platform: some View {
        HSplitView {
            textPane(tr("Plataforma, destino y proceso"), d.platformText) { d.loadPlatform() }
            textPane(tr("Desenrollado de la pila en el marco actual"), d.unwindText) { d.loadUnwind() }
        }
        .task(id: "\(d.isStopped)|\(d.pc ?? 0)") {
            if d.platformText.isEmpty { d.loadPlatform() }
            d.loadUnwind()
        }
    }

    private func textPane(_ title: String, _ text: String, reload: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Button(tr("Actualizar"), action: reload).controlSize(.small)
            }
            .padding(6)
            ScrollView {
                Text(text.isEmpty ? "—" : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: Theme.background))
        }
    }

    // MARK: snapshots

    private var snapshots: some View {
        let list = d.snapshots
        return VStack(spacing: 0) {
            if list.count > 1 {
                HStack {
                    Text(tr("Instante")).font(.caption)
                    Slider(value: Binding(get: { Double(d.viewedIndex) }, set: { d.view(snapshot: Int($0.rounded())) }),
                           in: 0...Double(list.count - 1), step: 1)
                    Text("\(d.viewedIndex + 1) / \(list.count)").font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 8).padding(.top, 6)
            }
            HSplitView {
                List(list) { s in
                    HStack {
                        Text("\(s.id + 1)").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        Text(s.name ?? s.reason).lineLimit(1)
                        Spacer()
                        Text(s.pc.map(d.hex) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if compareWith == s.id { Image(systemName: "arrow.left.arrow.right").foregroundStyle(.orange) }
                    }
                    .listRowBackground(s.id == d.viewedIndex ? Color.accentColor.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { d.view(snapshot: s.id) }
                    .contextMenu {
                        Button(tr("Poner nombre…")) { rename(s) }
                        Button(tr("Comparar con este")) { compareWith = s.id }
                        Button(tr("Copiar su memoria al programa")) {
                            Task { note = tr("%@ bytes escritos en el programa", "\(await d.copyToProgram(snapshot: s))") }
                        }
                        Button(tr("Exportar como texto…")) { export(s) }
                    }
                }
                .frame(minWidth: 280)
                differences
            }
            HStack {
                Button(tr("Capturar toda la memoria escribible")) {
                    Task { note = tr("%@ bytes guardados en el instante actual", "\(await d.captureAllMemory())") }
                }
                .disabled(!d.isStopped)
                .help(tr("Lee todas las regiones con permiso de escritura (hasta 64 MB) y las guarda en el instante actual"))
                if compareWith != nil { Button(tr("Dejar de comparar")) { compareWith = nil } }
                Spacer()
            }
            .controlSize(.small).padding(6)
        }
    }

    @ViewBuilder private var differences: some View {
        let list = d.snapshots
        if let other = compareWith, list.indices.contains(other), list.indices.contains(d.viewedIndex), other != d.viewedIndex {
            let a = list[min(other, d.viewedIndex)], b = list[max(other, d.viewedIndex)]
            let rows = d.compare(a, b)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("Del instante %@ al %@: %@ diferencias", "\(a.id + 1)", "\(b.id + 1)", "\(rows.count)"))
                    .font(.caption.weight(.semibold)).padding(6)
                Table(rows) {
                    TableColumn(tr("Clase")) { Text($0.kind) }.width(70)
                    TableColumn(tr("Qué")) { Text($0.what).monospaced() }.width(min: 110, ideal: 140)
                    TableColumn(tr("Antes")) { Text($0.before).monospaced() }
                    TableColumn(tr("Después")) { Text($0.after).monospaced() }
                }
            }
            .frame(minWidth: 380)
        } else {
            Text(tr("Elige «Comparar con este» en un instante y luego pulsa otro para ver qué cambió entre los dos."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                .frame(minWidth: 380, maxHeight: .infinity)
        }
    }

    private func rename(_ s: DebugSnapshot) {
        model.formRequest = FormRequest(title: tr("Nombre del instante %@", "\(s.id + 1)"),
                                        fields: [FormField(key: "name", title: tr("Nombre"), value: s.name ?? "", mono: false)],
                                        actionTitle: tr("Guardar"), origin: "debugger") { values in
            d.rename(snapshot: s.id, values["name"] ?? "")
        }
    }

    private func export(_ s: DebugSnapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "instante-\(s.id + 1).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try d.export(snapshot: s).write(to: url, atomically: true, encoding: .utf8) } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    // MARK: traces

    private var traces: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                HStack {
                    Image(systemName: "eye")
                    Text(d.traceName.isEmpty ? tr("Sesión actual") : d.traceName)
                    Spacer()
                    Text(tr("%@ instantes", "\(d.snapshots.count)")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(d.otherTraces) { t in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(t.name)
                        Spacer()
                        Text(tr("%@ instantes", "\(t.trace.snapshots.count)")).font(.caption).foregroundStyle(.secondary)
                        Button(tr("Ver")) { d.switchTrace(to: t) }.disabled(d.phase != .replay)
                            .help(tr("Solo al recorrer una traza guardada: con un proceso vivo, en pantalla está la sesión"))
                        Button(tr("Comparar el último instante")) { compare(t) }
                        Button { d.closeOtherTrace(t) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button(tr("Abrir otra traza…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json, .data]
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try d.loadOtherTrace(from: url) } catch { model.errorMessage = error.localizedDescription }
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            .controlSize(.small).padding(6)
        }
    }

    private func compare(_ other: LoadedTrace) {
        guard let mine = d.snapshots.indices.contains(d.viewedIndex) ? d.snapshots[d.viewedIndex] : nil,
              let theirs = other.trace.snapshots.last else { return }
        let rows = d.compare(theirs, mine)
        let text = rows.prefix(400).map { "\($0.kind)\t\($0.what)\t\($0.before)\t\($0.after)" }.joined(separator: "\n")
        model.copyToPasteboard(text)
        note = tr("%@ diferencias con «%@» (copiadas)", "\(rows.count)", other.name)
    }
}

/// Which memory each instant recorded: time across, addresses down.
private struct MemoryOverTime: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.debugger
        let list = d.snapshots
        let bases = Array(Set(list.flatMap { $0.memory.map { $0.base & ~0xfff } })).sorted()
        GeometryReader { geo in
            if list.isEmpty || bases.isEmpty {
                Text(tr("Aún no hay memoria grabada.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { ctx, size in
                    let cw = max(2, (size.width - 130) / CGFloat(list.count))
                    let rh = max(3, min(18, (size.height - 10) / CGFloat(bases.count)))
                    for (r, base) in bases.enumerated() {
                        ctx.draw(Text(d.hex(base)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                                 at: CGPoint(x: 4, y: 5 + CGFloat(r) * rh + rh / 2), anchor: .leading)
                    }
                    for (c, s) in list.enumerated() {
                        for chunk in s.memory {
                            guard let r = bases.firstIndex(of: chunk.base & ~0xfff) else { continue }
                            let rect = CGRect(x: 130 + CGFloat(c) * cw, y: 5 + CGFloat(r) * rh, width: max(1, cw - 1), height: max(1, rh - 1))
                            ctx.fill(Path(rect), with: .color(c == d.viewedIndex ? .orange : .accentColor.opacity(0.7)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let cw = max(2, (geo.size.width - 130) / CGFloat(list.count))
                    let index = Int((location.x - 130) / cw)
                    if list.indices.contains(index) { d.view(snapshot: index) }
                }
            }
        }
        .background(Color(nsColor: Theme.background))
        .help(tr("Cada columna es un instante y cada fila una página de memoria grabada. Pulsa para ir a ese instante."))
    }
}

// MARK: - Breakpoint conditions

extension AppModel {
    func requestBreakpointRule(_ address: String) {
        let rule = debugger.conditions[address] ?? BreakpointRule()
        formRequest = FormRequest(
            title: tr("Breakpoint en %@", address),
            message: tr("La condición es una expresión del depurador (por ejemplo $x0 == 5). Los comandos se ejecutan al parar."),
            fields: [FormField(key: "condition", title: tr("Condición"), value: rule.condition),
                     FormField(key: "hit", title: tr("Parar a partir de la vez número"), value: rule.hitCount),
                     FormField(key: "commands", title: tr("Comandos al parar (uno por línea)"), kind: .multiline, value: rule.commands)],
            actionTitle: tr("Guardar"), origin: "debugger") { [self] values in
                var all = debugger.conditions
                all[address] = BreakpointRule(condition: values["condition"] ?? "", hitCount: values["hit"] ?? "",
                                              commands: values["commands"] ?? "")
                debugger.conditions = all
            }
    }

    /// Enables or disables every breakpoint of the program.
    func setAllBreakpoints(enabled: Bool) {
        let list = breakpoints
        Task {
            for b in list {
                _ = try? await engine.call("setBreakpoint", ["address": b.address, "state": enabled ? "enabled" : "disabled"], as: Bool.self)
            }
            bookmarks = (try? await engine.call("bookmarks")) ?? bookmarks
            await refreshUndo()
            debugger.breakpointsChanged()
        }
    }

    /// What the pop-up of the code views shows for a word while the debugger has a state.
    func debugHover(_ word: String) async -> (String, [String])? {
        guard debugger.hasState, debugger.mappedSession == activeSession, let value = await debugger.hoverValue(word) else { return nil }
        return (word, [value])
    }
}
