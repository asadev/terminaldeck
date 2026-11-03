---
name: overnight-run
description: "Work unattended to a finished result while the person is away (asleep, travelling, in meetings), with one summary at the end. Use when they say 'keep going while I sleep', 'decide yourself', 'don't wait for me' or hand over a job before leaving. Questions are gathered for the end; nothing waits on them."
category: Workflow
---

# Overnight run: they are away, you decide, nothing stalls

## Before they leave

1. Ask every question you need now, in one short numbered list. After they are gone you decide everything yourself.
2. Write the plan down where a crash cannot lose it: inside Terminal Deck as the "where we are" topic (`memory_topic_update`), otherwise a `PLAN.md` in the project. Include what "finished" means.
3. Agree what you may NOT do without them (for example: publish, deploy, spend money, delete data, email people). Everything else is yours to decide.

## While they are away

4. Work through the plan without stopping. When one piece is done, start the next. Being found idle, waiting for an answer, is the failure to avoid.
5. Split independent pieces across parallel sessions or agents when you can, each in its own branch or copy so they do not collide.
6. Blocked? Try a different way first: another tool, another approach, another layer. Only if that also fails, park the item and move on.
7. Questions that only the person can answer (a password, a code, a choice that is really theirs) go on a list for the end. They never block the rest of the work.
8. Record each decision you make on their behalf, with one line of why, as you go (`memory_note_add` with type `decision` inside Terminal Deck).
9. If something crashes or the session is lost, pick up where it stopped (the `recover` skill), never from zero.
10. Keep the "where we are" topic up to date as you go, not only at the end.

## At the end

11. One final check of everything together: build, tests, and actually look at the result (open it, click through it). Fix what that finds.
12. Do not publish, deploy or release unless they said so before leaving. If you do, report each stage live with deploy_start, deploy_step (each step, its tool and result) and deploy_finish.
13. Leave the result ready to look at: the app running, the page open, the document in front of them. Only one copy of it, the newest.

## When they come back

Lead with one short summary table:

| Done | Still running | Left | Needs you |
|------|---------------|------|-----------|

Under "Needs you", a numbered list with exact steps (where to click, what to type). Short, plain words. Then the decisions you made for them, one line each.

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "overnight-run"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
