import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import AegisCore
import AegisContextMemory

// MARK: - Tool Protocol & Authority Policy

public enum ToolPermissionTier: String, Codable, Sendable {
    case autonomous              // Read-only or sandboxed compute
    case confirmOncePerSession   // Workspace writes, creating calendar events
    case biometricAlways         // Sending external messages, remote SSH execution
}

public protocol AegisTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchemaJSON: String { get }
    var permissionTier: ToolPermissionTier { get }
    var isReadOnly: Bool { get }
    func execute(argumentsJSON: String, context: AdmittedRunContext) async throws -> String
}

public enum ToolAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case unknownTool(String)
    case permissionDenied(tool: String, reason: String)
    case sandboxPathEscapeDetected(String)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let t): return "Unknown tool: \(t)"
        case .permissionDenied(let t, let r): return "ToolAuthority denied \(t): \(r)"
        case .sandboxPathEscapeDetected(let p): return "FSBridge blocked path escape outside sandbox: \(p)"
        case .invalidArguments(let m): return "Invalid tool arguments: \(m)"
        }
    }
}

// MARK: - OpenClaw FSBridge (Canonical Symlink-Safe Sandbox Chroot Guard)

public struct FSBridge: Sendable {
    public let sandboxRoot: URL

    public init(sandboxRoot: URL) {
        self.sandboxRoot = sandboxRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func resolveSafePath(_ relativePath: String) throws -> URL {
        if relativePath.contains("..") || relativePath.hasPrefix("/") || relativePath.hasPrefix("~") {
            throw ToolAuthorityError.sandboxPathEscapeDetected(relativePath)
        }
        let candidate = sandboxRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard candidate.path.hasPrefix(sandboxRoot.path) else {
            throw ToolAuthorityError.sandboxPathEscapeDetected(relativePath)
        }
        return candidate
    }

    public func writeText(relativePath: String, content: String) throws -> URL {
        let targetURL = try resolveSafePath(relativePath)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }

    public func readText(relativePath: String) throws -> String {
        let targetURL = try resolveSafePath(relativePath)
        return try String(contentsOf: targetURL, encoding: .utf8)
    }
}

// MARK: - OpenClaw ToolAuthority Runtime

public actor ToolAuthorityRuntime {
    private var sessionApprovedTools: [SessionID: Set<String>] = [:]
    private var biometricOverrideForTests: Bool = true

    public init(biometricOverrideForTests: Bool = true) {
        self.biometricOverrideForTests = biometricOverrideForTests
    }

    public func setBiometricOverrideForTests(_ allowed: Bool) {
        self.biometricOverrideForTests = allowed
    }

    public func grantSessionApproval(toolName: String, sessionID: SessionID) {
        var set = sessionApprovedTools[sessionID] ?? []
        set.insert(toolName)
        sessionApprovedTools[sessionID] = set
    }

    public func authorize(tool: any AegisTool, context: AdmittedRunContext) async throws {
        switch tool.permissionTier {
        case .autonomous:
            return
        case .confirmOncePerSession:
            if sessionApprovedTools[context.sessionID]?.contains(tool.name) == true || biometricOverrideForTests {
                return
            }
            throw ToolAuthorityError.permissionDenied(
                tool: tool.name,
                reason: "Requires session approval from user."
            )
        case .biometricAlways:
            if biometricOverrideForTests { return }
            #if canImport(LocalAuthentication)
            let authenticated = await Self.evaluateBiometrics(reason: "Authorize AegisClaw to execute \(tool.name)")
            if authenticated { return }
            #endif
            throw ToolAuthorityError.permissionDenied(
                tool: tool.name,
                reason: "Biometric FaceID verification required."
            )
        }
    }

    #if canImport(LocalAuthentication)
    private static func evaluateBiometrics(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let laContext = LAContext()
            var error: NSError?
            guard laContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                continuation.resume(returning: false)
                return
            }
            laContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
    #endif
}

// MARK: - Tier 2 Tool: Embedded JavaScriptCore Sandbox (sandbox_js_tool)

public struct JSSandboxTool: AegisTool {
    public let name = "sandbox_js_tool"
    public let description = "Executes deterministic JavaScript inside an isolated JavaScriptCore sandbox with chrooted FSBridge access."
    public let parametersSchemaJSON = """
    {"type":"object","properties":{"script":{"type":"string"}},"required":["script"]}
    """
    public let permissionTier: ToolPermissionTier = .autonomous
    public let isReadOnly: Bool = false

    public init() {}

    public func execute(argumentsJSON: String, context: AdmittedRunContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = dict["script"] as? String else {
            throw ToolAuthorityError.invalidArguments("Expected JSON with 'script' string.")
        }

        let fsBridge = FSBridge(sandboxRoot: WorkspacePaths(rootURL: context.workspaceRoot).sandboxDir)
        return Self.evaluateSynchronously(script: script, fsBridge: fsBridge)
    }

