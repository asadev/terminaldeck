---
name: save-session
description: "Save what was learned and decided in this session so the next session (any AI, any seat) starts from it. Use when the person says 'save this session', 'wrap up', 'remember this', 'log this' or at the end of a long stretch of work. Inside Terminal Deck it saves into the seat's Deck Memory with the memory tools."
category: Workflow
---

# Save the session: what the next session must know

A session that ends without saving makes the next one start blind. Save the knowledge, not the transcript.

## Inside Terminal Deck: save into Deck Memory

Use the memory tools, never loose files in the home folder or the AI's own config folder. The app stamps every note with who wrote it and which seat and project it belongs to.

1. **Where we are.** `memory_topic_update` for each piece of work you held: the goal, where it stands now, the decisions and why, the open items, and the exact next step. One topic per piece of work. Pass `done: true` for a topic that is finished.
2. **Decisions, corrections and lessons.** One `memory_note_add` per fact, each understandable on its own, with the right type: `decision`, `preference`, `correction`, `lesson`, `how-to`, `result` or `open-item`. If an older note is no longer true, pass its id as `replaces` instead of adding a contradiction.
3. **Checklists.** Steps that must happen every time go on the seat's checklist with `memory_checklist_add`, not into a note.
4. **A handoff, when asked for one.** `handoff_present` writes a document another person or AI can pick up cold and shows it to the person.
5. Check what you saved with `memory_search`: search for one of your new notes by a couple of its words.

If the memory tools are not available in this session, say so plainly and write the same content into a short `SESSION-NOTES.md` in the project folder instead (newest first), so nothing is lost.

## What to write

- What was done and why.
- Decisions, with the reasoning, not just the outcome.
- The exact state of unfinished work: files touched, commands run, what was checked and what is only assumed.
- The next steps, in order.
- Open questions for the person.

## Rules

- Distil. A short note a fresh AI can act on beats a long recap.
- Absolute dates, never "tomorrow" or "next week".
- Never write a password, token or key into memory or a note. Say where it lives instead.
- Saving twice in one session updates the same topic; it does not start a new one.
- Finish with one line to the person: what was saved and where they can see it (the seat's memory in Terminal Deck).

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "save-session"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
