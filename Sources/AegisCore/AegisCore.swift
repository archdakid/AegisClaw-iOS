import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - Core Identifiers & Domain Models

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString.lowercased()) {
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct TurnID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString.lowercased()) {
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ToolCallRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String { callID }
    public let callID: String
    public let toolName: String
    public let argumentsJSON: String

    public init(callID: String = "call_\(UUID().uuidString.prefix(8))", toolName: String, argumentsJSON: String) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

public struct ToolCallResult: Codable, Sendable, Equatable {
    public let callID: String
    public let toolName: String
    public let outputText: String
    public let isError: Bool
    public let overflowFilePath: String?
    public let latencyMs: Int

    public init(
        callID: String,
        toolName: String,
        outputText: String,
        isError: Bool = false,
        overflowFilePath: String? = nil,
        latencyMs: Int = 0
    ) {
        self.callID = callID
        self.toolName = toolName
        self.outputText = outputText
        self.isError = isError
        self.overflowFilePath = overflowFilePath
        self.latencyMs = latencyMs
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: SessionID
    public let role: MessageRole
    public let content: String
    public let thinking: String?
    public let toolCalls: [ToolCallRequest]
    public let toolCallID: String?
    public let tokenCount: Int
    public let promotionScore: Double
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        sessionID: SessionID,
        role: MessageRole,
        content: String,
        thinking: String? = nil,
        toolCalls: [ToolCallRequest] = [],
        toolCallID: String? = nil,
        tokenCount: Int? = nil,
        promotionScore: Double = 0.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.tokenCount = tokenCount ?? max(1, (content.count + (thinking?.count ?? 0)) / 4)
        self.promotionScore = promotionScore
        self.createdAt = createdAt
    }
}

public struct InboundUserMessage: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let channelSource: String
    public let senderIdentifier: String
    public let attachments: [String]
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        text: String,
        channelSource: String = "ios_native_ui",
        senderIdentifier: String = "local_owner",
        attachments: [String] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.channelSource = channelSource
        self.senderIdentifier = senderIdentifier
        self.attachments = attachments
        self.timestamp = timestamp
    }
}

// MARK: - OpenClaw AdmittedRunContext & HostCapability

public struct TurnBudgetLimits: Codable, Sendable, Equatable {
    public let maxToolRounds: Int
    public let maxContextTokens: Int
    public let reservedOutputTokens: Int
    public let maxToolOutputChars: Int
    public let maxWallClockSeconds: TimeInterval
    public let jetsamCeilingBytes: UInt64

    public static let defaultEdgeBudget = TurnBudgetLimits(
        maxToolRounds: 10,
        maxContextTokens: 16384, // Active edge window within Gemma 4 E4B 128K (131,072) native context
        reservedOutputTokens: 1536,
        maxToolOutputChars: 4000,
        maxWallClockSeconds: 180,
        jetsamCeilingBytes: 3_400_000_000 // ~3.4 GB safe ceiling on 8GB iPhone
    )

    public init(
        maxToolRounds: Int = 10,
        maxContextTokens: Int = 16384,
        reservedOutputTokens: Int = 1536,
        maxToolOutputChars: Int = 4000,
        maxWallClockSeconds: TimeInterval = 180,
        jetsamCeilingBytes: UInt64 = 3_400_000_000
    ) {
        self.maxToolRounds = maxToolRounds
        self.maxContextTokens = maxContextTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.maxToolOutputChars = maxToolOutputChars
        self.maxWallClockSeconds = maxWallClockSeconds
        self.jetsamCeilingBytes = jetsamCeilingBytes
    }
}

public struct HostCapabilityGrant: Codable, Sendable, Hashable {
    public let capabilityName: String
    public let isEnabled: Bool
    public let requiresBiometricConfirmation: Bool

    public init(capabilityName: String, isEnabled: Bool = true, requiresBiometricConfirmation: Bool = false) {
        self.capabilityName = capabilityName
        self.isEnabled = isEnabled
        self.requiresBiometricConfirmation = requiresBiometricConfirmation
    }
}

public struct AdmittedRunContext: Sendable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let processOwnerID: String
    public let workspaceRoot: URL
    public let budget: TurnBudgetLimits
    public let capabilities: Set<HostCapabilityGrant>
    public let startedAt: Date

    public init(
        sessionID: SessionID,
        turnID: TurnID = TurnID(),
        processOwnerID: String = "pid_\(ProcessInfo.processInfo.processIdentifier)",
        workspaceRoot: URL,
        budget: TurnBudgetLimits = .defaultEdgeBudget,
        capabilities: Set<HostCapabilityGrant> = []
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.processOwnerID = processOwnerID
        self.workspaceRoot = workspaceRoot
        self.budget = budget
        self.capabilities = capabilities
        self.startedAt = Date()
    }
}

// MARK: - App Group Workspace Bootstrapper

