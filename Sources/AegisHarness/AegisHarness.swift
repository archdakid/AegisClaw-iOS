import Foundation
import AegisCore
import AegisEdgeLLM
import AegisContextMemory
import AegisTools

// MARK: - Turn Verdict & Result Types

public struct ConversationTurnResult: Sendable, Equatable {
    public let turnID: TurnID
    public let finalResponse: String
    public let thinkingTrace: String?
    public let toolCallsExecuted: Int
    public let usedPrefixCache: Bool
    public let coalescedFollowUpMessages: [String]
    public let recoveredCrashEntries: [ToolJournalEntry]
}

// MARK: - Hermes ToolRoundExecutor (Persist-Before-Execute, Dedup, Truncation, Loop Guard)

public actor ToolRoundExecutor {
    private let database: SQLiteWALDatabase
    private let toolRegistry: ToolRegistry
    private let toolAuthority: ToolAuthorityRuntime
    private let paths: WorkspacePaths
    private var recentSignatures: [SessionID: [String]] = [:]

    public init(
        database: SQLiteWALDatabase,
        toolRegistry: ToolRegistry,
        toolAuthority: ToolAuthorityRuntime,
        paths: WorkspacePaths
    ) {
        self.database = database
        self.toolRegistry = toolRegistry
        self.toolAuthority = toolAuthority
        self.paths = paths
    }

    /// Strips duplicate read-only tool calls within the same batch (`_deduplicate_tool_calls`).
    public func deduplicateToolBatch(_ calls: [ToolCallRequest]) async -> [ToolCallRequest] {
        var seenReadSignatures = Set<String>()
        var filtered: [ToolCallRequest] = []
        for call in calls {
            let signature = "\(call.toolName)::\(call.argumentsJSON)"
            if let tool = await toolRegistry.tool(named: call.toolName), tool.isReadOnly {
                if seenReadSignatures.contains(signature) {
                    continue
                }
                seenReadSignatures.insert(signature)
            }
            filtered.append(call)
        }
        return filtered
    }

    /// Detects 3 consecutive identical tool calls (`is_runaway_repetition`).
    public func isRunawayRepetition(sessionID: SessionID, call: ToolCallRequest) -> Bool {
        let sig = "\(call.toolName)::\(call.argumentsJSON)"
        var history = recentSignatures[sessionID] ?? []
        history.append(sig)
        if history.count > 6 {
            history.removeFirst(history.count - 6)
        }
        recentSignatures[sessionID] = history
        guard history.count >= 3 else { return false }
        let lastThree = history.suffix(3)
        return lastThree.allSatisfy { $0 == sig }
    }

    public func executeToolRound(
        calls: [ToolCallRequest],
        context: AdmittedRunContext,
        onEvent: @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> (results: [ToolCallResult], loopBroken: Bool) {
        let deduplicated = await deduplicateToolBatch(calls)
        var results: [ToolCallResult] = []

        for call in deduplicated {
            if isRunawayRepetition(sessionID: context.sessionID, call: call) {
                let breakResult = ToolCallResult(
                    callID: call.callID,
                    toolName: call.toolName,
                    outputText: "[Runaway Repetition Guard]: Tool `\(call.toolName)` was invoked 3 times with identical arguments. Breaking loop; synthesize final answer now.",
                    isError: true
                )
                results.append(breakResult)
                return (results, true)
            }

            await onEvent(.toolCallRequested(call))

            guard let tool = await toolRegistry.tool(named: call.toolName) else {
                let errResult = ToolCallResult(
                    callID: call.callID,
                    toolName: call.toolName,
                    outputText: "Validation Error: Unknown tool `\(call.toolName)`.",
                    isError: true
                )
                results.append(errResult)
                await onEvent(.toolCallCompleted(errResult))
                continue
            }

            // CRITICAL INVARIANT: Persist-Before-Execute into SQLite WAL Journal
            try await database.recordToolCallPending(
                callID: call.callID,
                turnID: context.turnID,
                sessionID: context.sessionID,
                toolName: call.toolName,
                argsJSON: call.argumentsJSON
            )

            let startTime = Date()
            do {
                try await toolAuthority.authorize(tool: tool, context: context)
                let rawOutput = try await tool.execute(argumentsJSON: call.argumentsJSON, context: context)
                let (finalText, overflowPath) = try truncateOutputIfNeeded(
                    rawOutput,
                    callID: call.callID,
                    maxChars: context.budget.maxToolOutputChars
                )
                try await database.markToolCallCompleted(callID: call.callID, outputPath: overflowPath)
                let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                let okResult = ToolCallResult(
                    callID: call.callID,
                    toolName: call.toolName,
                    outputText: finalText,
                    isError: false,
                    overflowFilePath: overflowPath,
                    latencyMs: latency
                )
                results.append(okResult)
                await onEvent(.toolCallCompleted(okResult))
            } catch {
                try await database.markToolCallCompleted(callID: call.callID, outputPath: nil)
                let errResult = ToolCallResult(
                    callID: call.callID,
                    toolName: call.toolName,
                    outputText: "Tool Execution Error: \(error.localizedDescription)",
                    isError: true
                )
                results.append(errResult)
                await onEvent(.toolCallCompleted(errResult))
            }
        }
        return (results, false)
    }

    private func truncateOutputIfNeeded(
        _ output: String,
        callID: String,
        maxChars: Int
    ) throws -> (text: String, overflowPath: String?) {
        guard output.count > maxChars else { return (output, nil) }
        let fileURL = paths.toolOutputsDir.appendingPathComponent("\(callID).txt")
        try output.write(to: fileURL, atomically: true, encoding: .utf8)
        let preview = String(output.prefix(maxChars))
        let truncatedMsg = "\(preview)\n...[Truncated \(output.count - maxChars) chars; full output saved at \(fileURL.path)]"
        return (truncatedMsg, fileURL.path)
    }
}

// MARK: - AIAgentCoordinator (Hermes run_conversation + OpenClaw AdmittedRunContext)

public actor AIAgentCoordinator {
    private let paths: WorkspacePaths
    private let database: SQLiteWALDatabase
    private let contextEngine: any ContextEngineProtocol
    private let modelProvider: any LanguageModelProvider
    private let toolRegistry: ToolRegistry
    private let toolRoundExecutor: ToolRoundExecutor
    private var sessionHistories: [SessionID: [ChatMessage]] = [:]

    public init(
        paths: WorkspacePaths,
        database: SQLiteWALDatabase,
        contextEngine: any ContextEngineProtocol,
        modelProvider: any LanguageModelProvider,
        toolRegistry: ToolRegistry,
        toolAuthority: ToolAuthorityRuntime
    ) {
        self.paths = paths
        self.database = database
        self.contextEngine = contextEngine
        self.modelProvider = modelProvider
        self.toolRegistry = toolRegistry
        self.toolRoundExecutor = ToolRoundExecutor(
            database: database,
            toolRegistry: toolRegistry,
            toolAuthority: toolAuthority,
            paths: paths
        )
    }

    public func runConversation(
        sessionID: SessionID,
        userMessage: InboundUserMessage,
        systemPrompt: String = "You are AegisClaw, an autonomous on-device iOS personal assistant.",
        budget: TurnBudgetLimits = .defaultEdgeBudget,
        holderPID: String = "pid_\(ProcessInfo.processInfo.processIdentifier)",
        streamCallback: @Sendable (AgentStreamEvent) async -> Void = { _ in }
    ) async throws -> ConversationTurnResult {
        let turnID = TurnID()

        // 1. Durable Turn Lease Acquisition & Coalescing
        let (acquired, coalesced) = try await database.acquireOrCoalesceTurnLease(
            sessionID: sessionID,
            holderPID: holderPID,
            turnID: turnID,
            ttlSeconds: 30,
            inboundMessageJSON: userMessage.text
        )
        if !acquired {
            return ConversationTurnResult(
                turnID: turnID,
                finalResponse: "[Coalesced into active turn lease for session \(sessionID)]",
                thinkingTrace: nil,
                toolCallsExecuted: 0,
                usedPrefixCache: false,
                coalescedFollowUpMessages: coalesced,
                recoveredCrashEntries: []
            )
        }

        // 2. Crash Recovery Gate: Check for orphaned PENDING_EXECUTION tool calls from prior Jetsam/crash
        let recoveredEntries = try await database.recoverOrphanedToolCalls(for: sessionID)
        var history = sessionHistories[sessionID] ?? []
        for orphan in recoveredEntries {
            let recoveryMsg = ChatMessage(
                sessionID: sessionID,
                role: .tool,
                content: "[Recovered from prior process interruption during tool `\(orphan.toolName)` (call \(orphan.callID))]",
                toolCallID: orphan.callID
            )
            history.append(recoveryMsg)
            try await contextEngine.ingest(message: recoveryMsg)
        }

        // 3. Ingest inbound user message
        let userChatMsg = ChatMessage(sessionID: sessionID, role: .user, content: userMessage.text)
        history.append(userChatMsg)
        try await contextEngine.ingest(message: userChatMsg)

        let runContext = AdmittedRunContext(
            sessionID: sessionID,
            turnID: turnID,
            processOwnerID: holderPID,
            workspaceRoot: paths.rootURL,
            budget: budget
        )

        var toolCallsCount = 0
        var finalOutput = ""
        var latestThinking: String?
        var prefixCacheHit = false
        let sortedSchemas = await toolRegistry.canonicalSortedToolSchemasJSON()

        // 4. Bounded Agentic Tool-Calling Loop
        for _ in 0..<budget.maxToolRounds {
            let assembled = try await contextEngine.assemble(
                sessionID: sessionID,
                query: userMessage.text,
                history: history,
                systemPrompt: systemPrompt,
                sortedToolSchemasJSON: sortedSchemas,
                budget: budget
            )
            history = assembled.compactedHistory

            let genRequest = ModelGenerationRequest(
                sessionID: sessionID,
                immutablePrefix: assembled.immutablePrefix,
                messages: history,
                assembledMemoryBlock: assembled.retrievedMemoryBlock,
                toolSchemasJSON: sortedSchemas,
                maxOutputTokens: budget.reservedOutputTokens
            )

            let response = try await modelProvider.generateTurn(request: genRequest, onEvent: streamCallback)
            prefixCacheHit = response.usedPrefixCache
            if let t = response.thinking {
                latestThinking = t
            }

            if response.toolCalls.isEmpty {
                finalOutput = response.content
                let assistantMsg = ChatMessage(
                    sessionID: sessionID,
                    role: .assistant,
                    content: response.content,
                    thinking: response.thinking
                )
                history.append(assistantMsg)
                try await contextEngine.ingest(message: assistantMsg)
                break
            } else {
                let assistantToolMsg = ChatMessage(
                    sessionID: sessionID,
                    role: .assistant,
                    content: response.content,
                    thinking: response.thinking,
                    toolCalls: response.toolCalls
                )
                history.append(assistantToolMsg)
                try await contextEngine.ingest(message: assistantToolMsg)

                let (toolResults, loopBroken) = try await toolRoundExecutor.executeToolRound(
                    calls: response.toolCalls,
                    context: runContext,
                    onEvent: streamCallback
                )
                toolCallsCount += toolResults.count

                for tr in toolResults {
                    let toolMsg = ChatMessage(
                        sessionID: sessionID,
                        role: .tool,
                        content: tr.outputText,
                        toolCallID: tr.callID
                    )
                    history.append(toolMsg)
                    try await contextEngine.ingest(message: toolMsg)
                }

                if loopBroken {
                    finalOutput = toolResults.last?.outputText ?? "Loop broken."
                    break
                }
            }
        }

        sessionHistories[sessionID] = history
        let drainedCoalesced = try await database.drainCoalescedMessagesAndReleaseLease(sessionID: sessionID)

        await streamCallback(.turnCompleted(totalTokens: history.reduce(0) { $0 + $1.tokenCount }, latencyMs: 165))

        return ConversationTurnResult(
            turnID: turnID,
            finalResponse: finalOutput,
            thinkingTrace: latestThinking,
            toolCallsExecuted: toolCallsCount,
            usedPrefixCache: prefixCacheHit,
            coalescedFollowUpMessages: drainedCoalesced,
            recoveredCrashEntries: recoveredEntries
        )
    }
}
