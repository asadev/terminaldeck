---
name: project-setup
description: "Set up a Terminal Deck project with the person by chat, the same steps as the New project guide: name and look, home folder, lead, team, skills, project card, connections. Use when the person says 'set up a project', 'make this a project', 'help me finish setting up', or picks Set up with Hoot in the guide."
category: Workflow
---

# Set up a project, step by step

A folder opened on its own is only a plain session. A project is set up on purpose: it gets a name, a home folder, a lead, a team, skills and a card the lead reads first. Walk the person through it the way the New project guide does, by chat.

## How to talk while doing it

- One step at a time. Ask only what you need for that step; offer a sensible default so the person can just say yes.
- Before each step, say in one plain sentence why it matters (`project_setup_guide` has that sentence for every step).
- Only the name and the home folder are required. Every other step can be skipped; say so, and move on when the person skips.
- Never ask for a password, token or key in chat. Where one is needed, the person types it in the app (see Connections).
- Do the work with the tools; do not tell the person to click something you can do yourself.

## Before you start

1. Call `project_setup_guide` once: the steps, why each matters, and the tools for each.
2. For an existing project, call `project_setup_status` with its id and do only the parts listed as missing.
3. If the person would rather click through it, `project_setup_open` shows the same guide on their screen (at a step, for an existing project).

## The steps

1. **Name and look.** Ask for the name and one line on what the project is. Create the project with `project_registry_save` (an id of lowercase letters, digits and dashes, the name, the folders). Save the line with `project_settings_set` (values `{"about": "<line>"}`). A logo is optional: an image file path goes in `project_registry_save` as `logo`.
2. **Home folder.** Ask which folder holds the project, or offer to use one you find with `projects_browse`. Put it in the project's folders, then open it with `projects_add` so sessions and tools can work there. A folder that already belongs to another project cannot be used twice.
3. **Lead.** Explain that the lead runs the project's agents: you give it goals, it hands out the work and reports back. Offer three choices: a new agent (`tasks_agents` save with this project's id, then `project_registry_set_lead` with `agent:<id>`), an existing agent (`project_registry_set_lead`), or you lead for now (`project_settings_set` values `{"setup.hootLeads": true}`).
4. **Team.** Ask which roles the project needs (for example iOS engineer, reviewer). Each role is a seat with its own memory; memory belongs to the seat, not to the agent. Save each agent with `tasks_agents` (save, with this project's id and its role as `seat`; several at once with save-many). Agent files already in the folder's `.claude/agents` can be brought in with `tasks_agents_import`.
5. **Skills.** List what is available with `skills_list` and suggest the ones each role needs. If a skill clashes with an AI command, offer `skills_rename` first. Create new skills with `skills_create`, which refuses reserved command names. Give them with `skills_assign`.
6. **Project card.** Draft the lead's card from what you learned: goals, top rules, key facts (what the project is, where it lives). Show the draft, then save it with `memory_card_save` on the seat `lead:<project id>`.
7. **Connections** (optional). GitHub: check with `github_state`; to connect, `github_connect` starts the sign-in (the person confirms a code on GitHub), then save the repository as `project_settings_set` values `{"githubRepo": "owner/name"}`. A task system: `connected_tasks_systems` lists the connected ones. Connecting a new one (`connected_tasks_connect`) needs an access token the person makes in that system, and a token never goes through chat, so open the guide at its Connections step (`project_setup_open`, step `connections`) for them to paste it there; then save the choice as `taskSystem`. Servers: `servers_look` lists saved servers; save the ones this project uses as `linkedServers` (names, comma separated); adding a new server is done in the app (Servers, Add a server).

## Finish

Call `project_setup_status` for the project and end with one short message: the setup score ("Setup 83%"), what is set, and what is still missing with one line each on how to add it later (the project page shows the same list).

## Inside Terminal Deck: show your steps and your answer

- As you start each numbered step above, call `flow_applied` with `skill: "project-setup"`, `step` (its number) and `stepTitle` (its few words), so the person sees this skill's steps tick by in their job flow. Outside Terminal Deck, skip this.
- When you report to the person, put every decision you need from them in a `:::needs-you` box as a numbered list, finished work in a `:::done` box, and what still runs elsewhere in a `:::waiting` box (each box ends with a line `:::`). Three or more items go in a table.
