import SwiftUI
import CoreModels
import DesignSystem

@MainActor
@Observable
final class CoachModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isSending = false
    var error: String?
    let conversationId = UUID().uuidString.lowercased()

    func send(_ text: String, env: AppEnvironment) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        input = ""
        isSending = true
        defer { isSending = false }
        do {
            let reply = try await env.coach.ask(trimmed, conversationId: conversationId)
            messages.append(ChatMessage(role: .assistant, text: reply.reply, citations: reply.citations))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// AI Coach chat grounded in the user's data. A non-diagnostic disclaimer is always visible.
struct CoachView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = CoachModel()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                disclaimer
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.m) {
                            if model.messages.isEmpty { suggestions }
                            ForEach(model.messages) { m in
                                MessageBubble(message: m).id(m.id)
                            }
                            if model.isSending {
                                HStack(spacing: 6) { ProgressView(); Text("Looking at your data…").font(.subheadline).foregroundStyle(.secondary) }
                                    .id("typing")
                            }
                            if let e = model.error {
                                InfoBanner(message: e, systemImage: "exclamationmark.triangle", tint: .train)
                            }
                        }
                        .padding(Spacing.l)
                    }
                    .onChange(of: model.messages.count) { _, _ in
                        if let id = model.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                inputBar
            }
            .background(Color.surface)
            .navigationTitle("Coach")
            .toolbar {
                if !model.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat", systemImage: "square.and.pencil") { model = CoachModel() }
                    }
                }
            }
        }
    }

    private var disclaimer: some View {
        Label {
            Text("General wellness information, not medical advice or diagnosis.")
        } icon: {
            Image(systemName: "stethoscope")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .accessibilityLabel(CoachCopy.disclaimer)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Ask about your food, training, sleep and recovery").font(.headline)
            ForEach(CoachCopy.suggestedQuestions, id: \.self) { q in
                Button {
                    Task { await model.send(q, env: env) }
                } label: {
                    HStack {
                        Text(q).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                    .padding(Spacing.m)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text(CoachCopy.disclaimer).font(.caption).foregroundStyle(.secondary).padding(.top, Spacing.s)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Spacing.s) {
            TextField("Ask your coach…", text: $model.input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, Spacing.m).padding(.vertical, 10)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .submitLabel(.send)
                .onSubmit { Task { await model.send(model.input, env: env) } }
            Button {
                Task { await model.send(model.input, env: env) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isSending)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text).font(.body).textSelection(.enabled)
                if !message.citations.isEmpty {
                    Text("Based on: " + message.citations.map { c in
                        [c.metric, [c.from?.iso, c.to?.iso].compactMap { $0 }.joined(separator: "→")].filter { !$0.isEmpty }.joined(separator: " ")
                    }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.m)
            .background(message.role == .user ? Color.recover.opacity(0.18) : Color.card,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .user ? "You: \(message.text)" : "Coach: \(message.text)")
    }
}
