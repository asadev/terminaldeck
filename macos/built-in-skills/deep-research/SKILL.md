---
name: deep-research
description: "Do proper, sourced research and end with a clear recommendation. Use when the person asks to 'research it properly', compare options, check a market, a vendor, a rule or a technical choice, or wants brainstorming based on real information. Not for quick questions: those get a direct answer."
category: Research
---

# Deep research: real sources, a clear recommendation

## 0. Is this research at all?

If the question has a short, well-known answer, just answer it. Research costs the person time and money; spend it only when the answer matters and is not obvious.

## 1. Pin the question

In one short exchange (or from what they already said), get clear on:
- what decision this research feeds,
- what "good" looks like for them (budget, timeline, place, level of detail),
- what they already know or have ruled out.

Frame it at the person's level. Research aimed at the wrong question wastes the whole run.

## 2. Gather from real sources

- Prefer primary sources: official documentation, pricing pages, laws and regulators, the vendor's own announcements, original data.
- Use several independent sources for every claim the recommendation depends on. When sources disagree, say so and say which you trust and why.
- Note the date of each source. Prices, rules and products change; say "as of" for anything time-sensitive.
- If you can run work in parallel (several agents or sessions), split the question into independent parts and have one part try to disprove the leading answer.
- Never invent a number, a quote or a link. If you could not find something, say that.

## 3. Write it down once

Put the findings in one document the person can come back to: in the project folder (for example `research/<topic>.md`), or inside Terminal Deck as a note with `memory_note_add` (type `result`) plus a link to the document. One source of truth, not several drafts.

## 4. Report in the conversation, not just a file path

1. **The verdict first**, in two or three plain sentences: what you recommend and why.
2. **The options, ranked**, each with its main strength, main risk and rough cost.
3. **Risks and unknowns** that could change the answer.
4. **Sources** as clickable links with dates.

A clear "this will not work, here is why" is more useful than a soft maybe.

## 5. Afterwards

- Answer follow-up questions from the research already done; do not run it all again.
- Wait for the person's choice before building anything based on it.

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "deep-research"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
