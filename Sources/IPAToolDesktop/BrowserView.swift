import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct IPAToolDesktopApp: App {
    var body: some Scene {
        Window("ipatool", id: "browser") {
            BrowserView()
                .frame(minWidth: 740, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 650)
    }
}

struct BrowserView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("storefront") private var savedCountry = StorefrontPicker.defaultCountry
    @AppStorage("platform") private var platform = StorePlatform.iphone
    @State private var term = ""
    @State private var results: [StoreApp] = []
    @State private var selectedID: StoreApp.ID?
    @State private var searched = false
    @State private var history: VersionHistory?
    @State private var versionID = ""
    @State private var metadata: [String: VersionMetadata] = [:]
    @State private var versionCache: [VersionCacheKey: [String: VersionMetadata]] = [:]
    @State private var loadedVersionCount = 0
    @State private var activity: String?
    @State private var error: String?
    @State private var downloadedFile: URL?
    @State private var showingAccount = false
    @State private var account = AppleAccount(tool: IPATool())
    @State private var backendReady = false
    @State private var installingBackend = false
    @State private var backendError: String?
    @FocusState private var searchFocused: Bool

    private var tool: IPATool { account.tool }
    private let versionBatchSize = 10
    private var busy: Bool { activity != nil }
    private var country: String { StorefrontPicker.supportedCountry(savedCountry, fallback: StorefrontPicker.defaultCountry) }
    private var selectedApp: StoreApp? { results.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HSplitView {
                    VStack(spacing: 0) {
                        searchBar
                        Divider()
                        resultList
                    }
                        .frame(minWidth: 260, idealWidth: 330)
                        .frame(height: geometry.size.height)
                    VStack(spacing: 0) {
                        searchFilters
                        Divider()
                        detailPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                        .frame(minWidth: 420, maxWidth: .infinity)
                        .frame(height: geometry.size.height)
                }
            }
            if installingBackend || backendError != nil || activity != nil || error != nil || downloadedFile != nil {
                Divider()
                statusBar
            }
        }
        .toolbar {
            Button {
                showingAccount = true
                if account.email == nil { Task { await account.launchSignIn() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                    Text(account.email ?? "Sign In")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(account.email ?? "Apple Account")
            .accessibilityLabel(account.email.map { "Apple Account, signed in as \($0)" } ?? "Apple Account, sign in")
            .disabled(busy || account.busy || !backendReady)
        }
        .sheet(isPresented: $showingAccount) { AccountView(account: account) }
        .task { await setupBackend() }
        .task(id: scenePhase) {
            if scenePhase == .active, backendReady { await account.refresh() }
        }
        .onChange(of: account.email) { oldEmail, _ in
            versionCache.removeAll()
            if oldEmail != nil { resetDetail() }
        }
        .onChange(of: country) { searchScopeChanged() }
        .onChange(of: platform) { searchScopeChanged() }
        .onChange(of: selectedID) { if selectedID != nil { resetDetail() } }
        .onChange(of: versionID) { downloadedFile = nil; error = nil }
        .defaultFocus($searchFocused, true)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by app name", text: $term)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(search)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Button("Search", action: search)
                .buttonStyle(.borderedProminent)
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .disabled(busy)
    }

    private var searchFilters: some View {
        HStack(spacing: 16) {
            StorefrontPicker(country: Binding(get: { country }, set: { savedCountry = $0 }))
            Picker("Platform", selection: $platform) {
                ForEach(StorePlatform.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .disabled(busy)
    }

    private var resultList: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView(
                    searched ? "No apps found" : "Find an app",
                    systemImage: "magnifyingglass",
                    description: Text(searched ? "Try a different name, storefront, or platform." : "Enter an app name to search the selected App Store.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, selection: $selectedID) { app in
                    HStack(spacing: 10) {
                        AppArtwork(url: app.artworkURL, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName).fontWeight(.medium).lineLimit(1)
                            if !app.bundleID.isEmpty {
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(app.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .disabled(busy)
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let app = selectedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        AppArtwork(url: app.artworkURL, size: 70)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.displayName).font(.title2.weight(.semibold))
                            Text(app.bundleID.isEmpty ? "App ID \(app.id)" : app.bundleID)
                                .font(.callout.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if !app.version.isEmpty {
                                Text("Current in \(StorefrontPicker.name(country)) · \(app.version)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    versionsSection(for: app)
                        .disabled(!backendReady)
                    if let downloadedFile {
                        Button("Show Download in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([downloadedFile])
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(busy)
        } else {
            ContentUnavailableView("Select an app", systemImage: "shippingbox",
                                   description: Text("Choose a search result to browse versions and download a package."))
        }
    }

    private func versionsSection(for app: StoreApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Versions").font(.headline)
            Text("Versions and downloads use your Apple Account’s storefront and require an app license.")
                .font(.callout).foregroundStyle(.secondary)

            if let history {
                let previous = history.previousVersions
                let visible = Array(previous.prefix(loadedVersionCount))
                let latestNumber = history.latestExternalVersionID.flatMap { metadata[$0]?.displayVersion } ?? ""
                Picker("Version", selection: $versionID) {
                    Text(latestNumber.isEmpty ? "Latest available" : "\(latestNumber) (Latest)").tag("")
                    if !visible.isEmpty {
                        Section(history.latestExternalVersionID == nil ? "Available builds" : "Previous versions") {
                            ForEach(Array(visible.enumerated()), id: \.element) { index, id in
                                Text(versionTitle(id, position: index + 1, among: visible)).tag(id)
                            }
                        }
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
                if previous.isEmpty {
                    Text("No previous versions are available.").font(.callout).foregroundStyle(.secondary)
                }
                if let id = versionID.isEmpty ? history.latestExternalVersionID : versionID,
                   let date = metadata[id]?.releaseDate {
                    Text("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    if visible.count < previous.count {
                        Button("Load Older Versions") {
                            perform("Loading older versions…") {
                                await loadVersionNumbers(for: app, history: history, startingAt: visible.count,
                                                         through: visible.count + versionBatchSize)
                            }
                        }
                    }
                    Button("Refresh Versions") { loadVersions(for: app) }
                }
                .buttonStyle(.link)
            } else {
                Button("Load Version History", systemImage: "clock.arrow.circlepath") { loadVersions(for: app) }
            }

            Button(versionID.isEmpty ? "Download Latest…" : "Download Selected Version…", systemImage: "arrow.down.circle") {
                chooseDownloadLocation(for: app)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 5)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let activity {
                ProgressView().controlSize(.small)
                Text(activity)
            } else if let error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).textSelection(.enabled)
            } else if downloadedFile != nil {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("Download complete")
            }
            if installingBackend {
                ProgressView().controlSize(.small)
                Text("Installing the official ipatool backend…")
            } else if let backendError {
                Text(backendError).textSelection(.enabled)
                Button("Retry Install") { Task { await setupBackend() } }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private func searchScopeChanged() {
        results = []
        selectedID = nil
        searched = false
        resetDetail()
        search()
    }

    private func setupBackend() async {
        guard !installingBackend, !backendReady else { return }
        installingBackend = true
        backendError = nil
        defer { installingBackend = false }
        do {
            try await BackendInstaller().install()
            backendReady = true
            installingBackend = false
            await account.refresh()
        } catch {
            backendError = "Could not install ipatool. \(error.localizedDescription)"
        }
    }

    private func resetDetail() {
        history = nil
        versionID = ""
        metadata = [:]
        loadedVersionCount = 0
        downloadedFile = nil
        error = nil
    }

    private func search() {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !busy else { return }
        resetDetail()
        results = []
        selectedID = nil
        searched = false
        perform("Searching \(StorefrontPicker.name(country))…") {
            results = try await StoreCatalog().search(term: query, country: country, platform: platform)
            searched = true
        }
    }

    private func loadVersions(for app: StoreApp) {
        perform("Loading version history…") {
            let updated = try await tool.versions(app: app, platform: platform)
            history = updated
            let previous = updated.previousVersions
            let selectedPosition = previous.firstIndex(of: versionID).map { $0 + 1 } ?? 0
            if selectedPosition == 0 { versionID = "" }
            await loadVersionNumbers(for: app, history: updated,
                                     through: max(versionBatchSize, loadedVersionCount, selectedPosition))
        }
    }

    private func loadVersionNumbers(for app: StoreApp, history: VersionHistory, startingAt start: Int = 0,
                                    through count: Int) async {
        let cacheKey = VersionCacheKey(appID: app.id, platform: platform)
        metadata = versionCache[cacheKey] ?? [:]
        let visible = history.previousVersions.prefix(count)
        let latest = start == 0 ? [history.latestExternalVersionID].compactMap { $0 } : []
        let missing = (latest + visible.dropFirst(start)).filter { !$0.isEmpty && metadata[$0] == nil }
        loadedVersionCount = visible.count
        if !missing.isEmpty {
            activity = "Looking up \(missing.count) version numbers…"
            let email = account.email
            let found = await tool.metadata(app: app, platform: platform, versionIDs: missing)
            guard account.email == email else { return }
            metadata.merge(found) { _, updated in updated }
            versionCache[cacheKey] = metadata
        }
    }

    private struct VersionCacheKey: Hashable {
        let appID: Int64
        let platform: StorePlatform
    }

    private func versionTitle(_ id: String, position: Int, among versions: [String]) -> String {
        guard let details = metadata[id], !details.displayVersion.isEmpty else {
            return "Version number unavailable (release \(position))"
        }
        let label = details.displayVersion
        let matching = versions.filter { metadata[$0]?.displayVersion == label }
        guard matching.count > 1 else { return label }
        if let date = details.releaseDate?.formatted(date: .abbreviated, time: .omitted),
           !matching.contains(where: { $0 != id && metadata[$0]?.releaseDate?.formatted(date: .abbreviated, time: .omitted) == date }) {
            return "\(label) · \(date)"
        }
        return "\(label) (release \(position))"
    }

    private func chooseDownloadLocation(for app: StoreApp) {
        let panel = NSSavePanel()
        let fileType = UTType(filenameExtension: platform.packageExtension) ?? .data
        panel.allowedContentTypes = [fileType]
        panel.canCreateDirectories = true
        let name = app.bundleID.isEmpty ? String(app.id) : app.bundleID
        let suffix = metadata[versionID]?.displayVersion
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") ?? ""
        panel.nameFieldStringValue = "\(name)\(suffix.isEmpty ? "" : "-\(suffix)").\(platform.packageExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform("Downloading \(app.displayName)…") {
            downloadedFile = try await tool.download(app: app, platform: platform,
                                                     versionID: versionID.isEmpty ? nil : versionID,
                                                     destination: destination)
        }
    }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        activity = message
        error = nil
        Task {
            defer { activity = nil }
            do {
                try await action()
            } catch {
                let message = error.localizedDescription
                if message.contains("failed to get account") || message.contains("2FA code is required") {
                    self.error = "\(message) Open Apple Account for sign-in instructions."
                } else if message.contains("license is required") {
                    self.error = "This app requires a license. Get it with your Apple Account in the App Store, then retry."
                } else {
                    self.error = message
                }
            }
        }
    }
}

private struct AppArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url?.scheme == "https" ? url : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22).fill(.quaternary)
                    Image(systemName: "app.dashed").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}
