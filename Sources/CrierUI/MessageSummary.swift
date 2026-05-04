import AppKit
import CrierEmitCore
import FoundationModels
import SwiftUI

// On-device summarization of long assistant turns via Apple's
// FoundationModels (macOS 26+, Apple Intelligence-enabled hardware).
// Older systems or machines without Apple Intelligence return
// `.unavailable` and the UI silently hides the affordance — no chip,
// no error. Threshold + gating logic lives in CrierEmitCore so it
// stays unit-testable.

enum SummaryService {
    static var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Asks the on-device model for a tight summary. Errors and
    /// model-unavailable both surface as `nil` so the caller can
    /// just keep showing the original message.
    static func summarize(_ text: String) async -> String? {
        guard modelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        You summarize assistant replies for a developer overlay. Keep it
        to 2-4 short bullet points, plain text, no markdown headings.
        Focus on the concrete actions, decisions, and outcomes — drop
        pleasantries, acknowledgements, and meta commentary.
        """)
        do {
            let response = try await session.respond(to: text)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

/// Wraps the existing `MessageCard` and adds a "Summarize" chip when
/// the message is long *and* on-device summarization is available.
/// Summary is generated lazily (only when the chip is tapped) and
/// kept in @State, so dismissing/reopening the panel re-runs it; we
/// don't bother persisting across runs because the input is already
/// reproducible from the transcript.
struct MessageWithOptionalSummary: View {
    let text: String

    @State private var summary: String?
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageCard(text: text)

            if shouldOfferSummary {
                summaryControls
            }

            if let s = summary, !s.isEmpty {
                MessageCard(text: s)
                    .overlay(alignment: .topLeading) {
                        Text("Summary")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tertiary, in: Capsule())
                            .padding(8)
                    }
            }
        }
    }

    private var shouldOfferSummary: Bool {
        CrierEmitCore.shouldOfferSummary(
            textLength: text.count,
            modelAvailable: SummaryService.modelAvailable
        )
    }

    @ViewBuilder
    private var summaryControls: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if summary == nil {
                Button {
                    Task { await runSummary() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Summarize")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    summary = nil
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Hide summary")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @MainActor
    private func runSummary() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await SummaryService.summarize(text)
        summary = result ?? ""  // empty string flags "we tried, failed"
    }
}
