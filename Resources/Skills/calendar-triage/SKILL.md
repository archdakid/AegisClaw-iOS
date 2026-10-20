---
name: calendar-triage
description: Resolves scheduling conflicts, proposes free time slots, and creates or updates calendar appointments safely.
category: scheduling
version: 1.0.0
---
# Calendar Triage & Conflict Resolution Skill

## Procedure
1. Always inspect existing events in the requested window via `calendar_and_reminders_tool(action: "list_window")` before creating or moving an event.
2. Verify that at least 15 minutes of transition buffer exists around travel events.
3. Request confirmation via `ToolAuthority` before committing mutations to `EKEventStore`.
