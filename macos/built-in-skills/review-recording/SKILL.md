---
name: review-recording
description: "Turn a screen recording (a .mov or .mp4 where the person shows and says what they want) into a numbered list of every ask, then build it and check each item against their words. Use when they drop a recording or say 'watch this' or 'list everything I asked'. Uses only what this computer has: speech is transcribed only when a transcription key is set."
category: Workflow
---

# Review a recording: every ask, numbered, built, checked

If the person says more parts are coming, wait for all of them before listing anything.

## 1. Take the recording in

- **The file.** Recordings often have unusual characters in their names (a narrow space before "PM", for example). Find the file with a wildcard (`ls ~/Desktop/*Recording*`) and use the name the system gives back, rather than retyping it.
- **What they said.** Transcribe the speech only with what this computer already has:
  - if `OPENAI_API_KEY` is set, use OpenAI's current speech-to-text model;
  - otherwise, if `ELEVENLABS_API_KEY` is set, use ElevenLabs speech-to-text (good for languages other than English);
  - if neither is set, skip transcription cleanly: say once that there is no transcription key, and work from the frames, the text on screen and the person's own message. Do not install a speech model or ask for a key in the middle of the job.
  - Never send the recording anywhere else.
  - To send only the sound, extract it first if `ffmpeg` is available (`ffmpeg -i in.mov -vn -ac 1 -ar 16000 out.m4a`).
- **What they showed.** Take frames, for example one every 5 to 10 seconds plus one at every scene change (`ffmpeg -i in.mov -vf "fps=1/5" frames/%04d.png`), skip identical ones, and look at all of them, not a sample. If `ffmpeg` is not installed, use whatever this computer offers to read frames, or ask the person for screenshots once.

## 2. List every ask

- Write a numbered list: one item per thing they asked for, each with their own words (from the transcript or what was on screen) under it. Include questions they asked; those need answers, not code.
- Also read their messages from the same time for extra asks.
- Save the list in the project (for example `reviews/<date>/ASKS.md`), or inside Terminal Deck as an open-items note (`memory_note_add`, type `open-item`).
- Show the numbered list to the person. They will refer to items by number.

## 3. Build it

- Build exactly what the list says. Nothing invented, nothing quietly skipped. If you must skip an item, say which and why; that choice is theirs.
- Independent items can go to parallel sessions or agents, each in its own branch or copy.
- Ask only when there is a real choice only they can make, and build the clear items while you wait.

## 4. Check against their words

Go through every numbered item: **done exactly / done differently / missing**, with their quote beside it. Fix anything that differs from what they said, the way they said it.

## 5. One final check, then hand back

- Build, run the tests, and look at every changed screen yourself (open it, click it).
- Do not publish or release unless they said to.
- Leave the newest version open in front of them, one copy only.
- Close with one short summary: done (by number), left, and anything that needs them, with exact steps.

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "review-recording"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
