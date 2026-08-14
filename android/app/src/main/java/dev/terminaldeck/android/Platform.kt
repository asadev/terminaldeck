package dev.terminaldeck.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build

/**
 * The two things [DeckViewModel] needs from Android, behind interfaces it can be tested without.
 *
 * Not architecture for its own sake. The collection of machines is the part of this app that must
 * not get one thing wrong — pairing a second machine and dropping the first — and that is a
 * question about which object holds what, answerable in milliseconds on a JVM. It was not
 * answerable at all while the view model was an `AndroidViewModel`: constructing one needs an
 * `Application`, and every method on `android.jar` in a unit test throws `Stub!`.
 *
 * So the clipboard and the network callback come in through these, the real ones are built in
 * `MainActivity`'s factory, and the multi-host tests use fakes.
 */
interface Clipboard {

    /** What is on the clipboard, or null. Read lazily: a paste that never happens reads nothing. */
    fun read(): String?

    fun write(text: String)

    /**
     * True when the system shows its own copy confirmation, so the app must not add a second.
     *
     * Android 13 draws a preview of whatever was just copied. A snackbar underneath it saying
     * "Copied." is the same news twice.
     */
    val confirmsItself: Boolean
}

/**
 * Tell someone when the OS says there is a network again.
 *
 * Without it the app waits out whatever backoff step it had reached — up to twenty seconds of a
 * dead terminal after the wifi bars are already full, which is how an app earns a reputation for
 * being slow.
 */
fun interface NetworkWatch {

    /** Start watching. The returned lambda stops. */
    fun start(onAvailable: () -> Unit): () -> Unit

    companion object {
        /** Nobody is watching. For tests and Compose previews, where there is no `Context`. */
        val none: NetworkWatch = NetworkWatch { {} }
    }
}

/* -------------------------------------------------------------------------- */

class AndroidClipboard(private val context: Context) : Clipboard {

    private val manager: ClipboardManager?
        get() = context.getSystemService(ClipboardManager::class.java)

    override fun read(): String? =
        manager?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()

    override fun write(text: String) {
        manager?.setPrimaryClip(ClipData.newPlainText("Terminal Deck", text))
    }

    override val confirmsItself: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
}

/**
 * `registerDefaultNetworkCallback`, which fires on the handoff between wifi and cellular too — the
 * common case on a phone, and one that looks identical to a dead socket from inside the app.
 */
class AndroidNetworkWatch(private val context: Context) : NetworkWatch {

    override fun start(onAvailable: () -> Unit): () -> Unit {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return {}
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onAvailable()
        }
        val stop: () -> Unit = { runCatching { manager.unregisterNetworkCallback(callback) } }
        val nothing: () -> Unit = {}
        return try {
            manager.registerDefaultNetworkCallback(callback)
            stop
        } catch (e: SecurityException) {
            // Some OEM builds refuse this without a permission the app does not hold. The app then
            // reconnects on its own schedule and when it is foregrounded, which is slower but not
            // broken — so it is not worth failing to start over.
            nothing
        }
    }
}
