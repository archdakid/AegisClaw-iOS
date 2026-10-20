---
name: web-research
description: Extracts structured facts and interactive elements from web pages using the headless WebKit DOM Accessibility Distiller.
category: research
version: 1.0.0
---
# WebKit Headless Research Skill

## Procedure
1. Call `browser_harness_tool` with `action: "navigate"` and the target URL.
2. Inspect the distilled Markdown + `[element_id]` interactive snapshot rather than raw HTML to conserve context window tokens.
3. Ground every factual claim with the exact source URL.
