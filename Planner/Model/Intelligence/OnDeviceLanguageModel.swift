import Foundation
import FoundationModels

/// Whether Apple's on-device language model can answer right now, in Planner's
/// own vocabulary so nothing outside this file imports FoundationModels.
///
/// The system reports three reasons for "no": the Mac is not eligible for
/// Apple Intelligence, it is eligible but the feature is off in System
/// Settings, or the model assets are still downloading. Each wants a different
/// sentence, so they are kept apart rather than collapsed into a Bool.
nonisolated enum OnDeviceModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// A reason this build does not know about. Treated as "not now".
    case unavailable

    var isAvailable: Bool { self == .available }

    var userDescription: String {
        switch self {
        case .available: return "Apple Intelligence is available."
        case .deviceNotEligible: return "This Mac doesn’t support Apple Intelligence."
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
        case .modelNotReady: return "Apple Intelligence is still downloading its model."
        case .unavailable: return "Apple Intelligence isn’t available right now."
        }
    }
}

/// One question for the model: standing instructions, the prompt itself, and
/// the two generation knobs every caller ends up wanting.
///
/// Every feature that uses the model — mail summaries first — builds one of
/// these rather than talking to a `LanguageModelSession` directly, so the
/// framework is behind one seam and tests can stand in a stub.
nonisolated struct OnDeviceModelRequest: Hashable, Sendable {
    var instructions: String
    var prompt: String
    /// A cap on the reply. A summary wants a sentence; without a cap the model
    /// is free to write a page, and the caller pays for it in latency.
    var maximumResponseTokens: Int?
    /// Lower is more deterministic. Summaries want to be boring.
    var temperature: Double?

    init(
        instructions: String,
        prompt: String,
        maximumResponseTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.instructions = instructions
        self.prompt = prompt
        self.maximumResponseTokens = maximumResponseTokens
        self.temperature = temperature
    }
}

/// The failures a caller can do something about. Everything else lands in
/// `.failed` with the framework's own description for the log.
nonisolated enum OnDeviceModelError: LocalizedError, Equatable {
    case unavailable(OnDeviceModelAvailability)
    /// The prompt does not fit the model's context window. The caller can
    /// retry with less of it.
    case promptTooLong
    /// The model declined — a guardrail on the input or the output. Not
    /// retryable: the same content gets the same answer.
    case refused
    /// Too many requests in a short span. Retryable later.
    case rateLimited
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason.userDescription
        case .promptTooLong: return "The message is too long to summarize."
        case .refused: return "Apple Intelligence declined to summarize this message."
        case .rateLimited: return "Apple Intelligence is busy. Try again in a moment."
        case let .failed(message): return message
        }
    }
}

/// Where model answers come from.
///
/// Not `@MainActor`, for the same reason `MailSource` is not: a reply takes
/// seconds, and nothing about waiting for it belongs on the main thread. Only
/// `Sendable` values cross the boundary.
///
/// `respond` is `@concurrent` so a conforming type is always called off the
/// caller's actor. The system model does its work out of process, but prompt
/// assembly and tokenization are not free, and a stub in tests must not be
/// able to block the main actor by accident either.
nonisolated protocol OnDeviceLanguageModel: Sendable {
    var availability: OnDeviceModelAvailability { get }
    @concurrent func respond(to request: OnDeviceModelRequest) async throws -> String
}

/// Apple's on-device model, through the FoundationModels framework.
///
/// One `LanguageModelSession` per request, on purpose. A session is a
/// transcript: every exchange stays in its context window, and a session that
/// is still answering throws on a second call. Planner's uses are independent
/// one-shot questions, so a fresh session each time is both simpler and the
/// only shape that lets two features ask at once without coordinating.
nonisolated struct SystemOnDeviceLanguageModel: OnDeviceLanguageModel {
    var availability: OnDeviceModelAvailability {
        Self.availability(SystemLanguageModel.default.availability)
    }

    @concurrent func respond(to request: OnDeviceModelRequest) async throws -> String {
        let model = SystemLanguageModel.default
        let availability = Self.availability(model.availability)
        guard availability.isAvailable else { throw OnDeviceModelError.unavailable(availability) }

        let session = LanguageModelSession(model: model, instructions: request.instructions)
        var options = GenerationOptions()
        options.maximumResponseTokens = request.maximumResponseTokens
        options.temperature = request.temperature
        do {
            return try await session.respond(to: request.prompt, options: options).content
        } catch {
            throw Self.translate(error)
        }
    }

    static func availability(_ availability: SystemLanguageModel.Availability) -> OnDeviceModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unavailable
        }
    }

    /// The framework's error surface changed shape between macOS 26 and 27,
    /// and a binary built against the 27 SDK with a 26 deployment target can
    /// see either. Both are folded into the handful of cases callers act on.
    static func translate(_ error: Error) -> Error {
        if let error = error as? OnDeviceModelError { return error }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return OnDeviceModelError.promptTooLong
            case .guardrailViolation, .refusal: return OnDeviceModelError.refused
            case .rateLimited: return OnDeviceModelError.rateLimited
            case .assetsUnavailable: return OnDeviceModelError.unavailable(.modelNotReady)
            default: return OnDeviceModelError.failed(Self.describe(error))
            }
        }
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return OnDeviceModelError.promptTooLong
                case .guardrailViolation, .refusal: return OnDeviceModelError.refused
                case .rateLimited: return OnDeviceModelError.rateLimited
                default: return OnDeviceModelError.failed(Self.describe(error))
                }
            }
            if let error = error as? SystemLanguageModel.Error {
                switch error {
                case .assetsUnavailable: return OnDeviceModelError.unavailable(.modelNotReady)
                @unknown default: return OnDeviceModelError.failed(Self.describe(error))
                }
            }
        }
        return OnDeviceModelError.failed(Self.describe(error))
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The model used when there is none: tests, and any build that should never
/// touch Apple Intelligence. Reports itself unavailable and refuses every
/// request, so a feature wired to it simply never shows its output.
nonisolated struct UnavailableOnDeviceLanguageModel: OnDeviceLanguageModel {
    var availability: OnDeviceModelAvailability { .unavailable }

    @concurrent func respond(to request: OnDeviceModelRequest) async throws -> String {
        throw OnDeviceModelError.unavailable(.unavailable)
    }
}
