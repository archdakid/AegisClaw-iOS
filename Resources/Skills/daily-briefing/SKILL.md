---
name: daily-briefing
description: Synthesizes a morning executive briefing combining today's Calendar events, high-priority Reminders, and active Standing Intents.
category: productivity
version: 1.0.0
---
# Daily Executive Briefing Skill

## Procedure
1. Invoke `calendar_and_reminders_tool` with `action: "list_today"` to retrieve all events and incomplete reminders for the next 24 hours.
2. Check active standing intents and recent memory entries from `USER.md`.
3. Present a concise chronological schedule highlighting any back-to-back conflicts, travel buffer warnings, and top 3 action items.
