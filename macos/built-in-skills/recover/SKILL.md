---
name: recover
description: "Pick up after a crash, a closed laptop, a lost conversation or an interruption, from exactly where the work stopped. Use when the person says 'continue', 'where were we', 'you died mid-way', 'back' or 'stuck?' after a break. Never restart from zero and never redo finished work."
category: Workflow
---

# Recover: find where it stopped, carry on from there

The person should never pay twice for the same work. Before doing anything new, find out what was already done.

## 1. Find where the work stopped

Look in this order and stop as soon as the picture is clear:

1. **Inside Terminal Deck:** your memory first. `memory_search` for the job, read the open "where we are" topic for it and the last decision notes, and `memory_board_read` for what each session, agent and task was doing and what waits for the person. If a moment is unclear, `memory_diary_read` opens the conversation around it word for word.
2. **The project itself:** `git status`, `git log -5`, the branches and worktrees, half-written files, notes or plans saved in the project.
3. **Anything still running:** background jobs, dev servers, builds, test runs, other sessions or agents. A job that is still running is not a job to start again.
4. **The last messages of the conversation**, if any survived.

## 2. Deliver what was lost first

If an answer was being written when things stopped, the person never saw it. Give it to them first, short.

## 3. Continue, don't redo

- Carry on each unfinished piece from its exact stopping point, with the same plan it had.
- Work that finished stays finished. Check it is really there (the file, the commit, the result), then move on.
- If a step failed only because the machine was overloaded or the connection dropped, run it again once, quietly, before treating it as a real failure.
- Temporary folders may have been cleared by a restart. Rebuild what lived there from the project, the notes or the conversation rather than starting the whole job over.

## 4. Tell the person in a few plain lines

What was recovered, what is continuing now, and what (if anything) was lost and has to be redone. Then keep working. Do not ask for permission to continue work they already asked for.

## 5. Leave a trail for next time

Inside Terminal Deck, update the "where we are" topic for this job with `memory_topic_update` as you go, so the next interruption costs nothing.

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "recover"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
