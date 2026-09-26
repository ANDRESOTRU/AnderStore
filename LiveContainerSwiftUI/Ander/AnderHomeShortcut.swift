import Combine
import Foundation
import Network
import SafariServices
import SwiftUI

/// Serves exactly one profile on loopback. No files, external upload or LAN listener.
final class AnderShortcutServer {
    private let queue = DispatchQueue(label: "uk.andresot.shortcut")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let profile: Data
    private let path = "/\(UUID().uuidString)/AnderStoreShortcut.mobileconfig"
    private var pending: CheckedContinuation<URL, Error>?
    init(profile: Data) { self.profile = profile }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pending = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = listener.port,
                               let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)") {
                                let pending = self.pending; self.pending = nil
                                pending?.resume(returning: url)
                            }
                        case .failed(let error): self.stopOnQueue(error: error)
                        case .cancelled: self.stopOnQueue(error: CancellationError())
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        self.connections.append(connection)
                        connection.start(queue: self.queue)
                        self.read(connection, header: Data())
                        self.queue.asyncAfter(deadline: .now() + 10) { [weak connection] in connection?.cancel() }
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        if self?.pending != nil { self?.stopOnQueue(error: URLError(.timedOut)) }
                    }
                    self.queue.asyncAfter(deadline: .now() + 600) { [weak self] in self?.stopOnQueue(error: CancellationError()) }
                } catch { self.stopOnQueue(error: error) }
            }
        }
    }

    private func read(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var header = header
            if let data { header.append(data) }
            guard header.count <= 16384, error == nil else { self.close(connection); return }
            if let text = String(data: header, encoding: .utf8), text.contains("\r\n\r\n") {
                let accepted = AnderShortcutHTTP.accepts(text, path: self.path)
                let body = accepted ? self.profile : Data()
                let status = accepted ? "200 OK" : "404 Not Found"
                let fields = "HTTP/1.1 \(status)\r\nContent-Type: application/x-apple-aspen-config\r\nContent-Disposition: attachment; filename=\"AnderStoreShortcut.mobileconfig\"\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                var response = Data(fields.utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
            } else if !complete {
                self.read(connection, header: header)
            } else { self.close(connection) }
        }
    }
    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }
    func stop() { queue.async { self.stopOnQueue(error: CancellationError()) } }
    private func stopOnQueue(error: Error) {
        let pending = pending; self.pending = nil
        pending?.resume(throwing: error)
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
    }
}

@MainActor
final class AnderHomeShortcutCoordinator: ObservableObject {
    static let shared = AnderHomeShortcutCoordinator()
    @Published var app: LCAppModel?
    func show(_ app: LCAppModel) { self.app = app }
}

@MainActor
final class AnderHomeShortcutSession: ObservableObject {
    @Published var url: URL?
    @Published var loading = false
    @Published var error: String?
    @Published var downloaded = false
    private var server: AnderShortcutServer?
    private var operation: Task<Void, Never>?
    func start(_ app: LCAppModel, style: GeneratedIconStyle) {
        guard !loading else { return }
        stop()
        loading = true; error = nil
        operation = Task {
            defer { loading = false; operation = nil }
            do {
                guard let profile = app.appInfo.generateWebClipConfig(withContainerId: app.uiSelectedContainer?.folderName, iconStyle: style) else {
                    throw CocoaError(.propertyListWriteInvalid)
                }
                let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                let service = AnderShortcutServer(profile: data)
                server = service
                let address = try await service.start()
                guard !Task.isCancelled else { service.stop(); return }
                url = address
                downloaded = true // A download was offered; this does not confirm installation.
            } catch {
                if !Task.isCancelled { self.error = "lc.shortcut.failure".loc }
                server?.stop(); server = nil
            }
        }
    }
    func stop() {
        operation?.cancel()
        server?.stop(); server = nil
        url = nil
    }
}

struct AnderHomeShortcutGuide: View {
    @ObservedObject var app: LCAppModel
    @StateObject private var session = AnderHomeShortcutSession()
    @Environment(\.presentationMode) private var presentation
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkIcon = false
    @AppStorage("anderAdvancedFunctions", store: LCUtils.appGroupUserDefault) private var advanced = false
    @State private var style: GeneratedIconStyle = .Light

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        if let icon = app.appInfo.iconIsDarkIcon(darkIcon) {
                            Image(uiImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        Text(app.displayName).font(.title2.bold())
                    }
                    Text("lc.shortcut.explanation".loc)
                    ForEach(1...4, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(index)).font(.headline).frame(width: 26)
                            Text("lc.shortcut.step\(index)".loc)
                        }
                    }
                    if advanced, #available(iOS 18.0, *) {
                        Picker("lc.shortcut.iconStyle".loc, selection: $style) {
                            Text("lc.shortcut.light".loc).tag(GeneratedIconStyle.Light)
                            Text("lc.shortcut.dark".loc).tag(GeneratedIconStyle.Dark)
                        }.pickerStyle(.segmented)
                    }
                    Button {
                        session.start(app, style: style)
                    } label: {
                        HStack {
                            if session.loading { ProgressView() }
                            Text((session.downloaded ? "lc.shortcut.downloadAgain" : "lc.shortcut.begin").loc)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(session.loading)
                    if let error = session.error { Text(error).foregroundStyle(.red) }
                    Text("lc.shortcut.eightMinutes".loc).font(.callout).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("lc.appBanner.addToHomeScreen".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) { presentation.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: Binding(get: { session.url != nil }, set: { if !$0 { session.url = nil } })) {
                if let url = session.url { SafariView(url: .constant(url)) }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { style = darkIcon ? .Dark : .Light }
        .onDisappear { session.stop() }
    }
}
