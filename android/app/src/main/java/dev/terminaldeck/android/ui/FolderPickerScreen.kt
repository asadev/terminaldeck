package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.FolderBrowseView
import dev.terminaldeck.android.FolderListing
import dev.terminaldeck.android.protocol.FolderEntry
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * Walking the machine's folders on a phone, to start a session in one it cannot see.
 *
 * > *"it is not giving me the option to choose the folder as well."*
 *
 * Said on an iPhone against a rented Linux server with nothing open on it, and the same is true
 * here. The cause was never permission — one of the owner's own devices may start a session in
 * **any** absolute folder, so `welcome.folders` is a *suggestion* for it rather than a boundary, and
 * on a bare server that suggestion is one row, the account's home. What the phone had no way to do
 * was find out what was there. This screen is that one missing answer, transcribed from
 * `ios/TerminalDeck/Screens/FolderPickerView.swift`: it reads directory names off the machine
 * ([dev.terminaldeck.android.FolderBrowseController]) and hands the chosen path to the ordinary
 * `create`. It grants nothing and changes nothing.
 *
 * ## Why not a text field
 *
 * It was the obvious cheap answer and it is the wrong one. Typing `/root/projects/api` on a phone
 * keyboard, correctly, with no completion and no way to see what is actually there, is a worse
 * experience than the one being fixed — and the first typo comes back as *that folder is not on this
 * machine any more*, which reads as a bug. Somebody reaching for a folder on a machine they cannot
 * see needs to be shown what is on it.
 *
 * ## Unreadable folders are drawn, not hidden
 *
 * `/root` is on every Linux listing and openable by nobody but root. Dropping the rows this account
 * cannot enter would mean somebody looking for a folder they know is there, not finding it, and
 * going to look for a bug in the picker. They are drawn dimmed with a lock and do not respond — the
 * machine carries `readable` on every row for exactly this.
 *
 * ## One tap means *go in*, and starting is a separate press
 *
 * A row that both descended and started would make every mis-tap a session on a machine somewhere.
 * Tapping a folder walks into it; the button at the bottom starts a session in the folder you are
 * standing in, and it names that folder.
 *
 * The screen is a pure function of [view]; opening the first listing on the way in and clearing it
 * on the way out is the caller's, so a test or a preview can hand in any state without a machine.
 */
@Composable
fun FolderPickerScreen(
    view: FolderBrowseView,
    /** Walk into a folder, or up to a parent, or — with null — back to the machine's own default. */
    onBrowse: (String?) -> Unit,
    /** Start a session in the folder on screen. The path is the folder the button names. */
    onChoose: (String) -> Unit,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxSize().background(colors.background)) {
        DeckTopBar(title = "Choose a folder", onBack = onBack)

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when {
                view.error != null -> Unavailable(view.error, onRestart = { onBrowse(null) })
                view.listing != null -> FolderList(view.listing, onBrowse)
                // The listing has been asked for and has not arrived — a spinner rather than an
                // empty screen, and the one place on this screen where a spinner is honest: nothing
                // is known yet and the wait is a round trip that will end.
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = colors.accent)
                }
            }
        }

        // Pinned to the bottom rather than the bar because it is the screen's one action and a thumb
        // is at the bottom of a phone. It carries the folder's own name, so pressing it is a
        // decision about a folder rather than about a screen. Absent until a listing is on screen —
        // there is nothing to start in until the machine has answered.
        view.listing?.let { listing ->
            StartBar(path = listing.path, onStart = { onChoose(listing.path) })
        }
    }
}

