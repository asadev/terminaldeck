<!--
  Thanks for sending this. Delete any section that genuinely does not apply —
  an honest "not applicable" is better than a box ticked out of politeness.
-->

## What this changes

<!-- One or two sentences. What does the app do now that it did not before? -->

## Why

<!--
  The problem, not the patch. If there is an issue, link it: "Fixes #12".
  If there is no issue and this is more than a small fix, please say why you
  went straight to code — it is not a rule, it just helps to know.
-->

## How to check it

<!--
  Steps a reviewer can follow on their own machine to see the difference.
  Include the starting state: which project, how many sessions, which agent.
-->

## Checks

- [ ] `npm run typecheck` passes
- [ ] `npm test` passes
- [ ] New behaviour has a test, or there is a reason below why it cannot

## Did you look at it

Compiling is not working. Two bugs in this repo shipped a clean typecheck and a
clean console while being visibly wrong on screen.

- [ ] This change is not visible, so there is nothing to look at
- [ ] I ran it and looked at it — in the app, or in the harness
      (`npx vite --config .harness/vite.config.ts`)

<!-- If it is visible, a before/after screenshot is worth the thirty seconds. -->

## Origin of the code

Every line here is written fresh, or its source is named. Pasting in code from
another project — however permissive its licence — pulls that project's licence
and copyright notice permanently into this repository.

- [ ] I wrote this
- [ ] Some of it came from elsewhere, and I have named the source below

## Things this repo is strict about

Only tick the ones your change touches.

- [ ] Colours come from `src/renderer/styles/tokens.css`, no raw hex
- [ ] Any new shortcut is declared in `src/renderer/keymap.ts` and nowhere else
- [ ] The product name is not hardcoded — it lives only in `src/shared/brand.ts`
- [ ] New main-process features export one `registerXIpc(ipcMain)`, and their
      types stay in their own module rather than moving into `shared/types.ts`
- [ ] If the preload changed, `.harness/stub.ts` was updated to match it

## Anything the reviewer should know

<!--
  Loose ends, things you were unsure about, decisions that could reasonably have
  gone the other way. This section is the most useful one in most pull requests.
-->
