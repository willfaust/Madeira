// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import FoundationModels
@testable import Triptych

// MARK: - Concrete FoundationModels & MLX Fallback Types Under Test
// Exercises the FoundationModels API surface Curator relies on.

@available(iOS 26.0, *)
enum CuratorBackendStatus: Equatable, Sendable {
    case appleFoundationModel(variantName: String, contextSize: Int, supportsVision: Bool)
    case mlxFallbackRequired(reason: String)
    case temporarilyUnavailable(reason: String)
}

@available(iOS 26.0, *)
enum CuratorAvailability {
    static func evaluate(
        availability: SystemLanguageModel.Availability,
        supportsLocale: Bool = true,
        variantName: String = "AFM 3 Core",
        contextSize: Int = 8192,
        supportsVision: Bool = true
    ) -> CuratorBackendStatus {
        switch availability {
        case .available:
            guard supportsLocale else {
                return .mlxFallbackRequired(reason: "Unsupported locale")
            }
            return .appleFoundationModel(
                variantName: variantName,
                contextSize: contextSize,
                supportsVision: supportsVision
            )
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .mlxFallbackRequired(reason: "Device is not eligible for Apple Intelligence")
            case .appleIntelligenceNotEnabled:
                return .mlxFallbackRequired(reason: "Apple Intelligence is not enabled")
            case .modelNotReady:
                return .temporarilyUnavailable(reason: "Apple Intelligence model assets are still preparing")
            @unknown default:
                return .temporarilyUnavailable(reason: "Unavailable")
            }
        }
    }
}

@available(iOS 26.0, *)
@Generable(description: "Structured diagnostic summary of a Triptych engine failure.")
struct CuratorDiagnosticAnalysis: Equatable, Sendable {
    @Guide(
        description: "Canonical log clues cited from the excerpt",
        .maximumCount(3)
    )
    var evidenceClues: [String]

    @Guide(
        description: "The Triptych subsystem most likely responsible for the symptom",
        .anyOf(["Casement", "Pane", "Atelier", "Fresco", "x86 PC", "Easel/JIT", "Unknown"])
    )
    var likelyArea: String

    @Guide(description: "Plain-language explanation in at most two short sentences")
    var summary: String

    @Guide(
        description: "Safe configuration lever to recommend, or reportOnly if a code fix is needed",
        .anyOf(["smallerCodeCache", "enableJITAtLaunch", "enablePoolSplit", "enableRealSuspend", "reportOnly"])
    )
    var recommendedLever: String

    @Guide(
        description: "Steps the provided facts explicitly state were already tried",
        .maximumCount(4)
    )
    var stepsTried: [String]
}

@available(iOS 26.0, *)
enum CuratorDynamicSchema {
    static func makeConfigPatchSchema(allowedKeys: [String]) throws -> GenerationSchema {
        let keyChoiceSchema = DynamicGenerationSchema(
            name: "AllowedConfigKey",
            description: "Allowlisted configuration key for the active Triptych engine",
            anyOf: allowedKeys
        )
        let entrySchema = DynamicGenerationSchema(
            name: "ConfigSettingEntry",
            description: "A single validated key-value override",
            properties: [
                .init(name: "key", description: "Allowlisted setting key", schema: keyChoiceSchema, isOptional: false),
                .init(name: "value", description: "New setting value", schema: .init(type: String.self), isOptional: false),
                .init(name: "reason", description: "One-sentence explanation", schema: .init(type: String.self), isOptional: false),
            ]
        )
        let rootSchema = DynamicGenerationSchema(
            name: "CuratorConfigPatch",
            description: "Proposed engine configuration overrides",
            properties: [
                .init(
                    name: "entries",
                    description: "1 to 3 configuration overrides",
                    schema: .init(arrayOf: entrySchema, minimumElements: 1, maximumElements: 3),
                    isOptional: false
                ),
                .init(
                    name: "requiresRelaunch",
                    description: "True if applying these settings requires restarting Triptych",
                    schema: .init(type: Bool.self),
                    isOptional: false
                ),
            ]
        )
        return try GenerationSchema(root: rootSchema, dependencies: [])
    }
}

