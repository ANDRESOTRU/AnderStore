import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct AnderCertificateInfo: Identifiable {
    let name: String
    let serialNumber: String
    let creationDate: Date?
    let expiryDate: Date?
    let isActive: Bool
    let hasPrivateKey: Bool
    let isLocal: Bool
    let isPortal: Bool
    var id: String { serialNumber }
}

struct AnderAppIDInfo: Identifiable {
    let name: String
    let identifier: String
    let bundleIdentifier: String
    let expirationDate: Date?
    var id: String { identifier }
}

struct AnderProfileInfo: Identifiable {
    let name: String
    let uuid: String
    let identifier: String?
    let bundleIdentifier: String?
    var id: String { uuid }
}

@MainActor
final class AnderDeviceManagementModel: ObservableObject {
    static let shared = AnderDeviceManagementModel()

    @Published private(set) var certificates: [AnderCertificateInfo] = []
    @Published private(set) var appIDs: [AnderAppIDInfo] = []
    @Published private(set) var profiles: [AnderProfileInfo] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var portalSessionState: AnderPortalSessionState = .unknown
    @Published var showingReauthentication = false

    private init() {}

    func loadCertificates() {
        run("certificates.list") { [weak self] payload in
            let rows = payload?["certificates"] as? [[String: Any]] ?? []
            self?.certificates = rows.compactMap { row in
                guard let name = row["name"] as? String,
                      let serial = row["serialNumber"] as? String else { return nil }
                return AnderCertificateInfo(name: name,
                                            serialNumber: serial,
                                            creationDate: row["creationDate"] as? Date,
                                            expiryDate: row["expiryDate"] as? Date,
                                            isActive: row["isActive"] as? Bool ?? false,
                                            hasPrivateKey: row["hasPrivateKey"] as? Bool ?? false,
                                            isLocal: row["isLocal"] as? Bool ?? false,
                                            isPortal: row["isPortal"] as? Bool ?? false)
            }
            if let failure = payload?["portalFailure"] as? [String: Any] {
                self?.handlePortalFailure(AnderCoreFailure(payload: failure))
            } else {
                self?.portalSessionState = .ready
            }
        }
    }

    func revoke(_ certificate: AnderCertificateInfo) {
        run("certificates.revoke", params: ["serialNumber": certificate.serialNumber]) { [weak self] _ in
            if certificate.isActive {
                let defaults = LCUtils.appGroupUserDefault
                defaults.removeObject(forKey: "LCCertificateData")
                defaults.removeObject(forKey: "LCCertificatePassword")
                defaults.removeObject(forKey: "LCCertificateUpdateDate")
                defaults.removeObject(forKey: "anderCertificateSerial")
                defaults.removeObject(forKey: "anderCertificateSHA256")
                defaults.removeObject(forKey: "anderLastCertificateSync")
                AnderState.shared.certificateDidChange()
            }
            self?.loadCertificates()
            AnderState.shared.invalidate()
        }
    }

    func importP12(data: Data, password: String) {
        var params: [String: Any] = ["data": data.base64EncodedString()]
        if !password.isEmpty { params["password"] = password }
        run("certificates.importP12", params: params) { [weak self] _ in
            AnderState.shared.synchronizeCertificate(force: true) { _ in
                self?.loadCertificates()
            }
        }
    }

    func exportP12(_ certificate: AnderCertificateInfo,
                   password: String,
                   completion: @escaping (Data?, String?) -> Void) {
        run("certificates.exportP12",
            params: ["serialNumber": certificate.serialNumber, "password": password]) { payload in
            let data = (payload?["data"] as? String).flatMap { Data(base64Encoded: $0) }
            completion(data, payload?["filename"] as? String)
        }
    }

    func loadAppIDs() {
        run("appIDs.list") { [weak self] payload in
            let rows = payload?["appIDs"] as? [[String: Any]] ?? []
            self?.appIDs = rows.compactMap { row in
                guard let name = row["name"] as? String,
                      let identifier = row["identifier"] as? String,
                      let bundleIdentifier = row["bundleIdentifier"] as? String else { return nil }
                return AnderAppIDInfo(name: name,
                                      identifier: identifier,
                                      bundleIdentifier: bundleIdentifier,
                                      expirationDate: row["expirationDate"] as? Date)
            }
        }
    }

    func delete(_ appID: AnderAppIDInfo) {
        run("appIDs.delete", params: ["identifier": appID.identifier]) { [weak self] _ in
            self?.loadAppIDs()
        }
    }

