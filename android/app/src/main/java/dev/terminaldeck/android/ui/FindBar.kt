package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.termux.view.TerminalView
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * Finding a line in a session's scrollback, from a phone.
 *
 * The desktop has had a search panel since the first week; the phone had nothing, and the phone is
 * where it matters more — a laptop shows eighty columns and fifty rows at once, this shows about
 * fifty by thirty-five, so the same agent run that is one screen on a Mac is several screens of thumb
 * scrolling here. *"Where did it print the port number"* is the question people open this app to
 * answer. `ios/TerminalDeck/Terminal/TerminalFind.swift` is the sibling and carries the shared
 * reasoning; this is its Android half, with the one difference the two emulators force.
 *
 * ## The search is ours, because Termux has none
 *
 * SwiftTerm hands iOS `findNext`/`findPrevious`/`searchMatchSummary` against its own buffer. Termux
 * exposes no such thing, so this walks the buffer itself: every row from the oldest line of
 * scrollback ([TerminalBuffer.getActiveTranscriptRows] rows up) to the bottom of the screen, read
 * one row at a time through the same `getSelectedText` that Copy uses, matched case-insensitively.
 * A row at a time rather than the whole transcript joined, because the row is what a scroll needs:
 * the match has to be brought *onto the screen*, and only a row number can do that.
 *
 * ## The first match is the newest one
 *
 * Typing lands on the **last** match — the bottom-most, most recent one — because on a terminal the
 * occurrence that matters is almost always the last error, the port this run bound to, the file the
 * agent just wrote. So the down arrow ([later]) walks towards newer output and the up arrow
 * ([earlier]) walks back into history, which is also the direction the two arrows look like they
 * should move against a scrollback that grows downwards. The counter is read from the **top** —
 * "12 of 17" — because that is where you are in the whole buffer.
 *
 * ## What it does and does not do
 *
 * It **scrolls the match onto the screen** and **counts** — [status] is the "3 of 17" the bar shows.
 * It does **not** paint a highlight on the matched text: Termux's selection is driven by touch
 * handles through a controller that wants a `MotionEvent`, and standing one up from a row/column
 * would be a second, worse feature. The match is centred instead, which is what a thumb needs to
 * read it. Live output while the bar is open can shift row numbers under a snapshot taken on the last
 * keystroke; the count is retaken on every keystroke, which is when it matters.
 */
class TerminalFindSession(
    private val binding: RemoteSessionBinding,
    private val view: TerminalView,
) {
    /** What has been typed. The bar draws the counter only once this is non-empty. */
    var term by mutableStateOf("")
        private set

    /** 1-based position of the current match counted from the top, or 0 when nothing matches. */
    var index by mutableIntStateOf(0)
        private set

    /** How many matches in the whole buffer. */
    var total by mutableIntStateOf(0)
        private set

    /** The external row of each occurrence, top to bottom — one entry per match, for the scroll. */
    private var rows: List<Int> = emptyList()

    /** Index into [rows] of the match the view is parked on, or -1. */
    private var current = -1

    val hasTerm: Boolean get() = term.isNotEmpty()
    val hasMatches: Boolean get() = total > 0

    /**
     * What the counter reads — one string rather than three branches in the view, because it is the
     * part worth asserting. Empty before anything is typed, so a fresh bar does not accuse the user
     * of finding nothing; "No matches" in the warning colour when a term finds none.
     */
    val status: String
        get() = when {
            !hasTerm -> ""
            total == 0 -> "No matches"
            else -> "$index of $total"
        }

    /**
     * The term changed — every keystroke restarts the search from the bottom rather than walking on
     * from the last match, which with a term still being typed would leave you on whichever `e` came
     * first by the time you had typed `error`.
     */
    fun type(text: String) {
        term = text
        recompute()
        current = if (rows.isEmpty()) -1 else rows.lastIndex
        settle()
    }

    /** Further back in the scrollback — older output. Wraps, so it never goes dead on the first match. */
    fun earlier() = step(-1)

    /** Forwards again — newer output. Wraps at the last match back to the first. */
    fun later() = step(+1)

    private fun step(delta: Int) {
        if (rows.isEmpty()) return
        current = ((current + delta) % rows.size + rows.size) % rows.size
        settle()
    }

    private fun settle() {
        index = if (current >= 0) current + 1 else 0
        scrollToCurrent()
    }

    private fun recompute() {
        val emulator = binding.session.emulator
        val needle = term.lowercase()
        if (emulator == null || needle.isEmpty()) {
            rows = emptyList()
            total = 0
            return
        }
        val screen = emulator.getScreen()
        val cols = emulator.mColumns
        val history = screen.getActiveTranscriptRows()
        val found = ArrayList<Int>()
        var r = -history
        val bottom = emulator.mRows - 1
        while (r <= bottom) {
            val line = screen.getSelectedText(0, r, cols, r, false).lowercase()
            var from = 0
            while (true) {
                val at = line.indexOf(needle, from)
                if (at < 0) break
                found.add(r)
                // Advance past this hit so overlapping runs of the same letters are still counted
                // as the separate matches a person sees, matching how the desktop counts them.
                from = at + needle.length
            }
            r++
        }
        rows = found
        total = found.size
    }

    /**
     * Bring the current match onto the screen, roughly centred.
     *
     * `setTopRow` is the one public seam Termux gives for this — the same field its own finger-scroll
     * moves — and `invalidate` repaints at the new position without the snap-to-bottom a plain
     * `onScreenUpdated()` does on fresh output. The target is clamped into the buffer so a match on
     * the live screen parks at the bottom rather than scrolling past it.
     */
    private fun scrollToCurrent() {
        val row = rows.getOrNull(current) ?: return
        val emulator = binding.session.emulator ?: return
        val history = emulator.getScreen().getActiveTranscriptRows()
        val target = (row - emulator.mRows / 2).coerceIn(-history, 0)
        view.setTopRow(target)
        view.invalidate()
    }
}

