import SwiftUI
import CoreModels
import DesignSystem

struct AccountView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Account") {
                if let s = env.session {
                    LabeledContent("Signed in", value: s.email ?? "Apple ID (private relay)")
                    Button("Sign out") { Task { await env.signOut() } }
                } else {
                    SignInWithAppleCognitoButton()
                }
            }
            Section {
                Button(isExporting ? "Preparing export…" : "Export my data") {
                    Task {
                        isExporting = true
                        defer { isExporting = false }
                        do { exportURL = try await env.repository.exportData() } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(isExporting)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") }
                }
            } header: { Text("Your data") } footer: {
                Text("Exports include meals, body measurements, workouts, notes and settings as JSON. Links expire after 15 minutes.")
            }
            Section {
                Button("Delete account", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Permanently deletes your HealthApp account and all data on our servers (meals, photos, metrics, Oura connection). Data in Apple Health is not affected.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("Privacy") {
                Text("Your health data is encrypted on this device and on our servers, never sold, and never used for advertising. AI features receive only food photos and food-level context — never your name or Apple ID.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Account & privacy")
        .confirmationDialog("Delete your account and all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task {
                    do {
                        try await env.repository.deleteAccount()
                        await env.signOut()
                        env.hasOnboarded = false
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("This can't be undone.") }
    }
}

/// Starts Cognito Hosted UI sign-in with Sign in with Apple as the identity provider.
/// Styled after Apple's button guidelines (black, Apple logo, "Sign in with Apple").
struct SignInWithAppleCognitoButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Button {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await env.signIn() } catch { self.error = error.localizedDescription }
                }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().tint(scheme == .dark ? .black : .white) } else { Image(systemName: "applelogo") }
                    Text("Sign in with Apple").font(.system(size: 19, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .background(scheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Sign in with Apple")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
