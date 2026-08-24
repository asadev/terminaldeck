package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space
import dev.terminaldeck.android.ui.theme.TerminalScheme
import dev.terminaldeck.android.ui.theme.TerminalSchemeStore
import dev.terminaldeck.android.ui.theme.TerminalSchemes
import dev.terminaldeck.android.ui.theme.currentAppearance

/**
 * What a scheme actually looks like, drawn in the scheme.
 *
 * ## Why this is four lines of fake shell output and not a row of swatches
 *
 * A row of twenty-one squares tells you what colours are in a scheme and nothing about what it is
 * like to read one, which is the only question being asked here. The thing that makes Solarized
 * Dark different from Nord is not that their blues differ by a few degrees of hue — it is what a
 * prompt, a path and an error look like sitting on that particular ground at that particular
 * contrast. So the preview is a terminal: a prompt, a command, output with two colours in it, and a
 * block caret in the scheme's own cursor colour.
 *
 * The swatch strip is underneath as well, because the four lines cannot reach sixteen colours and
 * somebody editing bright magenta needs to see bright magenta. Both, rather than either.
 *
 * ## It is drawn with Compose, not with the emulator
 *
 * Attaching twenty-one real `TerminalView`s to a scrolling list would mean twenty-one pseudo
 * terminals for a settings screen. The colours are the same values from the same object, so what is
 * on screen is honest — with one stated exception, below.
 *
 * ## The one place this preview is deliberately not faithful
 *
 * The selection band. The vendored emulator draws a selection by inverting, so a real session
 * ignores `selectionBackground` entirely — and this preview does the same thing rather than
 * painting the stored colour, which would show somebody a band they will never see. The editor row
 * for that colour says so in words. A preview that flattered the model would be the more attractive
 * of the two and the one that lies.
 */
@Composable
fun TerminalSchemePreview(scheme: TerminalScheme, modifier: Modifier = Modifier) {
    val bg = Color(TerminalScheme.parse(scheme.background))
    val fg = Color(TerminalScheme.parse(scheme.foreground))
    val caret = Color(TerminalScheme.parse(scheme.cursor))
    fun ansi(index: Int) = Color(TerminalScheme.parse(scheme.ansi[index]))

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(Radius.medium)
            .background(bg)
            // A hairline in the app's ink rather than the scheme's, so that Pure black on a dark
            // phone still reads as a rectangle with edges instead of a hole in the card.
            .border(1.dp, DeckTheme.colors.hairline, Radius.medium)
            .padding(Space.x3),
        verticalArrangement = Arrangement.spacedBy(Space.half),
    ) {
        Row {
            Text("~/deck ", style = DeckType.monoSmall, color = ansi(12))
            Text("$ ", style = DeckType.monoSmall, color = ansi(10))
            Text("git status", style = DeckType.monoSmall, color = fg)
        }
        Row {
            Text("M  ", style = DeckType.monoSmall, color = ansi(11))
            Text("app/theme/TerminalScheme.kt", style = DeckType.monoSmall, color = fg)
        }
        Row {
            Text("??  ", style = DeckType.monoSmall, color = ansi(9))
            Text("untracked.kt", style = DeckType.monoSmall, color = ansi(8))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("$ ", style = DeckType.monoSmall, color = ansi(10))
            // The caret, as a block, because that is the shape this app's terminal draws.
            Box(
                modifier = Modifier
                    .size(width = 7.dp, height = 14.dp)
                    .background(caret)
            )
        }

        Spacer(Modifier.height(Space.x2))

        // The sixteen, in wire order, eight to a row: 0–7 dim on top, 8–15 bright underneath, which
        // is the arrangement every published palette sheet uses and therefore the one somebody
        // comparing against a screenshot expects.
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            listOf(0, 8).forEach { base ->
                Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    (base until base + 8).forEach { index ->
                        Box(
                            modifier = Modifier
                                .size(width = 18.dp, height = 8.dp)
                                .clip(Radius.small)
                                .background(ansi(index))
                        )
                    }
                }
            }
        }
    }
}

