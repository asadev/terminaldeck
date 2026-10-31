---
name: options-gallery
description: "Build several genuinely different options for the person to choose from: designs, layouts, logos, names, copy, animations, approaches. Use when they say 'show me some options', 'make a few versions', 'I will choose' or anything that is their pick to make. They choose; never pick for them."
category: Design
---

# Options gallery: different ideas, their pick

## 1. Make options that are really different

- Each option is a different idea: a different approach, structure or mechanism, not the same idea in other colours or fonts.
- If the person rejected a round, the ideas from that round are out. Do not bring them back slightly changed.
- Three to six options is usually right unless they asked for a number.

## 2. Keep them where they will survive

Build the options inside the project (for example a dated `options/<topic>-<date>/` folder), never only in a temporary folder: the person may take days to choose, and a temporary folder can be cleared. Add a short README that says how to open them again.

## 3. Show them side by side

- Make one index page (or one document) that shows every option, each with a one-line plain description of how it behaves or what makes it different. Not "Option A/B/C" alone.
- If they need a local web server to view, start it on a free port (for example `python3 -m http.server 0 --bind 127.0.0.1`, then read the port it chose) and give the exact link. Never assume a fixed port is free.
- Inside Terminal Deck, open the page in the app's own browser panel so the person sees it beside the session.
- Check every option renders before handing over: open it, look at it, fix what is broken.

## 4. Present, then wait

Give a short numbered list with the link to each. Then wait. Do not apply one "to save time", and do not say which one you would pick unless asked.

## 5. When they choose

- Apply only the chosen option.
- Keep the others where they are (archived, never deleted), so "the one from before" can be brought back exactly.
- Once an option is approved, it is frozen: try further changes on a copy, never on the approved version itself.

## Text in options

Write as if it is real: confident, specific, true. No invented numbers, testimonials or stock filler.

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "options-gallery"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
