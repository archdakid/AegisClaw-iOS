---
name: aegisclaw-baseline
description: >-
  Maintain, update, and consult the AegisClaw iOS proven working baseline ledger, device configurations,
  CI milestones, and on-device inference outputs for iPhone 15 Pro. Use this skill whenever testing,
  debugging regressions, updating build configurations, or verifying physical device telemetry.
---

# AegisClaw Baseline & Regression Guard Skill

This skill governs the recording, verification, and regression-testing of proven configurations for AegisClaw iOS running on physical Apple Silicon hardware (iPhone 15 Pro, A17 Pro, 8 GB RAM).

## Key Principles

1. **Never Assume — Always Check the Baseline**:
   Before modifying project targets, schemes, MLX parameters, or build scripts, reference the baseline in [`SUCCESSFUL_BASELINE_REFERENCE.md`](file:///C:/Users/chadj/.gemini/antigravity/brain/a28192a2-8ca6-44bf-85bf-179699ba2281/SUCCESSFUL_BASELINE_REFERENCE.md).

2. **Scheme Uniqueness Rule**:
   In `Package.swift`, the library product must NEVER have the same name as the XcodeGen application target (`AegisClaw`). The package product is named `AegisClawLib` so `xcodebuild -scheme AegisClaw` unambiguously targets `AegisClaw.app`.

3. **No Swallowed Diagnostics**:
   Every failure in MLX container loading, token generation, or turn execution must stream visibly into the assistant's chat bubble with `⚠️` and full error details. Never allow `isGenerating = false` to suppress diagnostic state.

4. **Telemetry Visibility**:
   The telemetry pill (`activeRequestStatus` and `tok/s` token count) in `AegisMainView` must remain visible at all times, independent of whether active generation is currently in-flight.

---

## Proven Device Configuration

- **Hardware**: iPhone 15 Pro (A17 Pro, 8 GB unified RAM)
- **UDID**: `00008130-00010C2411E0001C`
- **Apple ID**: `quincearch@gmail.com`
- **Team ID**: `SCP973FPJ3`
- **Provisioning Profile**: `W5P5XX952C`
- **Sideloading Tool**: `xtool 1.22.0` in WSL2 Ubuntu (`scripts/sideload-ipa.ps1` via `scripts/repack_clean.py`)

---

## When to Update the Baseline Ledger

Update [`SUCCESSFUL_BASELINE_REFERENCE.md`](file:///C:/Users/chadj/.gemini/antigravity/brain/a28192a2-8ca6-44bf-85bf-179699ba2281/SUCCESSFUL_BASELINE_REFERENCE.md) whenever:
- A CI workflow completes with a new green build or notable failure.
- A new on-device test produces verified metrics (tokens/sec, latency, memory usage).
- A dependency version or build flag changes (`Package.swift`, `project.yml`, `xtool.yml`).
- A new model format is evaluated (MLX 4-bit, LiteRT FlatBuffer, GGUF).