    func loadProfiles() {
        run("profiles.list") { [weak self] payload in
            let rows = payload?["profiles"] as? [[String: Any]] ?? []
            self?.profiles = rows.compactMap { row in
                guard let name = row["name"] as? String,
                      let uuid = row["uuid"] as? String else { return nil }
                return AnderProfileInfo(name: name,
                                        uuid: uuid,
                                        identifier: row["identifier"] as? String,
                                        bundleIdentifier: row["bundleIdentifier"] as? String)
            }
        }
    }

    func signOut() {
        run("account.signOut", params: ["keepCertificate": true]) { _ in
            UserDefaults.standard.removeObject(forKey: "anderAppleID")
            AnderState.shared.clearAccountAfterSignOut()
        }
    }

    func requestReauthentication() {
        showingReauthentication = true
    }

    func didReauthenticate() {
        portalSessionState = .ready
        showingReauthentication = false
        AnderState.shared.invalidate()
    }

    private func handlePortalFailure(_ failure: AnderCoreFailure) {
        switch failure.kind {
        case "sessionExpired", "needsAuth":
            portalSessionState = .reauthRequired
            AnderState.shared.invalidate()
        case "rateLimited":
            portalSessionState = .rateLimited
            UserDefaults.standard.set(Date().timeIntervalSince1970 + 30 * 60,
                                      forKey: "anderSignInBlockedUntil")
            AnderState.shared.invalidate()
        default:
            errorMessage = AnderAccountAPI.friendly(failure)
        }
    }

    private func run(_ command: String,
                     params: [String: Any] = [:],
                     completion: @escaping ([String: Any]?) -> Void) {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let started = AnderAccountAPI.perform(command, params: params) { [weak self] response, failure in
            self?.isLoading = false
            if let failure {
                self?.handlePortalFailure(failure)
                return
            }
            self?.portalSessionState = .ready
            completion(response)
        }
        if !started {
            isLoading = false
            errorMessage = "lc.account.errorNoExtension".loc
        }
    }
}

struct AnderBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AnderPortalSessionBanner: View {
    @ObservedObject var model: AnderDeviceManagementModel