public struct WorkspacePaths: Sendable {
    public let rootURL: URL
    public var modelsDir: URL { rootURL.appendingPathComponent("models", isDirectory: true) }
    public var memoryDir: URL { rootURL.appendingPathComponent("memory", isDirectory: true) }
    public var memoryFileURL: URL { memoryDir.appendingPathComponent("MEMORY.md") }
    public var userFileURL: URL { memoryDir.appendingPathComponent("USER.md") }
    public var skillsDir: URL { rootURL.appendingPathComponent("skills", isDirectory: true) }
    public var dreamsDir: URL { rootURL.appendingPathComponent("dreams", isDirectory: true) }
    public var sandboxDir: URL { rootURL.appendingPathComponent("sandbox", isDirectory: true) }
    public var toolOutputsDir: URL { rootURL.appendingPathComponent("tool_outputs", isDirectory: true) }
    public var kvPrefixCacheDir: URL { rootURL.appendingPathComponent("cache/kv_prefix", isDirectory: true) }
    public var databaseDir: URL { rootURL.appendingPathComponent("db", isDirectory: true) }
    public var stateDatabaseURL: URL { databaseDir.appendingPathComponent("state.db") }
    public var configYAMLURL: URL { rootURL.appendingPathComponent("config.yaml") }

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
}

public enum WorkspaceBootstrapper {
    public static func resolveDefaultWorkspaceRoot(appGroupID: String = "group.com.aegisclaw.shared") -> URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL.appendingPathComponent("workspace", isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("AegisClawWorkspace", isDirectory: true)
    }

    @discardableResult
    public static func bootstrapWorkspace(at rootURL: URL) throws -> WorkspacePaths {
        let paths = WorkspacePaths(rootURL: rootURL)
        let fm = FileManager.default
        let directories = [
            paths.rootURL,
            paths.modelsDir,
            paths.memoryDir,
            paths.skillsDir,
            paths.dreamsDir,
            paths.sandboxDir,
            paths.toolOutputsDir,
            paths.kvPrefixCacheDir,
            paths.databaseDir
        ]
        for dir in directories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: paths.memoryFileURL.path) {
            let defaultMemory = """
            # Declarative Agent Memory (MEMORY.md)
            - Runtime: AegisClaw iOS 18+ Edge Agent Harness (Hermes + OpenClaw Synthesis)
            - Edge LLM: Google Gemma 4 E4B (`unsloth/gemma-4-E4B-it-UD-MLX-4bit`)
            - Memory Policy: Frozen at session start to protect Metal Prefix KV-Cache; staged writes apply on next session.
            """
            try defaultMemory.write(to: paths.memoryFileURL, atomically: true, encoding: .utf8)
        }

        if !fm.fileExists(atPath: paths.userFileURL.path) {
            let defaultUser = """
            # Dialectic User Profile (USER.md)
            - Communication Style: Direct, concise, grounded with actionable specifics.
            - Timezone: America/Port_of_Spain
            - Active Preferences: Prioritize on-device privacy and confirm before external mutations.
            """
            try defaultUser.write(to: paths.userFileURL, atomically: true, encoding: .utf8)
        }

        if !fm.fileExists(atPath: paths.configYAMLURL.path) {
            let defaultConfig = """
            version: 1
            edge_model: unsloth/gemma-4-E4B-it-UD-MLX-4bit
            base_model: google/gemma-4-E4B-it
            litert_model: litert-community/gemma-4-E4B-it-litert-lm
            gguf_model: unsloth/gemma-4-E4B-it-GGUF
            ple_flash_mmap: true
            preserve_thinking_across_tool_turns: true
            fallback_provider: anthropic
            fallback_model: claude-3-5-sonnet-latest
            max_tool_rounds: 10
            dreaming_consolidation_enabled: true
            """
            try defaultConfig.write(to: paths.configYAMLURL, atomically: true, encoding: .utf8)
        }

        // Seed default procedural skill if skills directory is empty
        let dailyBriefingDir = paths.skillsDir.appendingPathComponent("productivity/daily-briefing", isDirectory: true)
        let dailyBriefingFile = dailyBriefingDir.appendingPathComponent("SKILL.md")
        if !fm.fileExists(atPath: dailyBriefingFile.path) {
            try fm.createDirectory(at: dailyBriefingDir, withIntermediateDirectories: true)
            let seedSkill = """
            ---
            name: daily-briefing
            description: Synthesizes today's Calendar events, Reminders, and active Standing Intents into a morning briefing.
            category: productivity
            version: 1.0.0
            ---
            # Daily Executive Briefing Skill
            1. Query `calendar_and_reminders_tool` with `action: "list_today"`.
            2. Cross-reference with active Standing Intents and `USER.md`.
            3. Present a clear chronological schedule and highlight any conflicts.
            """
            try seedSkill.write(to: dailyBriefingFile, atomically: true, encoding: .utf8)
        }

        return paths
    }
}

// MARK: - Keychain Vault & SHA-256 Utilities

public enum CryptoUtils {
    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public actor KeychainVault {
    public static let shared = KeychainVault()
    private var inMemoryFallback: [String: [String]] = [:]
    private var rotationIndices: [String: Int] = [:]

    public init() {}

    public func storeAPIKeys(provider: String, keys: [String]) {
        inMemoryFallback[provider] = keys
        rotationIndices[provider] = 0
    }

    public func nextRotatedAPIKey(for provider: String) -> String? {
        guard let keys = inMemoryFallback[provider], !keys.isEmpty else { return nil }
        let idx = (rotationIndices[provider] ?? 0) % keys.count
        rotationIndices[provider] = (idx + 1) % keys.count
        return keys[idx]
    }
}
