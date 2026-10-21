#if canImport(SwiftUI)
import SwiftUI
#if canImport(WebKit)
import WebKit
#endif
import AegisCore
import AegisEdgeLLM
import AegisContextMemory
import AegisHarness
import AegisTools
import AegisGateway

@MainActor
public final class AegisAppViewModel: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var inputPrompt: String = ""
    @Published public var activeThinking: String = ""
    @Published public var isGenerating: Bool = false
    @Published public var lastPrefixCacheHit: Bool = false
    @Published public var lastPrefixHash: String = "-"
    @Published public var activeStreamingResponse: String = ""
    @Published public var liveTokensPerSecond: Double = 0.0
    @Published public var totalTokensGenerated: Int = 0

    // On-Device Gemma 4 E4B Model Download & Readiness State
    @Published public var selectedRuntimeFormat: Gemma4RuntimeFormat = .mlx4BitE4B
    @Published public var hfTokenInput: String = ""
    @Published public var isModelReadyOnDevice: Bool = false
    @Published public var isDownloadingModel: Bool = false
    @Published public var downloadProgressFraction: Double = 0.0
    @Published public var downloadStatusText: String = "Checking on-device model storage..."
    @Published public var showModelManagerSheet: Bool = false

    @Published public var dreamReportSummary: String = "No Dreaming Consolidation run yet in this session."

    public let sessionID = SessionID()
    private var coordinator: AIAgentCoordinator?
    private var consolidator: DreamingConsolidator?
    private var modelDownloader: Gemma4ModelDownloader?
    private var edgeModelProvider: MLXEdgeLLMProvider?

    public init() {
        Task {
            await bootstrapEngine()
        }
    }

    public func bootstrapEngine() async {
        do {
            let rootURL = WorkspaceBootstrapper.resolveDefaultWorkspaceRoot()
            let paths = try WorkspaceBootstrapper.bootstrapWorkspace(at: rootURL)
            let db = try SQLiteWALDatabase(databaseURL: paths.stateDatabaseURL)
            let frozenStore = FrozenMemoryStore(paths: paths)
            let skillService = SkillManagerService(skillsRoot: paths.skillsDir)
            let contextEngine = HybridSQLiteContextEngine(
                database: db,
                frozenMemoryStore: frozenStore,
                skillManager: skillService
            )
            let kvManager = PrefixKVCacheManager(cacheDirectory: paths.kvPrefixCacheDir)
            let downloader = Gemma4ModelDownloader(modelsRootDirectory: paths.modelsDir)
            self.modelDownloader = downloader

            let existingManifest = await downloader.verifiedOnDeviceManifest(forRepoID: selectedRuntimeFormat.rawValue)
            let localDir = existingManifest != nil ? downloader.localDirectory(forRepoID: selectedRuntimeFormat.rawValue) : nil
            let edgeModel = MLXEdgeLLMProvider(
                modelIdentifier: selectedRuntimeFormat.rawValue,
                kvCacheManager: kvManager,
                localModelDirectory: localDir
            )
            self.edgeModelProvider = edgeModel

            if let manifest = existingManifest {
                self.isModelReadyOnDevice = true
                let mb = manifest.totalSizeBytes / 1_000_000
                self.downloadStatusText = "On-Device Ready: \(manifest.repoID) (\(mb) MB, PLE mmap active)"
            } else {
                self.isModelReadyOnDevice = false
                self.downloadStatusText = "Model not yet downloaded. Tap 'Model Weights' to download \(selectedRuntimeFormat.rawValue) to device."
            }

            let router = HybridFailoverRouter(edgeProvider: edgeModel)

            let registry = ToolRegistry(initialTools: [
                JSSandboxTool(),
                MemoryManagerTool(frozenStore: frozenStore),
                SkillManagerToolWrapper(skillService: skillService),
                CalendarAndRemindersTool()
            ])
            let authority = ToolAuthorityRuntime()

            self.consolidator = DreamingConsolidator(
                database: db,
                paths: paths,
                frozenMemoryStore: frozenStore
            )
            self.coordinator = AIAgentCoordinator(
                paths: paths,
                database: db,
                contextEngine: contextEngine,
                modelProvider: router,
                toolRegistry: registry,
                toolAuthority: authority
            )
        } catch {
            self.activeThinking = "Bootstrap Error: \(error.localizedDescription)"
        }
    }

    public func startOnDeviceModelDownload() {
        guard let downloader = modelDownloader, !isDownloadingModel else { return }
        isDownloadingModel = true
        downloadProgressFraction = 0.0
        let format = selectedRuntimeFormat
        let token = hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let manifest = try await downloader.downloadModelToDevice(
                    format: format,
                    hfBearerToken: token.isEmpty ? nil : token,
                    simulateInCI: false
                ) { progress in
                    await MainActor.run {
                        self.downloadProgressFraction = progress.fractionCompleted
                        let dlMB = progress.bytesDownloaded / 1_000_000
                        self.downloadStatusText = "Downloading \(progress.currentFile) (\(progress.completedFilesCount)/\(progress.totalFilesCount)) — \(dlMB) MB"
                    }
                }
                let localDir = downloader.localDirectory(forRepoID: format.rawValue)
                await edgeModelProvider?.bindDownloadedModelDirectory(localDir)
                self.isModelReadyOnDevice = true
                self.isDownloadingModel = false
                self.downloadProgressFraction = 1.0
                self.downloadStatusText = "Verified on device: \(manifest.repoID) (\(manifest.files.count) files, SHA-256 OK)"
            } catch {
                self.isDownloadingModel = false
                self.downloadStatusText = "Download Error: \(error.localizedDescription)"
            }
        }
    }

    public func sendUserPrompt() {
        let trimmed = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let coordinator = coordinator else { return }
        inputPrompt = ""
        isGenerating = true
        activeThinking = ""
        activeStreamingResponse = ""
        liveTokensPerSecond = 0.0
        totalTokensGenerated = 0

        let userMsg = ChatMessage(sessionID: sessionID, role: .user, content: trimmed)
        messages.append(userMsg)

        let inbound = InboundUserMessage(text: trimmed)
        let currentSession = sessionID

        Task {
            do {
                let result = try await coordinator.runConversation(
                    sessionID: currentSession,
                    userMessage: inbound
                ) { event in
                    await MainActor.run {
                        switch event {
                        case .prefixCacheStatus(let hit, let hash, _):
                            self.lastPrefixCacheHit = hit
                            self.lastPrefixHash = String(hash.prefix(10))
                        case .thinkingDelta(let delta):
                            self.activeThinking = delta
                        case .textDelta(let delta):
                            self.activeStreamingResponse += delta
                        case .turnCompleted(let totalTokens, let latencyMs):
                            self.totalTokensGenerated = totalTokens
                            if latencyMs > 0 {
                                self.liveTokensPerSecond = (Double(totalTokens) / (Double(latencyMs) / 1000.0))
                            }
                        case .toolCallRequested, .toolCallCompleted:
                            break
                        }
                    }
                }
                let assistantMsg = ChatMessage(
                    sessionID: currentSession,
                    role: .assistant,
                    content: result.finalResponse,
                    thinking: result.thinkingTrace
                )
                self.messages.append(assistantMsg)
                self.activeStreamingResponse = ""
                self.isGenerating = false
            } catch {
                self.activeThinking = "Turn Error: \(error.localizedDescription)"
                self.activeStreamingResponse = ""
                self.isGenerating = false
            }
        }
    }

    public func triggerDreamingConsolidationNow() {
        guard let consolidator = consolidator else { return }
        Task {
            if let report = try? await consolidator.runDreamingConsolidation() {
                self.dreamReportSummary = "Consolidated \(report.consolidatedChunkCount) chunks -> \(report.dreamFilePath)"
            }
        }
    }
}

