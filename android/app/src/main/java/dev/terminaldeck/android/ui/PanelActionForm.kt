package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.text.KeyboardOptions
import dev.terminaldeck.android.protocol.PanelAction
import dev.terminaldeck.android.protocol.PanelField
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckSegmented
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * The form behind any panel action that asks for something first — a port of
 * `ios/TerminalDeck/Screens/PanelActionForm.swift`.
 *
 * `PanelAction.fields` is what makes every panel a control rather than a list without a wire frame per
 * verb: the host declares the boxes, this draws them, and what comes back is a `Map<String, String>`
 * on `panel.act` that only the host understands. Nothing here knows what an MCP command is or what a
 * scope means. One form serves *add* and *edit* — a prefilled `PanelField.value` is the whole
 * mechanism — and a fixed set of answers is a picker, not a keyboard. Nothing on these forms is prose,
 * so nothing is autocorrected; the long half of a placeholder goes behind the ⓘ, split on the host's
 * own dash. A destructive action is confirmed here, from inside the filled-in form, not before it.
 */
@Composable
fun PanelActionForm(
    title: String,
    action: PanelAction,
    onCancel: () -> Unit,
    onSubmit: (Map<String, String>) -> Unit,
) {
    val colors = DeckTheme.colors

    // Seeded from the fields' own values, which is what makes one action serve both add and edit.
    // Built by assignment rather than a map builder that traps on a repeated key: a host that sent the
    // same field id twice has a bug, and that is not a reason to kill the app on a phone in a hand.
    val values = remember(action) {
        mutableStateMapOf<String, String>().apply { action.fields.forEach { this[it.id] = it.value } }
    }
    var confirming by remember { mutableStateOf(false) }

    fun text(id: String) = values[id] ?: ""
    val ready = action.fields.all { !it.required || text(it.id).trim().isNotEmpty() }

    fun send() {
        // Off it goes, as typed — the host trims what it needs to and this end cannot know which
        // fields those are.
        onSubmit(values.toMap())
    }

    fun confirm() {
        if (action.destructive) confirming = true else send()
    }

    BackHandler(onBack = onCancel)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Space.x2, vertical = Space.x1),
            ) {
                TextButton(onClick = onCancel) {
                    Text("Cancel", style = DeckType.control, color = colors.secondary)
                }
                Text(
                    text = title,
                    style = DeckType.title,
                    color = colors.primary,
                    modifier = Modifier.weight(1f).padding(horizontal = Space.x2),
                    maxLines = 1,
                )
                // The action's own words, not "Save" or "Done": the host wrote the verb and is the
                // only party that knows what pressing this does.
                TextButton(onClick = { confirm() }, enabled = ready) {
                    Text(
                        text = action.label,
                        style = DeckType.control.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                        color = when {
                            !ready -> colors.faint
                            action.destructive -> colors.warning
                            else -> colors.accent
                        },
                    )
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = Space.x4).padding(top = Space.x3, bottom = Space.x6),
        ) {
            DeckGroup {
                action.fields.forEachIndexed { index, field ->
                    if (index > 0) DeckDivider(startIndent = Space.x4)
                    FieldRow(field = field, value = text(field.id), onValue = { values[field.id] = it })
                }
            }
        }
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            containerColor = colors.surface,
            title = { Text("${action.label}?", style = DeckType.rowTitle, color = colors.primary) },
            text = {
                val line = action.confirm
                if (!line.isNullOrEmpty()) Text(line, style = DeckType.footnote, color = colors.secondary)
            },
            confirmButton = {
                TextButton(onClick = { confirming = false; send() }) {
                    Text(action.label, style = DeckType.control, color = colors.critical)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) {
                    Text("Keep", style = DeckType.control, color = colors.secondary)
                }
            },
        )
    }
}

/** Up to this many answers are drawn as segments; past it, a menu. Three segments read at a glance on
 *  this screen's width and eight do not. */
private const val SEGMENTED_CHOICES = 3

@Composable
private fun FieldRow(field: PanelField, value: String, onValue: (String) -> Unit) {
    val colors = DeckTheme.colors
    val split = remember(field.placeholder) { splitPlaceholder(field.placeholder) }

    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(field.label, style = DeckType.caption, color = colors.faint)
            if (split.note != null) InfoDot(about = field.label, text = split.note)
        }
        Spacer(Modifier.padding(top = Space.x15))
        when {
            field.choices.isEmpty() -> DeckTextField(
                value = value,
                onValueChange = onValue,
                placeholder = split.placeholder.orEmpty(),
                mono = false,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = if (isAddress(field)) KeyboardType.Uri else KeyboardType.Ascii,
                ),
            )
            field.choices.size <= SEGMENTED_CHOICES -> DeckSegmented(
                options = field.choices,
                selectedIndex = field.choices.indexOf(value).coerceAtLeast(0),
                onSelect = { onValue(field.choices[it]) },
            )
            else -> ChoiceMenu(choices = field.choices, value = value.ifEmpty { field.choices.first() }, onSelect = onValue)
        }
    }
}

@Composable
private fun ChoiceMenu(choices: List<String>, value: String, onSelect: (String) -> Unit) {
    val colors = DeckTheme.colors
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = Space.x2),
        ) {
            Text(value, style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.UnfoldMore, contentDescription = null, tint = colors.faint, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            choices.forEach { choice ->
                DropdownMenuItem(text = { Text(choice) }, onClick = { onSelect(choice); open = false })
            }
        }
    }
}

private class Split(val placeholder: String?, val note: String?)

/**
 * The placeholder, and the sentence stuck to the end of it — split on the host's own *space em-dash
 * space*, which is how the host writes the two-part ones. A placeholder with no dash is left whole; if
 * it is long enough that the box will cut it, it is also put behind the dot, so nothing the host wrote
 * is only ever readable in a truncated form.
 */
private fun splitPlaceholder(placeholder: String?): Split {
    if (placeholder.isNullOrEmpty()) return Split(null, null)
    val dash = placeholder.indexOf(" — ")
    if (dash >= 0) return Split(placeholder.substring(0, dash), placeholder.substring(dash + 3))
    return Split(placeholder, if (placeholder.length > 48) placeholder else null)
}

/** Whether this field takes a URL — `url`, or something ending `.url`/`_url`. Deliberately not any id
 *  merely containing the three letters, which would catch `curl`. */
private fun isAddress(field: PanelField): Boolean {
    val id = field.id.lowercase()
    return id == "url" || id.endsWith(".url") || id.endsWith("_url")
}