@available(iOS 26.0, *)
struct StageConfigFixTool: Tool {
    let name = "stageConfigFix"
    let description = "Stages a validated configuration key=value fix for user approval."

    static let allowedKeys: Set<String> = [
        "henge.perf.codeCacheMB",
        "HV_NO_TLBI_BLOCK",
        "HV_HZ",
        "HV_WFI_SPIN",
        "pool",
        "pool-split",
        "env.MADEIRA_REAL_SUSPEND",
        "env.MADEIRA_VDCFG_PATH",
        "env.MADEIRA_X64_IMAGE_NOCOPY",
        "env.MADEIRA_WOW_RWX_PLAIN",
    ]

    @Generable
    struct Arguments: Equatable, Sendable {
        @Guide(
            description: "Allowlisted configuration key",
            .anyOf([
                "henge.perf.codeCacheMB",
                "HV_NO_TLBI_BLOCK",
                "HV_HZ",
                "HV_WFI_SPIN",
                "pool",
                "pool-split",
                "env.MADEIRA_REAL_SUSPEND",
                "env.MADEIRA_VDCFG_PATH",
                "env.MADEIRA_X64_IMAGE_NOCOPY",
                "env.MADEIRA_WOW_RWX_PLAIN",
            ])
        )
        var key: String

        @Guide(description: "Recommended value")
        var value: String
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        guard Self.allowedKeys.contains(arguments.key),
              !arguments.value.isEmpty,
              arguments.value.count <= 32,
              arguments.value.allSatisfy({ $0.isASCII && !$0.isNewline }) else {
            return "rejected: key or value outside Curator allowlist"
        }
        return "staged: \(arguments.key)=\(arguments.value)"
    }
}

enum CuratorFallbackModelChoice: String, Equatable, Sendable {
    case qwen3_0_6b_4bit = "mlx-community/Qwen3-0.6B-4bit"
    case qwen2_5_1_5b_4bit = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    case none = "none"

    var parameterCountBillions: Double {
        switch self {
        case .qwen3_0_6b_4bit: return 0.6
        case .qwen2_5_1_5b_4bit: return 1.5
        case .none: return 0.0
        }
    }

    var estimatedPeakFootprintBytes: UInt64 {
        switch self {
        case .qwen3_0_6b_4bit: return 488 * 1024 * 1024
        case .qwen2_5_1_5b_4bit: return 1050 * 1024 * 1024
        case .none: return 0
        }
    }

    var minimumAvailableMemoryBytes: UInt64 {
        switch self {
        case .qwen3_0_6b_4bit: return 900 * 1024 * 1024
        case .qwen2_5_1_5b_4bit: return 1850 * 1024 * 1024
        case .none: return 0
        }
    }

    static func select(
        availableMemoryBytes: UInt64,
        hasActiveHeavyEngine: Bool,
        prefer1_5BWhenHeadroomAllows: Bool = false
    ) -> CuratorFallbackModelChoice {
        guard !hasActiveHeavyEngine else { return .none }
        if prefer1_5BWhenHeadroomAllows,
           availableMemoryBytes >= Self.qwen2_5_1_5b_4bit.minimumAvailableMemoryBytes {
            return .qwen2_5_1_5b_4bit
        }
        if availableMemoryBytes >= Self.qwen3_0_6b_4bit.minimumAvailableMemoryBytes {
            return .qwen3_0_6b_4bit
        }
        return .none
    }
}

/// Deterministic local `LanguageModel` + `LanguageModelExecutor` implementation verifying that iOS 27's
/// `LanguageModelSession` and `DynamicProfile` drive a fallback model (such as MLX Swift) identically to `SystemLanguageModel`.
@available(iOS 27.0, *)
struct MockMLXFallbackLanguageModel: LanguageModel {
    struct Executor: LanguageModelExecutor {
        typealias Model = MockMLXFallbackLanguageModel

