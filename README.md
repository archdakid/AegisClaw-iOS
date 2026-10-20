# Antigravity (Gemini 3.8 Flash High) Build, xtool iPhone Deployment & GitHub CI Manifest — AegisClaw iOS (Gemma 4 E4B Edition)

This repository contains the complete, strict-concurrency **Swift 6.0** source code, **`xtool` configuration (`xtool.yml`, `Config/XtoolInfo.plist`, `.bsp/xtool.json`)**, **XcodeGen (`project.yml`)** project specification, entitlements, on-device **Hugging Face Hub model downloader (`Gemma4ModelDownloader`)**, seed `SKILL.md` files, headless WebKit DOM distiller script, **GitHub Actions CI workflow**, and **8-test XCTest integration suite** for **AegisClaw iOS**—unifying Nous Research's **Hermes Agent** and **OpenClaw** into an on-device Edge LLM and agentic personal assistant powered by **Google's Gemma 4 E4B** (`google/gemma-4-E4B-it` / `unsloth/gemma-4-E4B-it-UD-MLX-4bit` / `litert-community/gemma-4-E4B-it-litert-lm`) on iOS 18+.

---

## 1. Installing to iPhone with `xtool` (Linux, Windows WSL2, or macOS)

This repository is natively structured for **[xtool](https://xtool.sh/documentation/xtool/)** ([`xtool-org/xtool`](https://github.com/xtool-org/xtool)) so you can build, sign, and install **AegisClaw** directly onto a physical iPhone over USB from **Linux, Windows (WSL2), or macOS** without needing the Xcode IDE.

### How `xtool` Packaging Works in This Repository
- **`Package.swift`**: Exports the primary `.library(name: "AegisClaw", targets: ["AegisClawApp"])` product containing `@main public struct AegisClawApp: App` and linking all 6 core modules (`AegisCore`, `AegisEdgeLLM`, `AegisContextMemory`, `AegisHarness`, `AegisTools`, `AegisGateway`).
- **`xtool.yml`**: Declares `version: 1`, `bundleID: com.aegisclaw.ios`, `product: AegisClaw`, `infoPath: Config/XtoolInfo.plist`, and bundles `Resources/Skills` and `Resources/JS` into the root of `AegisClaw.app`.
- **`Config/XtoolInfo.plist`**: Provides a clean, macro-free overlay plist (`CFBundleDisplayName`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `UIBackgroundModes`, `BGTaskSchedulerPermittedIdentifiers`, and iOS privacy strings) so `xtool` merges keys cleanly without unexpanded Xcode `$(EXECUTABLE_NAME)` variables.
- **`.bsp/xtool.json`**: Configures the Build Server Protocol (`xtool dev build-server`) for SourceKit-LSP code completion in VSCode, Cursor, and Antigravity.

### Step-by-Step iPhone Installation via `xtool`

#### A. Install `xtool` & One-Time SDK Setup
- **On macOS**:
  ```bash
  brew install xtool-org/tap/xtool
  xtool setup
  ```
- **On Linux / Windows WSL2 (Ubuntu/Debian)**:
  ```bash
  sudo apt-get update && sudo apt-get install -y usbmuxd libimobiledevice-utils
  curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
  chmod +x xtool && sudo mv xtool /usr/local/bin/
  # Run one-time setup (authenticate with Apple ID API Key [0] or Password [1], and pass path to downloaded Xcode.xip)
  xtool setup
  ```
  *(On Windows WSL2, attach your USB-connected iPhone to WSL from an Administrator PowerShell prompt via `usbipd list` -> `usbipd bind --busid <BUSID>` -> `usbipd attach --wsl --busid <BUSID>`, then verify inside WSL with `ideviceinfo`.)*

#### B. Build, Sign & Deploy to Connected iPhone (`xtool dev`)
From the root of `AegisClaw-iOS`:
```bash
# Compiles AegisClaw for arm64-apple-ios, provisions & signs with your Apple ID, and installs over USB to your iPhone:
xtool dev
```
- **First-Time iPhone Trust**:
  1. When prompted on your iPhone, tap **Trust This Computer** and enter your passcode.
  2. Ensure **Developer Mode** is enabled on your iPhone (**Settings -> Privacy & Security -> Developer Mode**).
  3. If using a free Apple ID (Mode 1), trust your developer certificate under **Settings -> General -> VPN & Device Management -> [Your Apple ID] -> Trust**.
- **Alternative — Build Standalone `.ipa` or `.app` Bundle**:
  ```bash
  # Build ./xtool/AegisClaw.app without deploying
  xtool dev build

  # Package a standalone ./xtool/AegisClaw.ipa archive
  xtool dev build --ipa
  ```

---

## 2. Gemma 4 E4B Edge Runtime & On-Device Downloader Configuration

- **Primary MLX 4-Bit Model ID**: `unsloth/gemma-4-E4B-it-UD-MLX-4bit` (Apple Silicon Metal 4-bit dynamic quantization)
- **Canonical Base Model**: `google/gemma-4-E4B-it`
- **Alternative Runtime Formats Supported in `Gemma4RuntimeFormat`**:
  - **LiteRT-LM (iOS/Android)**: `litert-community/gemma-4-E4B-it-litert-lm`
  - **GGUF (llama.cpp Metal)**: `unsloth/gemma-4-E4B-it-GGUF`
  - **Low-Memory Fallback (E2B)**: `unsloth/gemma-4-E2B-it-UD-MLX-4bit`
- **On-Device Model Downloader (`Gemma4ModelDownloader` in `AegisEdgeLLM.swift`)**:
  1. **Hugging Face Hub API Discovery**: Queries `https://huggingface.co/api/models/<repo_id>` to resolve `.safetensors`, `.litertlm`, `.gguf`, `config.json`, and `tokenizer.json` files (with a deterministic fallback manifest when offline).
  2. **APFS Free Disk Space Guard**: Verifies `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` (≥ 3.0 GB for E4B; ≥ 1.6 GB for E2B) before starting transfers.
  3. **Resumable HTTP Range Transfers & SHA-256 Integrity**: Streams weights to `/workspace/models/<repo_id>/`, resumes interrupted `.part` files using HTTP `Range: bytes=<offset>-`, verifies SHA-256 digests, and writes `model_manifest.json`.
  4. **SwiftUI Model Manager Sheet**: `AegisMainView` includes a live **"Download Model / Gemma 4 Ready"** toolbar button and sheet with variant picker, optional `hf_...` Bearer token field, and real-time `ProgressView`.

---

## 3. Complete Repository File Manifest (22 Files)

| File Path | Architectural Subsystem & Purpose |
| :--- | :--- |
| `xtool.yml` | **[xtool](https://xtool.sh/documentation/xtool/control/)** declarative app bundle configuration (`bundleID: com.aegisclaw.ios`, `product: AegisClaw`, `infoPath: Config/XtoolInfo.plist`, and bundled `Resources`). |
| `Config/XtoolInfo.plist` | Clean, macro-free `Info.plist` overlay for `xtool` (`CFBundleDisplayName`, `UIFileSharingEnabled`, `UIBackgroundModes`, `BGTaskSchedulerPermittedIdentifiers`, and privacy usage descriptions). |
| `.bsp/xtool.json` | Build Server Protocol configuration enabling `xtool dev build-server` for SourceKit-LSP in VSCode, Cursor, and Antigravity. |
| `Package.swift` | Swift 6.0 package manifest defining the `AegisClaw` app library product (for `xtool`), `AegisClawKit` umbrella product (for XcodeGen), 6 modular core targets, `AegisClawApp` target, and `AegisClawTests`. |
| `project.yml` | **XcodeGen** specification that deterministically generates `AegisClaw.xcodeproj` for iOS 18.0. |
| `Config/AegisClaw.entitlements` | Declares `com.apple.developer.kernel.increased-memory-limit`, `com.apple.developer.kernel.extended-virtual-addressing`, and App Group `group.com.aegisclaw.shared`. |
| `Config/Info.plist` | Full Xcode `Info.plist` for `project.yml` builds. |
| `.github/workflows/ios-ci.yml` | Hardened GitHub Actions workflow (`macos-15` / Xcode 16+) that lints plist/xtool configs, runs `swift build` & `swift test --parallel`, compiles the `xtool` `AegisClaw` scheme for iOS Simulator, and builds `AegisClaw.xcodeproj`. |
| `Sources/AegisCore/AegisCore.swift` | Core value types (`SessionID`, `TurnID`, `AdmittedRunContext`, `TurnBudgetLimits`), `WorkspaceBootstrapper` (creating `/workspace/models/` and seeding `config.yaml`), `KeychainVault`, and SHA-256 data/string utilities. |
| `Sources/AegisEdgeLLM/AegisEdgeLLM.swift` | `Gemma4E4BConfiguration`, **`Gemma4ModelDownloader`** (Hugging Face Hub downloader, HTTP Range resume, SHA-256 manifest verification), `PrefixKVCacheManager`, `MLXEdgeLLMProvider`, and `HybridFailoverRouter`. |
| `Sources/AegisContextMemory/AegisContextMemory.swift` | Native `SQLiteWALDatabase` actor (Schema v31, WAL mode, FTS5 `messages_fts`, `turn_leases`, `tool_execution_journal`, `memory_chunks`, `standing_intents`), `ANEEmbeddingService`, `FrozenMemoryStore`, `SkillManagerService` + `SkillGuardScanner`, and `DreamingConsolidator`. |
| `Sources/AegisTools/AegisTools.swift` | Strict-concurrency-safe `ToolAuthorityRuntime`, OpenClaw `FSBridge`, `JSSandboxTool`, `MemoryManagerTool`, `SkillManagerToolWrapper`, `CalendarAndRemindersTool`, and `ToolRegistry`. |
| `Sources/AegisHarness/AegisHarness.swift` | `ToolRoundExecutor` (Persist-Before-Execute SQLite WAL journal, read-call deduplication, 4,000-char output truncation with disk overflow, 3-strike runaway loop guard) and `AIAgentCoordinator` (`runConversation`). |
| `Sources/AegisGateway/AegisGateway.swift` | `SenderQuarantineGate` (6-digit pairing verification) and `HermesOpenClawMigrator` (`~/.hermes` and `~/.openclaw` workspace importer). |
| `Sources/AegisClawApp/AegisClawApp.swift` | SwiftUI iOS 18 application (`AegisClawApp`, `AegisMainView`, `AegisAppViewModel`) with **On-Device Model Manager Sheet** and live download progress bar. |
| `Resources/Skills/*/SKILL.md` | Seeded `agentskills.io` procedural skills (`daily-briefing`, `calendar-triage`, `web-research`). |
| `Resources/JS/DOMAccessibilityDistiller.js` | Injected script for headless `WKWebView` DOM & Accessibility snapshot distillation. |
| `Tests/AegisClawTests/AegisClawTests.swift` | 8-test end-to-end XCTest suite verifying Gemma 4 E4B configuration, on-device model downloading & SHA-256 manifest verification, WAL mode, Schema v31, FTS5 BM25 recall, Frozen Memory Prefix KV-Cache invariance, Durable Turn Leases, Persist-Before-Execute crash recovery, `SkillGuardScanner`, `FSBridge`, and Dreaming Consolidation. |

---

## 4. Instructions for Antigravity Agent (Step-by-Step Execution)

### Step 1: Materialize the Repository Tree
```bash
# Option A: Extract from zip archive
unzip AegisClaw-iOS-Repository.zip -d AegisClaw-iOS
cd AegisClaw-iOS

# Option B: Materialize via the self-contained Python bootstrapper
python3 bootstrap_aegisclaw_repo.py --output-dir ./AegisClaw-iOS
cd AegisClaw-iOS
```

### Step 2: Deploy to iPhone via `xtool` or Verify Locally
```bash
# Deploy directly to USB-connected iPhone via xtool (Linux / WSL2 / macOS):
xtool dev

# Or run the Swift 6 test suite & Simulator verification (macOS / GitHub Actions):
swift build
swift test --parallel
xcodebuild build -scheme AegisClaw -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""
```

### Step 3: Initialize Git & Push to GitHub to Trigger CI
```bash
git init
git checkout -b main
git add .
git commit -m "feat: AegisClaw iOS Edge LLM & Agentic Harness with Gemma 4 E4B and xtool support"
git remote add origin https://github.com/<YOUR_GITHUB_ORG_OR_USER>/AegisClaw-iOS.git
git push -u origin main
```
