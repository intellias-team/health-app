import SwiftUI
import Speech
import AVFoundation
import CoreModels
import NutritionKit
import DesignSystem

/// On-device speech transcription (Speech framework) for voice logging.
@MainActor
@Observable
final class SpeechTranscriber {
    var transcript = ""
    var isRecording = false
    var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func requestPermissions() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { error = "Allow Speech Recognition in Settings to log by voice."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { error = "Allow microphone access in Settings to log by voice."; return false }
        return true
    }

    func start() async {
        guard !isRecording else { return }
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available right now."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            request.taskHint = .dictation
            request.contextualStrings = ["grams", "cup", "tablespoon", "slice", "chicken breast", "oat milk", "Greek yogurt"]
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            Self.installTap(on: input, format: format, request: request)
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            transcript = ""
            error = nil

            task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    /// Audio-thread callbacks are created outside the main actor on purpose.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func startTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }

    func stop() {
        guard isRecording || task != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Say (or type) what you ate → `/v1/ai/voice-parse` → confirm items (estimates).
struct VoiceLogView: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void

    @State private var speech = SpeechTranscriber()
    @State private var typed = ""
    @State private var isParsing = false
    @State private var error: String?
    @State private var draft: MealDraft?

    private var text: String { speech.transcript.isEmpty ? typed : speech.transcript }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: 0)
            Text(speech.isRecording ? "Listening…" : "Describe your meal")
                .font(.title3.weight(.semibold))
            Text("For example: “Two scrambled eggs, a slice of whole wheat toast and a latte”")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            Button {
                Task {
                    if speech.isRecording { speech.stop() } else { Haptics.selection(); await speech.start() }
                }
            } label: {
                Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(speech.isRecording ? Color.train : Color.fuel, in: Circle())
                    .shadow(color: (speech.isRecording ? Color.train : Color.fuel).opacity(0.35), radius: 16, y: 6)
                    .symbolEffect(.pulse, isActive: speech.isRecording)
            }
            .accessibilityLabel(speech.isRecording ? "Stop recording" : "Start recording")

            Card {
                if speech.transcript.isEmpty {
                    TextField("…or type it here", text: $typed, axis: .vertical).lineLimit(2...5)
                } else {
                    Text(speech.transcript).font(.body)
                }
            }
            if let e = error ?? speech.error {
                InfoBanner(message: e, systemImage: "exclamationmark.triangle", tint: .train)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .background(Color.surface)
        .navigationTitle("Voice log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isParsing ? "Working…" : "Next") { Task { await parse() } }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isParsing)
            }
        }
        .onDisappear { speech.stop() }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, title: "Confirm items", onSaved: finish)
        }
    }

    private func parse() async {
        speech.stop()
        isParsing = true
        defer { isParsing = false }
        do {
            let items = try await env.recognition.parseVoice(transcript: text, category: context.category)
            guard !items.isEmpty else { error = "Couldn't find foods in that description. Try naming each food."; return }
            draft = MealDraft(date: context.date, category: context.category, source: .voice,
                              items: items.map(DraftItem.init(analyzed:)), notes: text)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
