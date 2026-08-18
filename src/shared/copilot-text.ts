/**
 * Sentences about the copilot's folder that both sides of the app have to say
 * in the same words.
 *
 * In `shared/` rather than in `main/copilot-folder.ts` because there are two
 * surfaces that must not disagree: the native folder panel, whose `message` the
 * main process sets, and the Settings pane, which says it again beside the
 * button that opens the panel. Two copies of a sentence about what an agent can
 * read is two copies that can drift, and the one that drifts is always the one
 * nobody reread.
 */

/**
 * What choosing a folder actually means, said before somebody chooses.
 *
 * A chosen folder may hold credentials — `~/ClaudeAsad/credentials/` does, and
 * that workspace's own instructions say so. This is **not a new exposure**: any
 * session started in that directory reads the same files, and the copilot is an
 * ordinary session running as the person. But it is a thing to be *chosen*
 * rather than discovered, which is the whole reason this string exists.
 *
 * It is the general fact, always shown, and there is deliberately no scanner
 * behind it. A heuristic looking for `.env` or a directory called `credentials`
 * would be wrong in both directions — it would miss `notes/passwords.md` and
 * flag a repository whose `.env.example` holds nothing — and a warning that
 * fires on the wrong folders teaches somebody to dismiss it before the one that
 * matters.
 *
 * It said "the folder's own CLAUDE.md" until the naming sweep. The copilot is
 * whichever agent the person picked, and each of them reads a differently-named
 * file out of that folder, so the old sentence was both branded and — for two
 * of the three agents this build ships — factually wrong about which file it
 * would read. "Its instructions and memory" is the category, it is true of all
 * of them, and it stays true of the next one.
 */
export const CHOOSING_A_FOLDER =
  'The copilot works in this folder as you would: it reads the folder’s own instructions and ' +
  'memory, and anything else in it — including any credentials kept there. That is the same ' +
  'access any session you start in that folder already has. Nothing of this app’s is ever ' +
  'written into it.'

/**
 * Why changing the folder needs a restart, in one sentence.
 *
 * A working directory is fixed at `exec`. Nothing in this app can move a running
 * process, so nothing in this app may imply that it can — this is the third time
 * this feature has had to be stopped from describing something it does not do,
 * and the other two are written up in `copilot-home.ts`.
 */
export const FOLDER_NEEDS_A_RESTART =
  'A session’s folder is fixed when it starts, so this takes effect the next time the copilot ' +
  'starts. The one running now keeps working where it began.'