/**
 * Choose the terminal's colours.
 *
 * Asad asked for this on every client — *"phone also, for Windows, for MacBook, all of them"* — and
 * on a phone it is a full screen rather than a menu, because every entry has to be seen rather than
 * read: a list of thirteen names with no colour on it would make somebody tap each one in turn to
 * find out what they had chosen.
 *
 * ## The tap is the whole gesture
 *
 * Selecting writes the store, which is observable, which is what `TerminalScreen` resolves its
 * palette from — so the session behind this screen is already repainted before the finger is off
 * the row. There is no Apply, for the reason [AppearanceScreen] gives about the control one level
 * up: a confirm button would put a step between a choice and its only observable effect.
 *
 * ## The first entry is not a scheme
 *
 * *Match app appearance* is the default and has to be first, because it is where everybody starts
 * and a list that opened on **Terminal Deck** would suggest somebody had chosen it. Its preview
 * draws whichever of the two halves the app currently resolves to, so it is a live answer to *what
 * will I get* rather than a label.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalSchemeScreen(onBack: () -> Unit, onEdit: (String) -> Unit) {
    val context = LocalContext.current
    val colors = DeckTheme.colors
    val dark = currentAppearance().isDark(LocalConfiguration.current)

    // Both reads subscribe, so adding or editing a scheme redraws this list without anything
    // having to tell it to.
    val chosen = TerminalSchemeStore.selectedId.value ?: TerminalSchemes.MATCH_APPEARANCE
    val custom = TerminalSchemeStore.customSchemes.value ?: emptyList()

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Terminal colours", onBack = onBack) },
    ) { padding ->
        /*
         * Lazy, and it has to be.
         *
         * Every row carries a live preview — four lines of text and sixteen swatches — so the list
         * is around three hundred nodes deep with thirteen built-ins and more once somebody starts
         * making copies. A `Column` with a scroll modifier composes all of it before the first frame,
         * which on a slow device is a visible stall on a *settings screen*, and it gets worse with
         * every scheme added. `LazyColumn` composes the two or three that are on screen.
         */
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(
                start = Space.screen,
                end = Space.screen,
                bottom = Space.x16,
            ),
        ) {
            item("caption.auto") { SectionCaption("Automatic") }
            item("auto") {
                DeckGroup {
                    SchemeChoice(
                        name = "Match app appearance",
                        detail = "Dark on ink, light on paper",
                        detailIsHex = false,
                        scheme = TerminalSchemes.forAppearance(dark),
                        selected = chosen == TerminalSchemes.MATCH_APPEARANCE,
                        tag = "scheme.auto",
                        onSelect = { TerminalSchemeStore.select(context, TerminalSchemes.MATCH_APPEARANCE) },
                        onEdit = null,
                    )
                }
                DeckFootnote(
                    "Follows the Appearance setting, including the phone's dark schedule. Pick a " +
                        "scheme below to override it."
                )
                Spacer(Modifier.height(Space.x5))
            }

            item("caption.builtin") { SectionCaption("Built in") }
            itemsIndexed(TerminalSchemes.builtIns, key = { _, it -> "builtin." + it.id }) { index, scheme ->
                /*
                 * One card per scheme rather than one card around all thirteen.
                 *
                 * A `DeckGroup` spanning the whole list would have to be a single lazy item to keep
                 * its rounded corners, which would compose every preview again — the exact thing
                 * this list is lazy to avoid.
                 */
                DeckGroup {
                    SchemeChoice(
                        name = scheme.name,
                        detail = scheme.background,
                        detailIsHex = true,
                        scheme = scheme,
                        selected = chosen == scheme.id,
                        tag = "scheme." + scheme.id,
                        onSelect = { TerminalSchemeStore.select(context, scheme.id) },
                        onEdit = { onEdit(scheme.id) },
                    )
                }
                if (index < TerminalSchemes.builtIns.lastIndex) Spacer(Modifier.height(Space.x2))
            }
            item("footnote.builtin") {
                DeckFootnote("Editing one of these makes a copy — the built-in stays as it shipped.")
                Spacer(Modifier.height(Space.x5))
            }

            if (custom.isNotEmpty()) {
                item("caption.custom") { SectionCaption("Yours") }
                itemsIndexed(custom, key = { _, it -> "custom." + it.id }) { index, scheme ->
                    DeckGroup {
                        SchemeChoice(
                            name = scheme.name,
                            detail = scheme.background,
                            detailIsHex = true,
                            scheme = scheme,
                            selected = chosen == scheme.id,
                            tag = "scheme." + scheme.id,
                            onSelect = { TerminalSchemeStore.select(context, scheme.id) },
                            onEdit = { onEdit(scheme.id) },
                        )
                    }
                    if (index < custom.lastIndex) Spacer(Modifier.height(Space.x2))
                }
                item("spacer.custom") { Spacer(Modifier.height(Space.x5)) }
            }

            item("footnote.tail") {
                DeckFootnote(
                    "Colours apply to open sessions straight away. This phone's terminal shows a " +
                        "selection by inverting, so Selection and Cursor text are stored for your " +
                        "other machines and change nothing here."
                )
            }
        }
    }
}

/**
 * One row of the picker: the preview, the name, whether it is the chosen one, and a way in.
 *
 * The whole row selects and the trailing button edits, rather than the row opening an editor with a
 * *Use this* button inside it. Choosing is the common gesture by a wide margin, and burying it one
 * level down would make the frequent thing cost two taps to save the rare thing one.
 */
@Composable
private fun SchemeChoice(
    name: String,
    detail: String,
    /** Mono for a hex, because it is a measurement; the app's own face for a sentence. */
    detailIsHex: Boolean,
    scheme: TerminalScheme,
    selected: Boolean,
    tag: String,
    onSelect: () -> Unit,
    onEdit: (() -> Unit)?,
) {
    val colors = DeckTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .testTag(tag)
            .padding(Space.card),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = if (selected) "In use" else null,
                tint = if (selected) colors.accent else Color.Transparent,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(Space.x2))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = name,
                    style = DeckType.rowTitle,
                    color = if (selected) colors.accent else colors.primary,
                )
                Text(
                    text = detail,
                    style = if (detailIsHex) DeckType.monoFootnote else DeckType.footnote,
                    color = colors.faint,
                )
            }
            if (onEdit != null) {
                IconButton(onClick = onEdit, modifier = Modifier.testTag("$tag.edit")) {
                    Icon(
                        imageVector = Icons.Filled.Tune,
                        contentDescription = "Edit $name",
                        tint = colors.secondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
        Spacer(Modifier.height(Space.x2))
        TerminalSchemePreview(scheme)
    }
}