        struct Configuration: Hashable, Sendable {
            let modelID: String
            let cacheLimitBytes: Int
        }

        let configuration: Configuration

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        func prewarm(model: MockMLXFallbackLanguageModel, transcript: Transcript) {}

        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: MockMLXFallbackLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let jsonResponse = """
            {"evidenceClues":["[jit-pool] EXHAUSTED","status=c0000017"],"likelyArea":"Pane","summary":"The 64-bit FEX JIT code pool ran out of memory while translating the Windows game.","recommendedLever":"enablePoolSplit","stepsTried":["Launched game with default 512 MB pool"]}
            """
            await channel.send(
                .response(
                    action: .appendText(jsonResponse, tokenCount: 42)
                )
            )
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: 128, cachedTokenCount: 64),
                        output: .init(totalTokenCount: 42, reasoningTokenCount: 0)
                    )
                )
            )
        }
    }

    let choice: CuratorFallbackModelChoice
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration, .toolCalling])
    }
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(modelID: choice.rawValue, cacheLimitBytes: 20 * 1024 * 1024)
    }
}

// MARK: - Unit Tests

@available(iOS 26.0, *)
final class CuratorFoundationModelsTests: XCTestCase {

    func testAvailabilityAndVariantsOnIOS27() {
        let model = SystemLanguageModel.default
        // The iPad Simulator reports the model available but a context size of 0, so only a nonzero size is checked.
        if model.isAvailable, model.contextSize > 0 { XCTAssertGreaterThanOrEqual(model.contextSize, 4096) }

        if #available(iOS 27.0, *) {
            let core3 = SystemLanguageModel.Variant.core3
            let coreAdv = SystemLanguageModel.Variant.coreAdvanced3
            XCTAssertNotEqual(core3, coreAdv)
            XCTAssertFalse(core3.displayName.isEmpty)
            XCTAssertFalse(coreAdv.displayName.isEmpty)
        }