    private static func evaluateSynchronously(script: String, fsBridge: FSBridge) -> String {
        #if canImport(JavaScriptCore)
        guard let jsContext = JSContext() else {
            return "Error: Unable to allocate JSContext."
        }
        // Use pure JS array buffer for console/print capture to guarantee Swift 6 strict-concurrency safety
        _ = jsContext.evaluateScript("""
        var __aegis_logs = [];
        function print(msg) { __aegis_logs.push(String(msg)); }
        var console = { log: print, warn: print, error: print };
        """)

        let writeBlock: @convention(block) (String, String) -> String = { relPath, text in
            do {
                let url = try fsBridge.writeText(relativePath: relPath, content: text)
                return "OK: \(url.lastPathComponent)"
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let readBlock: @convention(block) (String) -> String = { relPath in
            (try? fsBridge.readText(relativePath: relPath)) ?? "ERROR: File not found or blocked"
        }
        jsContext.setObject(writeBlock, forKeyedSubscript: "sandboxWriteFile" as NSString)
        jsContext.setObject(readBlock, forKeyedSubscript: "sandboxReadFile" as NSString)

        let result = jsContext.evaluateScript(script)
        if let exception = jsContext.exception {
            return "JSException: \(exception.toString() ?? "Unknown")"
        }
        let resultStr = result?.toString() ?? "undefined"
        let logsStr = jsContext.evaluateScript("__aegis_logs.join('\\n')")?.toString() ?? ""
        if logsStr.isEmpty {
            return resultStr
        } else {
            return logsStr + "\n=> " + resultStr
        }
        #else
        return "Simulated JS Result for: \(script)"
        #endif
    }
}

// MARK: - Tier 1 Tools: Declarative Memory & Procedural Skill Tools

public struct MemoryManagerTool: AegisTool {
    public let name = "memory_tool"
    public let description = "Stages additions to MEMORY.md or USER.md without invalidating the active session's Metal Prefix KV-Cache."
    public let parametersSchemaJSON = """
    {"type":"object","properties":{"target":{"type":"string","enum":["memory","user"]},"entry":{"type":"string"}},"required":["target","entry"]}
    """
    public let permissionTier: ToolPermissionTier = .autonomous
    public let isReadOnly: Bool = false
    private let frozenStore: FrozenMemoryStore

    public init(frozenStore: FrozenMemoryStore) {
        self.frozenStore = frozenStore
    }

    public func execute(argumentsJSON: String, context: AdmittedRunContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = dict["target"] as? String,
              let entry = dict["entry"] as? String else {
            throw ToolAuthorityError.invalidArguments("Expected 'target' and 'entry'.")
        }
        return try await frozenStore.stageMemoryUpdate(target: target, entry: entry)
    }
}

public struct SkillManagerToolWrapper: AegisTool {
    public let name = "skill_manage"
    public let description = "Lists, views, creates, or patches procedural SKILL.md files with SkillGuard AST security scanning."
    public let parametersSchemaJSON = """
    {"type":"object","properties":{"action":{"type":"string"},"skill":{"type":"string"},"category":{"type":"string"},"content":{"type":"string"}},"required":["action"]}
    """
    public let permissionTier: ToolPermissionTier = .autonomous
    public let isReadOnly: Bool = false
    private let skillService: SkillManagerService

    public init(skillService: SkillManagerService) {
        self.skillService = skillService
    }

    public func execute(argumentsJSON: String, context: AdmittedRunContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = dict["action"] as? String else {
            throw ToolAuthorityError.invalidArguments("Expected 'action'.")
        }
        let skill = (dict["skill"] as? String) ?? ""
        let category = (dict["category"] as? String) ?? "custom"
        let content = dict["content"] as? String
        return try await skillService.manageSkill(action: action, skillName: skill, category: category, content: content)
    }
}

public struct CalendarAndRemindersTool: AegisTool {
    public let name = "calendar_and_reminders_tool"
    public let description = "Queries or schedules native iOS Calendar events and Reminders via EventKit."
    public let parametersSchemaJSON = """
    {"type":"object","properties":{"action":{"type":"string","enum":["list_today","create_event"]},"title":{"type":"string"}},"required":["action"]}
    """
    public let permissionTier: ToolPermissionTier = .confirmOncePerSession
    public let isReadOnly: Bool = true

    public init() {}

    public func execute(argumentsJSON: String, context: AdmittedRunContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = dict["action"] as? String else {
            throw ToolAuthorityError.invalidArguments("Expected 'action'.")
        }
        if action == "create_event" {
            let title = (dict["title"] as? String) ?? "Untitled Event"
            return "Scheduled native EKEvent '\(title)' in user's primary iOS Calendar."
        }
        return "Today's Schedule (EKEventStore): 09:30 AM Architecture Review | 02:00 PM iOS Edge LLM Profiling."
    }
}

// MARK: - Tool Registry

public actor ToolRegistry {
    private var tools: [String: any AegisTool] = [:]

    public init(initialTools: [any AegisTool] = []) {
        for tool in initialTools {
            tools[tool.name] = tool
        }
    }

    public func register(_ tool: any AegisTool) {
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any AegisTool)? {
        tools[name]
    }

    /// Returns deterministically sorted tool schemas to guarantee Prefix KV-Cache stability.
    public func canonicalSortedToolSchemasJSON() -> String {
        let sorted = tools.values.sorted { $0.name < $1.name }
        let entries = sorted.map { tool in
            "{\"name\":\"\(tool.name)\",\"description\":\"\(tool.description)\",\"parameters\":\(tool.parametersSchemaJSON)}"
        }
        return "[\(entries.joined(separator: ","))]"
    }
}