@Composable
private fun FolderList(listing: FolderListing, onBrowse: (String?) -> Unit) {
    val colors = DeckTheme.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(top = Space.x3, bottom = Space.x5),
    ) {
        // Where you are, in full. The button at the bottom names the folder it will start in, but it
        // names the last component only — this is the line that says which `web` you are standing in.
        // Head-truncation is the truncation a path wants; Compose gained it in 1.8 and this build is
        // on an older BOM, so the line is allowed two rows before it tails off rather than faked.
        Text(
            text = listing.path,
            style = DeckType.mono,
            color = colors.faint,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x5, vertical = Space.x2),
        )

        DeckGroup(modifier = Modifier.padding(horizontal = Space.screen)) {
            // Up a level, when there is one. Null parent is the very top of a walk — nothing above
            // it, so no row rather than a row that goes nowhere.
            if (listing.parent != null) {
                FolderRow(
                    name = "..",
                    icon = Icons.Filled.ArrowUpward,
                    dimmed = false,
                    trailing = null,
                    onClick = { onBrowse(listing.parent) },
                )
                if (listing.entries.isNotEmpty()) DeckDivider(startIndent = Space.card)
            }

            if (listing.entries.isEmpty()) {
                Text(
                    text = "No folders in here.",
                    style = DeckType.body,
                    color = colors.faint,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.card, vertical = Space.x4),
                )
            }

            listing.entries.forEachIndexed { index, entry ->
                FolderRow(
                    name = entry.name,
                    // A folder this account cannot enter wears a lock rather than the folder glyph,
                    // so the reason it does not respond is on the row rather than left to be guessed.
                    icon = if (entry.readable) Icons.Filled.Folder else Icons.Filled.Lock,
                    dimmed = !entry.readable,
                    // Already shared with an agent — said rather than offered again.
                    trailing = if (entry.granted) "Shared" else null,
                    onClick = { onBrowse(entry.path) },
                )
                if (index < listing.entries.lastIndex) DeckDivider(startIndent = Space.card)
            }
        }
    }
}

/**
 * One folder in the walk.
 *
 * A dimmed row does not respond — the machine carries `readable`, and a press that would only be
 * refused is the dead click this app is repeatedly audited for. The row is here so that somebody
 * looking for a folder they know is on the machine finds it, not so it can be pressed.
 */
@Composable
private fun FolderRow(
    name: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    dimmed: Boolean,
    trailing: String?,
    onClick: () -> Unit,
) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !dimmed, onClick = onClick)
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (dimmed) colors.faint else colors.secondary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Text(
            text = name,
            style = DeckType.body,
            color = if (dimmed) colors.faint else colors.primary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            // Fills the row so the trailing "Shared" and chevron sit at the far edge, and the name
            // ellipsizes rather than shoving them off it — middle-truncation is what a folder name
            // wants, but this build's BOM predates it, so the tail goes.
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(Space.x2))
        if (trailing != null) {
            Text(text = trailing, style = DeckType.caption, color = colors.faint)
            Spacer(Modifier.width(Space.x2))
        }
        if (!dimmed) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.faint,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun StartBar(path: String, onStart: () -> Unit) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().background(colors.background)) {
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
        // "Start in <name>", or "Start here" at the root of a walk where the last component is empty
        // — the same wording iOS puts on this button, decided here so it cannot drift from screen to
        // screen. `folderName` is the picker's neighbour on `SessionDetailSheet` and splits on `/`,
        // which is the separator iOS's own `lastPathComponent` uses here too.
        val name = folderName(path)
        val label = if (name.isBlank() || name == "/") "Start here" else "Start in $name"
        DeckPrimaryButton(
            label = label,
            onClick = onStart,
            modifier = Modifier
                .padding(start = Space.screen, end = Space.screen, top = Space.x3, bottom = Space.x2)
                .navigationBarsPadding(),
        )
    }
}

/**
 * The folder could not be opened. Back to the machine's own choice rather than retrying the folder
 * that just failed: the folder is the thing that did not work, and a button whose only outcome is
 * the same refusal is not a button.
 */
@Composable
private fun Unavailable(problem: String, onRestart: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = Space.x8),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = problem,
            style = DeckType.footnote,
            color = DeckTheme.colors.faint,
        )
        Spacer(Modifier.height(Space.x3))
        TextButton(onClick = onRestart) {
            Text("Start again", style = DeckType.control, color = DeckTheme.colors.accent)
        }
    }
}
