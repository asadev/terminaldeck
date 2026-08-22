package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import dev.terminaldeck.android.ports.PortBook
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.FieldLabel
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * Writing down what a port actually is.
 *
 * *"agent service, WSL relay thing. Maybe we can rename them somehow."* The name is this phone's —
 * the machine does not know what is behind its own ports either, which is why nothing here goes on
 * the wire.
 *
 * Clearing the field removes the name, and the button says so rather than leaving somebody to guess
 * whether an empty box saves an empty label. Naming a port also **promotes** it out of whatever pile
 * it was in; the sentence at the foot says that, because it is a second effect from one gesture and a
 * row that jumped groups for no visible reason is a row that looks like a bug.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RenamePortSheet(
    port: Int,
    current: String?,
    onSave: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = DeckTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var text by remember { mutableStateOf(current.orEmpty()) }
    val cleaned = PortBook.clean(text)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background,
        shape = Radius.sheetShape,
        dragHandle = null,
    ) {
        DeckSheetChrome()
        Column(
            modifier = Modifier
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Text("Name port $port", style = DeckType.title, color = colors.primary)
            Spacer(Modifier.height(Space.x4))
            FieldLabel("What is it")
            DeckTextField(
                value = text,
                onValueChange = { text = it.take(PortBook.MAX_NAME_LENGTH) },
                placeholder = "The API the agent keeps talking about",
                singleLine = true,
            )
            DeckFootnote(
                "Kept on this phone, against this machine. Naming a port also lifts it to the top " +
                    "of the list — that is the whole of “keep some in the list and keep some folded”."
            )
            Spacer(Modifier.height(Space.x5))
            Row {
                DeckQuietButton(label = "Cancel", onClick = onDismiss, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(Space.x3))
                DeckPrimaryButton(
                    label = if (cleaned == null) "Remove name" else "Save",
                    onClick = { onSave(cleaned) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}