public struct AegisMainView: View {
    @StateObject private var viewModel = AegisAppViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Telemetry & On-Device Model Status Bar
                HStack {
                    Label(
                        viewModel.lastPrefixCacheHit ? "KV Prefix: HIT" : "KV Prefix: COLD",
                        systemImage: viewModel.lastPrefixCacheHit ? "bolt.fill" : "flame"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(viewModel.lastPrefixCacheHit ? .green : .orange)

                    if viewModel.liveTokensPerSecond > 0 || viewModel.totalTokensGenerated > 0 {
                        Label(
                            "\(String(format: "%.1f", viewModel.liveTokensPerSecond)) tok/s",
                            systemImage: "speedometer"
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.purple)
                    }

                    Spacer()

                    Button {
                        viewModel.showModelManagerSheet = true
                    } label: {
                        Label(
                            viewModel.isModelReadyOnDevice ? "Gemma 4 Ready" : "Download Model",
                            systemImage: viewModel.isModelReadyOnDevice ? "checkmark.icloud.fill" : "arrow.down.circle.fill"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(viewModel.isModelReadyOnDevice ? .blue : .red)
                    }

                    Spacer()

                    Button("Dream Now") {
                        viewModel.triggerDreamingConsolidationNow()
                    }
                    .font(.caption.bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if viewModel.isDownloadingModel {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: viewModel.downloadProgressFraction)
                        Text(viewModel.downloadStatusText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }

                Divider()

                // Message Stream
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { msg in
                            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 6) {
                                if let thought = msg.thinking, !thought.isEmpty {
                                    DisclosureGroup("Reasoning Trace (<think>)") {
                                        Text(thought)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption.bold())
                                    .padding(8)
                                }
                                Text(msg.content)
                                    .padding(12)
                                    .background(msg.role == .user ? Color.blue.opacity(0.15) : Color.gray.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
                        }

                        if viewModel.isGenerating {
                            VStack(alignment: .leading, spacing: 6) {
                                if !viewModel.activeThinking.isEmpty {
                                    DisclosureGroup("Reasoning Trace (<think>)") {
                                        Text(viewModel.activeThinking)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption.bold())
                                    .padding(8)
                                }
                                HStack(alignment: .bottom, spacing: 6) {
                                    Text(viewModel.activeStreamingResponse.isEmpty ? "Generating on Apple Metal..." : viewModel.activeStreamingResponse)
                                        .padding(12)
                                        .background(Color.gray.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .padding(.bottom, 6)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }

                Divider()

                // Input Composer
                HStack(spacing: 10) {
                    TextField("Ask AegisClaw or run [CALL_JS_SANDBOX: 6 * 7]...", text: $viewModel.inputPrompt)
                        .textFieldStyle(.roundedBorder)
                    Button(action: viewModel.sendUserPrompt) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(viewModel.isGenerating)
                }
                .padding(12)
            }
            .navigationTitle("AegisClaw — Gemma 4 E4B")
            .sheet(isPresented: $viewModel.showModelManagerSheet) {
                NavigationStack {
                    Form {
                        Section("Gemma 4 Edge Runtime Variant") {
                            Picker("Model Format", selection: $viewModel.selectedRuntimeFormat) {
                                ForEach(Gemma4RuntimeFormat.allCases) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                        }
                        Section("Hugging Face Hub Authentication (Optional)") {
                            SecureField("hf_... Bearer Token (only for gated repos)", text: $viewModel.hfTokenInput)
                        }
                        Section("On-Device Status & Transfer") {
                            Text(viewModel.downloadStatusText)
                                .font(.caption.monospaced())
                            if viewModel.isDownloadingModel {
                                ProgressView(value: viewModel.downloadProgressFraction)
                            }
                            Button {
                                viewModel.startOnDeviceModelDownload()
                            } label: {
                                Label("Download Gemma 4 Weights to Device", systemImage: "icloud.and.arrow.down.fill")
                                    .bold()
                            }
                            .disabled(viewModel.isDownloadingModel)
                        }
                    }
                    .navigationTitle("On-Device Model Manager")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                viewModel.showModelManagerSheet = false
                            }
                        }
                    }
                }
            }
        }
    }
}

@main
public struct AegisClawApp: App {
    public init() {}
    public var body: some Scene {
        WindowGroup {
            AegisMainView()
        }
    }
}
#endif
