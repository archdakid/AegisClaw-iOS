import Foundation
import AegisCore
import AegisEdgeLLM
import AegisContextMemory
import AegisHarness
import AegisTools

// MARK: - OpenClaw Sender Quarantine & Pairing Security Model

public struct QuarantinedSender: Codable, Sendable, Equatable, Identifiable {
    public var id: String { senderKey }
    public let senderKey: String
    public let channel: String
    public let pairingCode: String
    public var isApproved: Bool
    public var heldMessages: [String]
}

public actor SenderQuarantineGate {
    private var senders: [String: QuarantinedSender] = [
        "local_owner": QuarantinedSender(
            senderKey: "local_owner",
            channel: "ios_native_ui",
            pairingCode: "000000",
            isApproved: true,
            heldMessages: []
        )
    ]

    public init() {}

    public func admitOrQuarantine(message: InboundUserMessage) -> (admitted: Bool, pairingCode: String?) {
        if let existing = senders[message.senderIdentifier] {
            if existing.isApproved {
                return (true, nil)
            } else {
                var updated = existing
                updated.heldMessages.append(message.text)
                senders[message.senderIdentifier] = updated
                return (false, existing.pairingCode)
            }
        }
        let code = String(format: "%06d", Int.random(in: 100000...999999))
        let record = QuarantinedSender(
            senderKey: message.senderIdentifier,
            channel: message.channelSource,
            pairingCode: code,
            isApproved: false,
            heldMessages: [message.text]
        )
        senders[message.senderIdentifier] = record
        return (false, code)
    }

    public func approveSender(senderKey: String, pairingCode: String) -> [String]? {
        guard var record = senders[senderKey], record.pairingCode == pairingCode else {
            return nil
        }
        record.isApproved = true
        let released = record.heldMessages
        record.heldMessages = []
        senders[senderKey] = record
        return released
    }

    public func listQuarantinedSenders() -> [QuarantinedSender] {
        senders.values.filter { !$0.isApproved }.sorted { $0.senderKey < $1.senderKey }
    }
}

// MARK: - Bidirectional Hermes Agent <-> OpenClaw Workspace Migrator

public struct MigrationSummary: Codable, Sendable, Equatable {
    public let sourceSystem: String
    public let importedMemoryBytes: Int
    public let importedUserBytes: Int
    public let importedSkillsCount: Int
}

public enum HermesOpenClawMigrator {
    /// Imports a desktop `~/.hermes` or `~/.openclaw` directory structure into the iOS App Group workspace.
    public static func importExternalWorkspace(
        from externalDirectory: URL,
        into targetPaths: WorkspacePaths,
        skillService: SkillManagerService
    ) async throws -> MigrationSummary {
        let fm = FileManager.default
        let isHermes = fm.fileExists(atPath: externalDirectory.appendingPathComponent("config.yaml").path)
            || fm.fileExists(atPath: externalDirectory.appendingPathComponent("memory/MEMORY.md").path)
        let sourceType = isHermes ? "Hermes Agent (~/.hermes)" : "OpenClaw (~/.openclaw)"

        var memBytes = 0
        var userBytes = 0
        var skillCount = 0

        let candidateMemoryURLs = [
            externalDirectory.appendingPathComponent("memory/MEMORY.md"),
            externalDirectory.appendingPathComponent("MEMORY.md")
        ]
        for url in candidateMemoryURLs where fm.fileExists(atPath: url.path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            try content.write(to: targetPaths.memoryFileURL, atomically: true, encoding: .utf8)
            memBytes = content.utf8.count
            break
        }

        let candidateUserURLs = [
            externalDirectory.appendingPathComponent("memory/USER.md"),
            externalDirectory.appendingPathComponent("USER.md")
        ]
        for url in candidateUserURLs where fm.fileExists(atPath: url.path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            try content.write(to: targetPaths.userFileURL, atomically: true, encoding: .utf8)
            userBytes = content.utf8.count
            break
        }

        let extSkillsDir = externalDirectory.appendingPathComponent("skills")
        if fm.fileExists(atPath: extSkillsDir.path),
           let enumerator = fm.enumerator(at: extSkillsDir, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.lastPathComponent == "SKILL.md" {
                    if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
                        let skillName = fileURL.deletingLastPathComponent().lastPathComponent
                        if (try? await skillService.manageSkill(
                            action: "create",
                            skillName: skillName,
                            category: "migrated",
                            content: raw
                        )) != nil {
                            skillCount += 1
                        }
                    }
                }
            }
        }

        return MigrationSummary(
            sourceSystem: sourceType,
            importedMemoryBytes: memBytes,
            importedUserBytes: userBytes,
            importedSkillsCount: skillCount
        )
    }
}
