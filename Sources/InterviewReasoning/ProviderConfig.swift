import Foundation
import InterviewCore

/// OpenAI-compatible endpoints. Base URLs and models are editable in Settings; these are starting values
/// checked on 6 October 2026. Prices live in `PriceRegistry`.
public struct ProviderPreset: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var routineModel: String
    public var strongModel: String
    public var supportsStreamUsage: Bool
    public var maxTemperature: Double
    public var docsURL: String
    public var notes: String
    public init(id: String, displayName: String, baseURL: String, routineModel: String, strongModel: String, supportsStreamUsage: Bool = true, maxTemperature: Double = 2.0, docsURL: String, notes: String = "") {
        self.id = id; self.displayName = displayName; self.baseURL = baseURL; self.routineModel = routineModel; self.strongModel = strongModel
        self.supportsStreamUsage = supportsStreamUsage; self.maxTemperature = maxTemperature; self.docsURL = docsURL; self.notes = notes
    }
}

public enum ProviderPresets {
    public static let deepseek = ProviderPreset(id: "deepseek", displayName: "DeepSeek", baseURL: "https://api.deepseek.com/v1", routineModel: "deepseek-chat", strongModel: "deepseek-reasoner", docsURL: "https://api-docs.deepseek.com", notes: "One key covers both routes. Cache hits are cheaper; off-peak discounts apply.")
    public static let qwen = ProviderPreset(id: "qwen", displayName: "Qwen (Alibaba Model Studio, Singapore)", baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", routineModel: "qwen-flash", strongModel: "qwen-plus", docsURL: "https://www.alibabacloud.com/help/en/model-studio", notes: "Flash is the cheapest routine route tested in the plan's price table.")
    public static let moonshot = ProviderPreset(id: "moonshot", displayName: "Moonshot Kimi", baseURL: "https://api.moonshot.ai/v1", routineModel: "kimi-k2.5", strongModel: "kimi-k2.6", docsURL: "https://platform.moonshot.ai/docs", notes: "256K context on current models.")
    public static let zai = ProviderPreset(id: "zai", displayName: "Z.ai GLM", baseURL: "https://api.z.ai/api/paas/v4", routineModel: "glm-4.5-air", strongModel: "glm-5", docsURL: "https://docs.z.ai", notes: "China endpoint: https://open.bigmodel.cn/api/paas/v4")
    public static let minimax = ProviderPreset(id: "minimax", displayName: "MiniMax", baseURL: "https://api.minimax.io/v1", routineModel: "MiniMax-M2", strongModel: "MiniMax-M2", maxTemperature: 1.0, docsURL: "https://platform.minimax.io/docs", notes: "Temperature must be in (0, 1].")
    public static let custom = ProviderPreset(id: "custom", displayName: "Custom OpenAI-compatible", baseURL: "https://example.com/v1", routineModel: "model", strongModel: "model", docsURL: "", notes: "Any endpoint that implements POST /chat/completions with streaming.")
    public static let all: [ProviderPreset] = [deepseek, qwen, moonshot, zai, minimax, custom]
    public static func preset(id: String) -> ProviderPreset? { all.first { $0.id == id } }
}

/// Persisted reasoning configuration (settings table). The API key itself lives in the Keychain.
public struct ReasoningConfiguration: Codable, Sendable, Equatable {
    public var providerID: String
    public var baseURL: String
    public var routineModel: String
    public var strongModel: String
    public var sessionCapUSD: Double
    public var strongTurnAllowance: Int
    public var requestTimeoutSeconds: Double
    public var onDeviceEnabled: Bool
    public var onDeviceForQuestionDetection: Bool
    public var contextBudgetTokens: Int
    public init(providerID: String = "deepseek", baseURL: String = ProviderPresets.deepseek.baseURL, routineModel: String = ProviderPresets.deepseek.routineModel, strongModel: String = ProviderPresets.deepseek.strongModel, sessionCapUSD: Double = 0.75, strongTurnAllowance: Int = 4, requestTimeoutSeconds: Double = 25, onDeviceEnabled: Bool = true, onDeviceForQuestionDetection: Bool = true, contextBudgetTokens: Int = 6_000) {
        self.providerID = providerID; self.baseURL = baseURL; self.routineModel = routineModel; self.strongModel = strongModel; self.sessionCapUSD = sessionCapUSD
        self.strongTurnAllowance = strongTurnAllowance; self.requestTimeoutSeconds = requestTimeoutSeconds; self.onDeviceEnabled = onDeviceEnabled
        self.onDeviceForQuestionDetection = onDeviceForQuestionDetection; self.contextBudgetTokens = contextBudgetTokens
    }
    public static let settingsKey = "reasoning.configuration"
    public static let keychainAccountPrefix = "api-key."
    public var keychainAccount: String { Self.keychainAccountPrefix + providerID }
    public var preset: ProviderPreset { ProviderPresets.preset(id: providerID) ?? ProviderPresets.custom }
}
