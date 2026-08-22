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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.SessionChatView
import dev.terminaldeck.android.protocol.ChatMessageWire
import dev.terminaldeck.android.protocol.ChatRole
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The session as a conversation rather than as a terminal.
 *
 * A transcription of `pwa/src/chat-view.ts`, and the layout is the one Asad specified for the
 * desktop's own chat view:
 *
 *   > *"my message should start from the right… the left side will be the agent… no need to give a
 *   > name actually on both sides… just the text only and time only… give the copy button"*
 *
 * So: your bubbles right, the agent's left, no names on either side, the time under each, and a copy
 * button per bubble. What is read is a bounded tail of the JSONL the agent is already writing,
 * collapsed on the far machine by the same `ChatCollapser` the desktop uses — what travels is the
 * collapsed bubbles, never the file.
 *
 * ## The two empties, which are different facts
 *
 * `transcript == null` is "not asked yet" and draws a spinner. `transcript == false` is a folder
 * with **no transcript at all**, which is the one state here that says something rather than drawing
 * an empty list — and is why the way in is absent rather than opening onto nothing. An empty list
 * with `found` true is a session that has not spoken yet, and that draws nothing, because there is
 * nothing to say about it.
 *
 * ## Why the composer rides `session.send`
 *
 * Not `input`. `input` is bytes at a pty and carries no request id, so nothing can say whether they
 * landed; `session.send` is answered with `session.sent`, and that answer is what lets the box keep
 * the draft on a refusal instead of losing it into a socket that said nothing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionChatScreen(
    view: SessionChatView,
    title: String,
    onBack: () -> Unit,
    onOpened: () -> Unit,
    onClosed: () -> Unit,
    onSend: (String) -> Boolean,
    onCopy: (String) -> Unit,
    onDismissNotice: () -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // The read is started when this screen appears and stopped when it goes, because that flag is
    // what decides whether a session going quiet is worth a transcript read at all — a terminal
    // somebody is typing into must not send a file read across a relay after every burst of output.
    DisposableEffect(Unit) {
        onOpened()
        onDispose { onClosed() }
    }

    // A conversation is read from the bottom. Scrolling on growth rather than on every recomposition
    // so that reading back through it is not fought by the view.
    LaunchedEffect(view.rows.size) {
        if (view.rows.isNotEmpty()) listState.animateScrollToItem(view.rows.lastIndex)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to the terminal")
                    }
                },
                title = {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
            )
        },
        bottomBar = {
            if (!view.canSend) return@Scaffold
            Column(modifier = Modifier.imePadding().navigationBarsPadding()) {
                view.notice?.let { notice ->
                    Text(
                        text = notice.text,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (notice.ok) {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        } else {
                            MaterialTheme.colorScheme.error
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClick = onDismissNotice)
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
                Row(
                    verticalAlignment = Alignment.Bottom,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.background)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                ) {
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        modifier = Modifier.weight(1f),
                        enabled = !view.sending,
                        placeholder = { Text("Message this session") },
                        maxLines = 6,
                    )
                    Spacer(Modifier.height(0.dp))
                    IconButton(
                        onClick = {
                            // The draft is cleared only when the send was accepted onto the socket.
                            // A refusal keeps it in the box, which is the whole reason this rides
                            // `session.send`.
                            if (onSend(draft.trim())) draft = ""
                        },
                        enabled = !view.sending && draft.isNotBlank(),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.Send,
                            contentDescription = "Send",
                            tint = if (draft.isNotBlank() && !view.sending) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                        )
                    }
                }
            }
        },
    ) { padding ->
        when {
            view.transcript == null -> Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator(color = MaterialTheme.colorScheme.primary) }

            view.transcript == false -> Box(
                modifier = Modifier.fillMaxSize().padding(padding).padding(32.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "This folder has no transcript on the machine yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            else -> LazyColumn(
                state = listState,
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                items(view.rows, key = { it.id }) { row -> ChatBubble(row, onCopy) }
            }
        }
    }
}

/**
 * One bubble: the text, the time, and a copy button. No name on either side.
 *
 * `truncated` is the machine saying *there is more of this, go and look on the machine* — carried
 * through rather than decided here, because a reader that decided for itself would be saying it
 * about something else.
 */
@Composable
private fun ChatBubble(row: ChatMessageWire, onCopy: (String) -> Unit) {
    val mine = row.role == ChatRole.You
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            horizontalAlignment = if (mine) Alignment.End else Alignment.Start,
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Text(
                text = row.text,
                style = MaterialTheme.typography.bodyMedium,
                color = if (mine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        if (mine) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surface
                    )
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = clockOf(row.at) + if (row.truncated) " · cut" else "",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(0.dp))
                Icon(
                    Icons.Filled.ContentCopy,
                    contentDescription = "Copy this message",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .padding(start = 8.dp)
                        .height(14.dp)
                        .clickable { onCopy(row.text) },
                )
            }
        }
    }
}

/**
 * The time under a bubble, or nothing.
 *
 * `at` is 0 when the transcript line carried no date, and 0 is not midnight on the first of January
 * — printing it as a clock would be the view inventing a fact the machine did not have.
 */
private fun clockOf(at: Long): String {
    if (at <= 0) return ""
    return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(at))
}