/**
 * The find bar: a field, a count, and two arrows.
 *
 * The same controls in the same order as iOS `FindBar` — a person who learns one find bar in this
 * app has learned all three (the terminal's, the page's, the desktop's). It floats over the top of
 * the terminal rather than pushing it down: inserting it would take about three rows off the session,
 * and taking rows off a session is not a layout change, it is a `resize` on the wire that makes the
 * far end reflow. Searching is a thing you do *while reading*, so it must not disturb what is read.
 *
 * The counter is mono, because "3 of 17" is two counted numbers and data is mono in this app; the
 * words are not. Nothing here is a dead control: the arrows are disabled with no term and with no
 * matches, and the clear button exists only while there is something to clear.
 */
@Composable
fun FindBar(
    find: TerminalFindSession,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = DeckTheme.colors
    val focus = remember { FocusRequester() }
    // Raised straight away — the bar exists because somebody chose Find, so making them tap the
    // field they just asked for would be a second tap for nothing.
    LaunchedEffect(Unit) { focus.requestFocus() }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.x2),
        modifier = modifier
            .fillMaxWidth()
            .background(colors.surface)
            .border(width = 1.dp, color = colors.hairline, shape = Radius.medium)
            .padding(horizontal = Space.x3, vertical = Space.x2),
    ) {
        // The field, in its own recessed pill so it reads as the one thing here you type into.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.x15),
            modifier = Modifier
                .weight(1f)
                .clip(Radius.fieldShape)
                .background(colors.surfaceHigh)
                .padding(horizontal = Space.x3, vertical = Space.x2),
        ) {
            Icon(
                Icons.Filled.Search,
                contentDescription = null,
                tint = colors.faint,
                modifier = Modifier.size(16.dp),
            )
            Box(modifier = Modifier.weight(1f)) {
                if (find.term.isEmpty()) {
                    Text("Find in output", style = DeckType.control, color = colors.faint, maxLines = 1)
                }
                BasicTextField(
                    value = find.term,
                    onValueChange = { find.type(it) },
                    singleLine = true,
                    textStyle = DeckType.control.merge(androidx.compose.ui.text.TextStyle(color = colors.primary)),
                    cursorBrush = SolidColor(colors.accent),
                    // Search rather than a newline, and the action walks *earlier* — the direction a
                    // fresh search already went, matching the terminal's return key on iOS.
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { find.earlier() }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
            }
            if (find.hasTerm) {
                Text(
                    text = find.status,
                    style = DeckType.mono,
                    // Secondary on a hit, warning when there is none — the one thing this slot can say
                    // that the screen behind it cannot show for itself.
                    color = if (find.hasMatches) colors.secondary else colors.warning,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    Icons.Filled.Close,
                    contentDescription = "Clear",
                    tint = colors.faint,
                    modifier = Modifier
                        .size(18.dp)
                        .clip(Radius.small)
                        .clickable { find.type("") },
                )
            }
        }

        // Earlier then later — up is back in time, the direction a search starts in.
        FindArrow(Icons.Filled.KeyboardArrowUp, "Earlier match", enabled = find.hasMatches) { find.earlier() }
        FindArrow(Icons.Filled.KeyboardArrowDown, "Later match", enabled = find.hasMatches) { find.later() }

        Text(
            text = "Done",
            style = DeckType.control,
            color = colors.accent,
            modifier = Modifier
                .clip(Radius.small)
                .clickable { onClose() }
                .padding(horizontal = Space.x2, vertical = Space.x1),
        )
    }
}

@Composable
private fun FindArrow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    Icon(
        icon,
        contentDescription = label,
        tint = if (enabled) colors.primary else colors.faint,
        modifier = Modifier
            .size(30.dp)
            .clip(Radius.small)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick)
            .padding(Space.x1),
    )
}
