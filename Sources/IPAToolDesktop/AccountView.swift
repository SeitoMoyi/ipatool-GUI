import AppKit
import SwiftUI

@MainActor @Observable
final class AppleAccount {
    let tool: IPATool
    private(set) var email: String?
    private(set) var error: String?
    private(set) var busy = false

    init(tool: IPATool) {
        self.tool = tool
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await readAccount()
    }

    private func readAccount() async {
        error = nil
        do {
            email = try await tool.accountEmail()
        } catch {
            let message = error.localizedDescription
            if message.contains("failed to get account") {
                email = nil
            } else {
                self.error = message
            }
        }
    }

    func launchSignIn() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let workspace = NSWorkspace.shared
            guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw IPATool.CommandError("Terminal could not be found.")
            }
            let launcher = try tool.makeLoginLauncher()
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await workspace.open([launcher], withApplicationAt: terminal, configuration: configuration)
            } catch {
                try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent())
                throw error
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await tool.signOut()
            email = nil
        } catch {
            let message = error.localizedDescription
            await readAccount()
            self.error = message
        }
    }
}

struct AccountView: View {
    let account: AppleAccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Apple Account", systemImage: "person.crop.circle")
                .font(.title2.weight(.semibold))
            if account.busy {
                ProgressView().controlSize(.small)
            } else if let email = account.email {
                Text("Signed in as \(email)").foregroundStyle(.secondary)
            } else if account.error == nil {
                Text("No Apple Account session found.").foregroundStyle(.secondary)
            }
            if let error = account.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            if account.email == nil {
                Text("Enter your Apple Account credentials and any verification code in Terminal, then return to ipatool.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if account.email == nil {
                    Button("Sign In with Terminal", systemImage: "terminal") {
                        Task { await account.launchSignIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check Sign-In") { Task { await account.refresh() } }
                } else {
                    Button("Sign Out") { Task { await account.signOut() } }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(account.busy)
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(account.busy)
    }
}