    var body: some View {
        if model.portalSessionState == .reauthRequired || model.portalSessionState == .rateLimited {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.portalSessionState == .rateLimited
                          ? "lc.account.errorRateLimited".loc
                          : "lc.account.sessionExpired".loc,
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("lc.account.signInAgain".loc) {
                        model.requestReauthentication()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct AnderReauthenticationView: View {
    private enum Phase: Equatable {
        case idle
        case signingIn
        case needsCode(String)
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("anderAppleID") private var savedAppleID = ""
    @AppStorage("anderSignInBlockedUntil") private var signInBlockedUntil = 0.0
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var message: String?
    @State private var phase: Phase = .idle
    let onSuccess: () -> Void

    private var blocked: Bool { signInBlockedUntil > Date().timeIntervalSince1970 }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("lc.account.emailPlaceholder".loc, text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("lc.account.passwordPlaceholder".loc, text: $password)
                        .textContentType(.password)
                    Button("lc.account.signInButton".loc, action: signIn)
                        .disabled(phase != .idle || email.isEmpty || password.isEmpty || blocked)
                } footer: {
                    if blocked {
                        Text("lc.account.errorRateLimited".loc).foregroundStyle(.orange)
                    } else {
                        Text("lc.account.privacy".loc)
                    }
                }

                if case .needsCode(let prompt) = phase {
                    Section("lc.account.codeTitle".loc) {
                        Text(prompt == "trustedDevice" || prompt == "sms"
                             ? "lc.account.codeDesc".loc : prompt)
                        TextField("000000", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Button("lc.account.codeConfirm".loc) {
                            phase = .signingIn
                            AnderAccountAPI.submitCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .disabled(code.count < 6)
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("lc.account.signInAgain".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        if case .needsCode = phase { AnderAccountAPI.submitCode("") }
                        dismiss()
                    }
                }
            }
            .onAppear { email = savedAppleID }
        }
    }

    private func signIn() {
        let appleID = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appleID.isEmpty, !password.isEmpty, !blocked else { return }
        message = nil
        phase = .signingIn
        let started = AnderAccountAPI.signIn(appleID: appleID, password: password, onCode: { prompt in
            code = ""
            phase = .needsCode(prompt)
        }, completion: { failure, account in
            password = ""
            phase = .idle
            if let failure {
                if failure.kind == "rateLimited" {
                    signInBlockedUntil = Date().timeIntervalSince1970 + 30 * 60
                }
                message = AnderAccountAPI.friendly(failure)
                return
            }
            signInBlockedUntil = 0
            savedAppleID = account ?? appleID
            onSuccess()
            dismiss()
        })
        if !started {
            phase = .idle
            message = "lc.account.errorNoExtension".loc
        }
    }
}

struct AnderCertificatesView: View {
    @ObservedObject private var model = AnderDeviceManagementModel.shared
    @State private var revokeTarget: AnderCertificateInfo?
    @State private var exportTarget: AnderCertificateInfo?
    @State private var password = ""
    @State private var pendingImport: Data?
    @State private var importing = false
    @State private var askingImportPassword = false
    @State private var askingExportPassword = false
    @State private var exportedDocument: AnderBinaryDocument?
    @State private var exportedFilename = "certificate.p12"

    var body: some View {
        List {
            AnderPortalSessionBanner(model: model)
            Section {
                Button("lc.certificates.import".loc) { importing = true }
            }
            ForEach(model.certificates) { certificate in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(certificate.name).font(.headline)
                        if certificate.isActive { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                        Spacer()
                    }
                    Text(certificate.serialNumber).font(.caption2).foregroundStyle(.secondary)
                    Text([certificate.isLocal ? "lc.certificates.local".loc : nil,
                          certificate.isPortal ? "lc.certificates.portal".loc : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    Label(certificate.hasPrivateKey ? "lc.certificates.privateKeyPresent".loc
                                                    : "lc.certificates.privateKeyMissing".loc,
                          systemImage: certificate.hasPrivateKey ? "key.fill" : "key.slash")
                        .font(.caption2)
                        .foregroundStyle(certificate.hasPrivateKey ? Color.green : Color.secondary)
                    if let expiry = certificate.expiryDate {
                        Text(expiry.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(expiry < Date() ? .red : .secondary)
                    }
                    HStack {
                        if certificate.hasPrivateKey {
                            Button("lc.certificates.export".loc) {
                                exportTarget = certificate
                                password = ""
                                askingExportPassword = true
                            }
                        }
                        Spacer()
                        if certificate.isPortal {
                            Button("lc.certificates.revoke".loc, role: .destructive) { revokeTarget = certificate }
                        }
                    }
                }
            }
        }
        .navigationTitle("lc.device.certificates".loc)
        .overlay { if model.isLoading { ProgressView() } }
        .refreshable { model.loadCertificates() }
        .onAppear { model.loadCertificates() }
        .sheet(isPresented: $model.showingReauthentication) {
            AnderReauthenticationView {
                model.didReauthenticate()
                model.loadCertificates()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingImport = try? Data(contentsOf: url)
            password = ""
            askingImportPassword = pendingImport != nil
        }
        .fileExporter(isPresented: Binding(get: { exportedDocument != nil },
                                           set: { if !$0 { exportedDocument = nil } }),
                      document: exportedDocument,
                      contentType: .data,
                      defaultFilename: exportedFilename) { _ in exportedDocument = nil }
        .alert("lc.certificates.revokeTitle".loc,
               isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } })) {
            Button("lc.certificates.revoke".loc, role: .destructive) {
                if let revokeTarget { model.revoke(revokeTarget) }
                revokeTarget = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) { revokeTarget = nil }
        } message: { Text("lc.certificates.revokeWarning".loc) }
        .alert("lc.certificates.importPassword".loc, isPresented: $askingImportPassword) {
            SecureField("lc.certificates.password".loc, text: $password)
            Button("lc.common.continue".loc) {
                if let pendingImport { model.importP12(data: pendingImport, password: password) }
                pendingImport = nil
                password = ""
            }
            Button("lc.common.cancel".loc, role: .cancel) { pendingImport = nil }
        }
        .alert("lc.certificates.exportPassword".loc, isPresented: $askingExportPassword) {
            SecureField("lc.certificates.password".loc, text: $password)
            Button("lc.certificates.export".loc) {
                guard let exportTarget else { return }
                guard !password.isEmpty else {
                    model.errorMessage = "lc.certificates.exportPasswordHint".loc
                    return
                }
                let exportPassword = password
                password = ""
                self.exportTarget = nil
                model.exportP12(exportTarget, password: exportPassword) { data, filename in
                    if let data {
                        exportedFilename = filename ?? "certificate.p12"
                        exportedDocument = AnderBinaryDocument(data: data)
                    }
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) { exportTarget = nil }
        } message: { Text("lc.certificates.exportPasswordHint".loc) }
        .alert("lc.common.error".loc,
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("lc.common.ok".loc) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct AnderAppIDsView: View {
    @ObservedObject private var model = AnderDeviceManagementModel.shared
    @State private var deleteTarget: AnderAppIDInfo?

    var body: some View {
        List {
            AnderPortalSessionBanner(model: model)
            ForEach(model.appIDs) { appID in
                VStack(alignment: .leading, spacing: 4) {
                    Text(appID.name).font(.headline)
                    Text(appID.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                    Text(appID.identifier).font(.caption2).foregroundStyle(.secondary)
                    if let date = appID.expirationDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption2)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { deleteTarget = appID } label: { Label("lc.common.remove".loc, systemImage: "trash") }
                }
            }
        }
        .navigationTitle("lc.device.appIDs".loc)
        .overlay { if model.isLoading { ProgressView() } }
        .onAppear { model.loadAppIDs() }
        .refreshable { model.loadAppIDs() }
        .sheet(isPresented: $model.showingReauthentication) {
            AnderReauthenticationView {
                model.didReauthenticate()
                model.loadAppIDs()
            }
        }
        .alert("lc.appIDs.deleteTitle".loc,
               isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let deleteTarget { model.delete(deleteTarget) }
                deleteTarget = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) { deleteTarget = nil }
        } message: { Text("lc.appIDs.deleteWarning".loc) }
        .alert("lc.common.error".loc,
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("lc.common.ok".loc) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct AnderProfilesView: View {
    @ObservedObject private var model = AnderDeviceManagementModel.shared
    var body: some View {
        List {
            AnderPortalSessionBanner(model: model)
            ForEach(model.profiles) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.headline)
                    Text(profile.bundleIdentifier ?? profile.identifier ?? profile.uuid)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("lc.device.profiles".loc)
        .overlay { if model.isLoading { ProgressView() } }
        .onAppear { model.loadProfiles() }
        .refreshable { model.loadProfiles() }
        .sheet(isPresented: $model.showingReauthentication) {
            AnderReauthenticationView {
                model.didReauthenticate()
                model.loadProfiles()
            }
        }
        .alert("lc.common.error".loc,
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("lc.common.ok".loc) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct AnderSetupInstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            instruction(number: 1,
                        title: "lc.setup.vpnTitle".loc,
                        text: "lc.setup.vpnText".loc,
                        icon: "shield.lefthalf.filled")
            instruction(number: 2,
                        title: "lc.setup.trustTitle".loc,
                        text: "lc.setup.trustText".loc,
                        icon: "checkmark.shield")
            instruction(number: 3,
                        title: "lc.setup.developerTitle".loc,
                        text: "lc.setup.developerText".loc,
                        icon: "hammer")
        }
        .navigationTitle("lc.setup.title".loc)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("lc.common.done".loc) { dismiss() }
            }
        }
    }

    private func instruction(number: Int, title: String, text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(AnderTheme.accent.opacity(0.16))
                Image(systemName: icon).foregroundColor(AnderTheme.accent)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number). \(title)").font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

struct AnderComponentsView: View {
    @State private var local: [String: String] = [:]
    @State private var remote: [String: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        List {
            componentRow("AnderStore", key: "anderstore")
            componentRow("Core", key: "core")
            componentRow("lc.components.engine".loc, key: "liveContainer")
            if let commit = local["commit"] {
                HStack { Text("lc.components.commit".loc); Spacer(); Text(String(commit.prefix(12))).foregroundStyle(.secondary) }
            }
            if let buildDate = local["buildDate"] {
                HStack { Text("lc.components.buildDate".loc); Spacer(); Text(buildDate).foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("lc.device.components".loc)
        .onAppear(perform: load)
        .refreshable { load() }
    }

    @ViewBuilder
    private func componentRow(_ title: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(local[key] ?? "—").foregroundStyle(.secondary)
            }
            if let latest = remote[key], latest != local[key] {
                Text(String(format: "lc.components.latest".loc, latest))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func load() {
        if let url = Bundle.main.url(forResource: "components", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            local = object
        } else {
            local = ["anderstore": AnderUpdateChecker.currentVersion]
        }

        guard let url = URL(string: "https://store.andresot.uk/updates.json") else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    errorMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let manifest = try? JSONDecoder().decode(AnderUpdatesManifest.self, from: data) else { return }
                remote = [
                    "anderstore": manifest.anderstore.version,
                    "core": manifest.core.version,
                    "liveContainer": manifest.liveContainer.version,
                ]
            }
        }.resume()
    }
}
