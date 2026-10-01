import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .welcome:
                WelcomeView()
            case .loading(let message, let progress):
                LoadingView(message: message, progress: progress)
            case .open:
                MainView()
            case .classic(let gpr):
                ClassicHandoffView(gpr: gpr)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $model.importRequest) { request in ImportSheet(request: request) }
        .sheet(item: $model.editRequest) { request in EditSheet(request: request) }
        .alert("Ghidra Studio", isPresented: Binding(get: { model.errorMessage != nil },
                                                     set: { if !$0 { model.errorMessage = nil } })) {
            Button(tr("Aceptar"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 136, height: 136)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                VStack(spacing: 6) {
                    Text("Ghidra Studio")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(tr("Ingeniería inversa con el motor de Ghidra"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if model.engineReady {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(model.engineStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                VStack(spacing: 10) {
                    Button {
                        model.presentOpenPanel()
                    } label: {
                        Label(tr("Importar binario…"), systemImage: "doc.viewfinder")
                            .frame(width: 230)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    HStack(spacing: 10) {
                        Button { model.presentNewProject() } label: {
                            Label(tr("Nuevo proyecto"), systemImage: "plus.rectangle.on.folder")
                                .frame(width: 140)
                                .padding(.vertical, 4)
                        }
                        Button { model.presentOpenProject() } label: {
                            Label(tr("Abrir proyecto"), systemImage: "folder")
                                .frame(width: 140)
                                .padding(.vertical, 4)
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)

                    Button {
                        model.launchClassic()
                    } label: {
                        Label(tr("Abrir Ghidra clásico"), systemImage: "macwindow")
                    }
                    .buttonStyle(.link)
                    .padding(.top, 4)
                }
                .padding(.top, 14)
                Spacer()
                Text(tr("También puedes arrastrar un ejecutable a esta ventana"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity)

            WelcomeSidePanel()
                .frame(width: 360)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

struct RecentsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.recents.isEmpty {
                ContentUnavailableView(tr("Sin archivos recientes"), systemImage: "clock",
                                       description: Text(tr("Los binarios que analices aparecerán aquí.")))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.recents, id: \.self) { path in
                    Button {
                        model.open(URL(fileURLWithPath: path))
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(tr("Mostrar en Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        Button(tr("Quitar de la lista")) { model.recents.removeAll { $0 == path } }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Loading

struct LoadingView: View {
    @Environment(AppModel.self) private var model
    let message: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .symbolEffect(.pulse)
            VStack(spacing: 6) {
                Text(model.program?.name ?? tr("Analizando"))
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 420)
                    .contentTransition(.opacity)
            }
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(width: 360)
            Text(tr("El análisis completo continuará en segundo plano mientras exploras el código."))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

// MARK: - Welcome side panel

struct WelcomeSidePanel: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(tr("Proyecto")).tag(0)
                Text(tr("Recientes")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            if tab == 0 {
                ProjectTreeView()
                if !model.recentProjects.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Proyectos recientes")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.recentProjects.prefix(4), id: \.self) { gpr in
                            Button {
                                model.openProject(gpr)
                            } label: {
                                Label(((gpr as NSString).lastPathComponent as NSString).deletingPathExtension,
                                      systemImage: "shippingbox")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help(gpr)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else {
                RecentsPanel()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

// MARK: - Classic hand-off

struct ClassicHandoffView: View {
    @Environment(AppModel.self) private var model
    let gpr: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text(tr("Proyecto abierto en Ghidra clásico"))
                .font(.title.weight(.semibold))
            Text(tr("«%@» está en uso en el Ghidra clásico.\nCuando termines (depurador, emulador, Version Tracking…), cierra el clásico y vuelve aquí.", "\(((gpr as NSString).lastPathComponent as NSString).deletingPathExtension)"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                model.openProject(gpr)
            } label: {
                Label(tr("Volver a abrir en Ghidra Studio"), systemImage: "arrow.uturn.backward")
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