        XCTAssertEqual(
            CuratorAvailability.evaluate(availability: .available, variantName: "AFM 3 Core", contextSize: 8192),
            .appleFoundationModel(variantName: "AFM 3 Core", contextSize: 8192, supportsVision: true)
        )
        XCTAssertEqual(
            CuratorAvailability.evaluate(availability: .available, supportsLocale: false),
            .mlxFallbackRequired(reason: "Unsupported locale")
        )
        XCTAssertEqual(
            CuratorAvailability.evaluate(availability: .unavailable(.deviceNotEligible)),
            .mlxFallbackRequired(reason: "Device is not eligible for Apple Intelligence")
        )
        XCTAssertEqual(
            CuratorAvailability.evaluate(availability: .unavailable(.appleIntelligenceNotEnabled)),
            .mlxFallbackRequired(reason: "Apple Intelligence is not enabled")
        )
        XCTAssertEqual(
            CuratorAvailability.evaluate(availability: .unavailable(.modelNotReady)),
            .temporarilyUnavailable(reason: "Apple Intelligence model assets are still preparing")
        )
    }

    func testGuidedGenerationSchemaAndGeneratedContentRoundTrip() throws {
        let sample = CuratorDiagnosticAnalysis(
            evidenceClues: ["Synchronous Exception at 0x46519EF8"],
            likelyArea: "Casement",
            summary: "EDK2 hit a translation block invalidation fault during ISO boot.",
            recommendedLever: "reportOnly",
            stepsTried: ["Enabled HV_NO_TLBI_BLOCK"]
        )

        let content = sample.generatedContent
        XCTAssertTrue(content.isComplete)
        let decoded = try CuratorDiagnosticAnalysis(content)
        XCTAssertEqual(decoded, sample)

        let jsonDecoded = try GeneratedContent(json: content.jsonString)
        XCTAssertEqual(try CuratorDiagnosticAnalysis(jsonDecoded), sample)

        let partial = sample.asPartiallyGenerated()
        XCTAssertEqual(partial.likelyArea, "Casement")
        XCTAssertEqual(partial.recommendedLever, "reportOnly")

        let dynamicSchema = try CuratorDynamicSchema.makeConfigPatchSchema(
            allowedKeys: ["henge.perf.codeCacheMB", "HV_NO_TLBI_BLOCK"]
        )
        if #available(iOS 27.0, *) {
            XCTAssertEqual(dynamicSchema.name, "CuratorConfigPatch")
        }

        XCTAssertThrowsError(try CuratorDynamicSchema.makeConfigPatchSchema(allowedKeys: [])) { error in
            guard case GenerationSchema.SchemaError.emptyTypeChoices(let schemaName, _) = error else {
                XCTFail("Expected emptyTypeChoices error, got \(error)")
                return
            }
            XCTAssertEqual(schemaName, "AllowedConfigKey")
        }
    }

    func testCuratorToolDefinitionAndAllowlistGuard() async throws {
        let tool = StageConfigFixTool()
        let def = Transcript.ToolDefinition(tool: tool)
        XCTAssertEqual(def.name, "stageConfigFix")
        XCTAssertFalse(def.description.isEmpty)

        let validOut = try await tool.call(
            arguments: .init(key: "henge.perf.codeCacheMB", value: "512")
        )
        XCTAssertEqual(validOut, "staged: henge.perf.codeCacheMB=512")

        // Prompt injection attempt with an unallowlisted key or embedded newline must be rejected.
        let forbiddenKeyOut = try await tool.call(
            arguments: .init(key: "DYLD_INSERT_LIBRARIES", value: "/tmp/evil.dylib")
        )
        XCTAssertTrue(forbiddenKeyOut.hasPrefix("rejected:"))

        let newlineInjectionOut = try await tool.call(
            arguments: .init(key: "HV_NO_TLBI_BLOCK", value: "1\nDYLD_PRINT_ENV=1")
        )
        XCTAssertTrue(newlineInjectionOut.hasPrefix("rejected:"))
    }

    @available(iOS 27.0, *)
    func testCustomFallbackLanguageModelSessionExecution() async throws {
        let fallbackModel = MockMLXFallbackLanguageModel(choice: .qwen3_0_6b_4bit)
        XCTAssertTrue(fallbackModel.capabilities.contains(.guidedGeneration))
        XCTAssertTrue(fallbackModel.capabilities.contains(.toolCalling))
        XCTAssertFalse(fallbackModel.capabilities.contains(.vision))

        let session = LanguageModelSession(
            model: fallbackModel,
            tools: [StageConfigFixTool()],
            instructions: "Diagnose the Triptych log excerpt."
        )
        session.transcriptErrorHandlingPolicy = .revertTranscript
        session.prewarm()

        // Setting reasoningLevel on a model without .reasoning capability throws LanguageModelError.unsupportedCapability.
        do {
            _ = try await session.respond(
                to: "[jit-pool] EXHAUSTED",
                generating: CuratorDiagnosticAnalysis.self,
                contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .light)
            )
            XCTFail("Expected unsupportedCapability(.reasoning)")
        } catch {
            guard case LanguageModelError.unsupportedCapability(let info) = error else {
                XCTFail("Expected unsupportedCapability(.reasoning), got \(error)")
                return
            }
            XCTAssertEqual(info.capability, .reasoning)
        }

        let response = try await session.respond(
            to: "[jit-pool] EXHAUSTED status=c0000017",
            generating: CuratorDiagnosticAnalysis.self,
            options: GenerationOptions(
                samplingMode: .greedy,
                temperature: 0.0,
                maximumResponseTokens: 256,
                toolCallingMode: .disallowed
            ),
            contextOptions: ContextOptions(
                includeSchemaInPrompt: true,
                reasoningLevel: fallbackModel.capabilities.contains(.reasoning) ? .light : nil
            )
        )

        XCTAssertEqual(response.content.likelyArea, "Pane")
        XCTAssertEqual(response.content.recommendedLever, "enablePoolSplit")
        XCTAssertEqual(response.content.evidenceClues, ["[jit-pool] EXHAUSTED", "status=c0000017"])
        XCTAssertEqual(response.usage.input.totalTokenCount, 128)
        XCTAssertEqual(response.usage.input.cachedTokenCount, 64)
        XCTAssertEqual(response.usage.output.totalTokenCount, 42)
        XCTAssertEqual(response.usage.totalTokenCount, 170)
    }

    func testFailureModesAndMLXFallbackMemoryPolicy() {
        if #available(iOS 27.0, *) {
            let overflow = LanguageModelError.contextSizeExceeded(
                .init(contextSize: 8192, tokenCount: 9400, debugDescription: "Prompt exceeded 8192 tokens")
            )
            if case .contextSizeExceeded(let info) = overflow {
                XCTAssertEqual(info.contextSize, 8192)
                XCTAssertEqual(info.tokenCount, 9400)
            } else {
                XCTFail("Expected contextSizeExceeded")
            }

            let assetsErr = SystemLanguageModel.Error.assetsUnavailable(
                .init(debugDescription: "BackgroundAssets download pending")
            )
            XCTAssertFalse(assetsErr.debugDescription.isEmpty)

            let parseErr = GeneratedContent.ParsingError(
                rawContent: "{broken",
                debugDescription: "Truncated JSON"
            )
            XCTAssertEqual(parseErr.rawContent, "{broken")
        }

        // Verify all fallback models obey the <= 1.5B parameter constraint.
        XCTAssertLessThanOrEqual(CuratorFallbackModelChoice.qwen3_0_6b_4bit.parameterCountBillions, 1.5)
        XCTAssertLessThanOrEqual(CuratorFallbackModelChoice.qwen2_5_1_5b_4bit.parameterCountBillions, 1.5)

        let mb: UInt64 = 1024 * 1024
        // 1. Active heavy VM/game engine -> never load MLX weights in-process.
        XCTAssertEqual(
            CuratorFallbackModelChoice.select(
                availableMemoryBytes: 4096 * mb,
                hasActiveHeavyEngine: true,
                prefer1_5BWhenHeadroomAllows: true
            ),
            .none
        )

        // 2. Low memory headroom (< 900 MB) -> deterministic triage only (.none).
        XCTAssertEqual(
            CuratorFallbackModelChoice.select(
                availableMemoryBytes: 750 * mb,
                hasActiveHeavyEngine: false
            ),
            .none
        )

        // 3. 4 GB-6 GB non-AI device idle (e.g. 1,400 MB free) -> Qwen3-0.6B-4bit (~488 MB peak).
        let defaultChoice = CuratorFallbackModelChoice.select(
            availableMemoryBytes: 1400 * mb,
            hasActiveHeavyEngine: false,
            prefer1_5BWhenHeadroomAllows: true
        )
        XCTAssertEqual(defaultChoice, .qwen3_0_6b_4bit)
        XCTAssertLessThan(defaultChoice.estimatedPeakFootprintBytes, 1400 * mb)

        // 4. 6 GB non-AI device idle with >= 1,850 MB free & 1.5B opted in -> Qwen2.5-1.5B-Instruct-4bit (~1,050 MB peak).
        let optIn15B = CuratorFallbackModelChoice.select(
            availableMemoryBytes: 2200 * mb,
            hasActiveHeavyEngine: false,
            prefer1_5BWhenHeadroomAllows: true
        )
        XCTAssertEqual(optIn15B, .qwen2_5_1_5b_4bit)
        XCTAssertLessThan(optIn15B.estimatedPeakFootprintBytes, 2200 * mb)
    }
}
