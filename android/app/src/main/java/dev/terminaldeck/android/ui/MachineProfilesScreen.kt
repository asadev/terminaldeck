package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.MachineProfilesUiView
import dev.terminaldeck.android.protocol.MachineBrowserProfile
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckEmptyState
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * The machine's browser profiles — the cookie jars it keeps, which one it is using, and the two
 * things a phone can honestly do to them.
 *
 * A port of `ios/TerminalDeck/Screens/MachineProfilesView.swift`. These are `persist:` partitions on
 * the machine's own disk, so everything here just relays a verb to the machine and reads the answer:
 *
 *   > *"we have profile, password, cookies, everything… it should be all same, because it is just
 *   > linking this to the server side."*
 *
 * **Switch** decides which jar the *next* page opens into; it is its own confirmation, because both
 * verbs re-answer with a fresh list and a switched profile simply moves up into the *In use* card.
 * **Clear** empties a jar — it signs that machine's browser out of everything in it — so it asks first,
 * and names the machine out loud: *"It should give the warning also."* While a verb is out the whole
 * screen stops taking taps, because there is no correlation id on this wire and "the list changed" is
 * the only signal that it is done.
 */
@Composable
fun MachineProfilesScreen(
    view: MachineProfilesUiView,
    machineLabel: String,
    onBack: () -> Unit,
    onUse: (String) -> Unit,
    onClear: (String) -> Unit,
) {
    var confirming by remember { mutableStateOf<MachineBrowserProfile?>(null) }
    val colors = DeckTheme.colors
    val list = view.list
    val busy = view.working != null

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Browser profiles", subtitle = machineLabel, onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen),
        ) {
            when {
                // Null is "reading…", not "none" — the family has no push, so the screen re-asks on
                // every appearance and this is the beat before the first answer.
                list == null -> Box(
                    modifier = Modifier.fillMaxWidth().padding(top = Space.x16),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(28.dp))
                }

                list.isEmpty -> DeckEmptyState(
                    text = "This machine's browser has no profiles.",
                    modifier = Modifier.padding(top = Space.x16),
                )

                else -> {
                    list.currentProfile?.let { current ->
                        SectionCaption("In use")
                        DeckGroup {
                            ProfileRow(
                                profile = current,
                                selected = true,
                                working = view.working,
                                onClear = { confirming = current },
                                onUse = null,
                            )
                        }
                    }

                    val others = list.others
                    if (others.isNotEmpty()) {
                        SectionCaption("Switch to")
                        DeckGroup {
                            others.forEachIndexed { index, profile ->
                                if (index > 0) DeckDivider(startIndent = Space.card)
                                ProfileRow(
                                    profile = profile,
                                    selected = false,
                                    working = view.working,
                                    onClear = { confirming = profile },
                                    onUse = if (busy) null else { { onUse(profile.id) } },
                                )
                            }
                        }
                    }

                    DeckFootnote(
                        "Switching decides which jar the next page opens into. Clearing one signs " +
                            "$machineLabel's browser out of everything in it, and touches nothing on this phone."
                    )
                }
            }
            Spacer(Modifier.padding(top = Space.x8))
        }
    }

    confirming?.let { profile ->
        AlertDialog(
            onDismissRequest = { confirming = null },
            containerColor = colors.surface,
            titleContentColor = colors.primary,
            textContentColor = colors.secondary,
            title = { Text("Clear this profile?", style = DeckType.title) },
            text = {
                Text(
                    "This empties ${profile.displayName}'s cookie jar on $machineLabel and signs its " +
                        "browser out of everything in it.",
                    style = DeckType.footnote,
                )
            },
            confirmButton = {
                TextButton(onClick = { onClear(profile.id); confirming = null }) {
                    Text("Clear", color = colors.critical)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirming = null }) {
                    Text("Keep", color = colors.secondary)
                }
            },
        )
    }
}

/** One profile row: a badge, the name, what it holds, and — as a *sibling* of the switch, never nested
 *  inside it — the Clear word. The whole row switches when [onUse] is set; Clear is its own hit target,
 *  so a press never coin-tosses between switching and destroying. */
@Composable
private fun ProfileRow(
    profile: MachineBrowserProfile,
    selected: Boolean,
    working: String?,
    onClear: () -> Unit,
    onUse: (() -> Unit)?,
) {
    val colors = DeckTheme.colors
    val clearing = working == profile.id
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .then(if (onUse != null) Modifier.clickable(onClick = onUse) else Modifier)
            .padding(horizontal = Space.card, vertical = Space.x2),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(if (selected) 34.dp else 28.dp)
                .clip(CircleShape)
                .background(colors.accentSoft),
        ) {
            Text(
                text = badge(profile),
                style = DeckType.monoBody,
                color = colors.accent,
            )
        }
        Spacer(Modifier.width(Space.x3))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile.displayName,
                style = if (selected) DeckType.rowTitle else DeckType.body,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            holds(profile)?.let {
                Text(it, style = DeckType.caption, color = colors.faint, maxLines = 1)
            }
        }
        Spacer(Modifier.width(Space.x2))
        // Clearing is drawn as a word swapping to "Clearing…" rather than a spinner, so the row does
        // not change height while a verb is out.
        Text(
            text = if (clearing) "Clearing…" else "Clear",
            style = DeckType.value,
            color = if (clearing) colors.faint else colors.critical,
            modifier = Modifier
                .clip(dev.terminaldeck.android.ui.theme.Radius.medium)
                .then(if (working == null) Modifier.clickable(onClick = onClear) else Modifier)
                .padding(horizontal = Space.x3, vertical = Space.x2),
        )
    }
}

/** The one character the badge draws — the profile's own avatar, or the initial of its name. */
private fun badge(profile: MachineBrowserProfile): String {
    profile.avatar.takeIf { it.isNotEmpty() }?.let { return it.take(1).uppercase() }
    return profile.displayName.take(1).uppercase()
}

/** What a profile holds, drawn only when the machine said — never a zero, because absent and none read
 *  the same and inventing "0 cookies" is a claim the wire did not make. */
private fun holds(profile: MachineBrowserProfile): String? {
    val parts = buildList {
        profile.sites?.let { add(if (it == 1) "1 site" else "$it sites") }
        profile.cookies?.let { add(if (it == 1) "1 cookie" else "$it cookies") }
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}
