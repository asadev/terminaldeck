package dev.terminaldeck.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.InputType
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import dev.terminaldeck.android.WatchController
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.TAP_SLOP_PX
import dev.terminaldeck.android.protocol.WatchMath
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The canvas one browser surface is cast onto, and the gestures that drive it.
 *
 * A plain [View] rather than a composable, and that is the whole reason it exists: the four rules
 * this viewer cannot get wrong silently are all about *when* things happen relative to a draw, and
 * a Compose recomposition per frame at thirty frames a second would rebuild a tree to move one
 * bitmap. The same call `WatchSurfaceUIView` makes on iOS, for the same reasons.
 *
 *  1. **Ack from the paint callback.** [onDraw] sends it, after the bitmap is on the canvas — the
 *     host holds one un-acked frame per watcher, so acking on receipt asks a machine for frames
 *     faster than a phone can draw them.
 *  2. **The page lives on the server, so this never scrolls itself.** A swipe becomes a wheel the
 *     server performs; what is drawn is only ever the server's own viewport.
 *  3. **Coordinates are image pixels of a named frame.** Every gesture is measured against the frame
 *     currently drawn and sent with *that* `seq`, so a scroll landing mid-gesture cannot desync it.
 *  4. **A masked frame is a curtain, never pixels.** `data` is empty on one, and this draws its own
 *     lock card; a curtain takes no taps.
 *
 * ## Where a tap lands when the aspect ratios differ
 *
 * The bitmap is drawn to fit, centred, so a frame whose shape does not match the view is letterboxed
 * rather than stretched. Coordinates are then measured against **the rectangle the image was
 * actually drawn into**, not the whole view — a tap in the letterbox maps to the nearest edge pixel
 * of the page instead of to a point the page never showed. In the ordinary case the two are the same
 * rectangle: the host renders at the width this view asked for.
 */
class WatchSurfaceView(
    context: Context,
    private val watch: WatchController,
    /** The surface being shown: `""` for the front tab, else a slot name. */
    private val target: String,
) : View(context) {

    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val curtainPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        // The PWA's own curtain ink on its own curtain paper. Deliberately fixed rather than themed:
        // the page is not being shown, so this is not the app's paper.
        color = CURTAIN_INK
        textSize = 40f
        textAlign = Paint.Align.CENTER
    }

    private var bitmap: Bitmap? = null

    /** The last frame actually drawn — what a gesture is measured against. */
    private var lastFrame: ServerMessage.BrowserFrame? = null

    /** The `seq` waiting to be acked from the next draw, or null. */
    private var pendingAck: Int? = null

    /** One decode at a time; a frame arriving mid-decode replaces the one waiting. */
    private var painting = false
    private var queued: ServerMessage.BrowserFrame? = null

    /** The width last asked for, so a resize renegotiates only on a real change. */
    private var requestedWidth = 0

    private var curtainText: String? = null

    private val decoder = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "watch-decode").apply { isDaemon = true }
    }

    private val drawn = RectF()
    private val source = Rect()

    private enum class Gesture { NONE, PENDING, SCROLL }

    private var gesture = Gesture.NONE
    private var startX = 0f
    private var startY = 0f
    private var lastX = 0f
    private var lastY = 0f

    init {
        setBackgroundColor(CURTAIN_PAPER)
        isClickable = true
        // Focusable in touch mode, so a tap can take the responder and raise the system keyboard —
        // the whole of *"if we just click inside and type from our keyboard, it should work… I should
        // not have to have this separate button of keyboard."* There is no field any more; the canvas
        // itself is what the keyboard types into, and every key becomes a `browser.input`.
        isFocusable = true
        isFocusableInTouchMode = true
        watch.frameHandler = { frame ->
            if (frame.window == target) post { onFrame(frame) }
        }
    }

    /** The frame a typed line should be aimed at, or null while nothing has been drawn. */
    fun currentSeq(): Int? = lastFrame?.takeIf { !it.masked }?.seq

    /* ------------------------------------------------------------------ keyboard -- */

    /**
     * The canvas is the text editor now.
     *
     * `TYPE_NULL` tells the IME this is not an ordinary field and to send raw key events rather than
     * edit a buffer it thinks it owns — which is exactly what a remote page wants, because there is no
     * local text to edit, only keystrokes to forward. A soft keyboard that insists on committing text
     * anyway (gesture typing) is caught by [commitText]; the rest arrive as key events through
     * [streamKey]. `IME_ACTION_GO` puts *Go* on the return key, and pressing it becomes an Enter.
     */
    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_NULL
        outAttrs.imeOptions = EditorInfo.IME_ACTION_GO or
            EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        return object : BaseInputConnection(this, false) {
            override fun sendKeyEvent(event: KeyEvent): Boolean = streamKey(event)

            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
                lastFrame?.takeIf { !it.masked }?.let { watch.insert(target, it.seq, text.toString()) }
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                lastFrame?.takeIf { !it.masked }?.let { frame ->
                    repeat(beforeLength.coerceAtLeast(0)) { watch.backspace(target, frame.seq) }
                }
                return true
            }
        }
    }

    private fun showKeyboard() {
        if (!isFocused) requestFocus()
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun hideKeyboard() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow(windowToken, 0)
        clearFocus()
    }

    /**
     * One key event, forwarded to the page against the frame it was measured on.
     *
     * Acted on the way **down** only, and each verb sends its own down-and-up on the wire — a page
     * listening on `keyup` needs the release, and doing it here rather than waiting for the physical
     * up keeps a held key from stalling. Enter, Backspace and Tab are named keys; everything else is
     * the character it produced. `ACTION_MULTIPLE` with `KEYCODE_UNKNOWN` carries a whole string (some
     * IMEs deliver a word this way), so it is forwarded as one paste. The navigation keys — Back, Home,
     * volume — are left alone, or the system back gesture would type into the page instead of leaving.
     */
    private fun streamKey(event: KeyEvent): Boolean {
        val frame = lastFrame ?: return false
        if (frame.masked) return false
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_MULTIPLE) {
            return event.action == KeyEvent.ACTION_UP && handledKey(event.keyCode)
        }
        when (event.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> watch.enter(target, frame.seq)
            KeyEvent.KEYCODE_DEL -> watch.backspace(target, frame.seq)
            KeyEvent.KEYCODE_TAB -> watch.key(target, frame.seq, "Tab", "Tab")
            KeyEvent.KEYCODE_UNKNOWN -> {
                val chars = event.characters ?: return false
                watch.insert(target, frame.seq, chars)
            }
            else -> {
                val code = event.unicodeChar
                if (code == 0) return false
                watch.insert(target, frame.seq, String(Character.toChars(code)))
            }
        }
        return true
    }

    /** Which keys this view forwards to the page, so their release is consumed too and does not bubble
     *  to the activity. Deliberately not the navigation keys — those belong to the system. */
    private fun handledKey(keyCode: Int): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_MENU,
        KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE,
        -> false
        else -> lastFrame?.masked == false
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (handledKey(keyCode) && streamKey(event)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyMultiple(keyCode: Int, repeatCount: Int, event: KeyEvent): Boolean {
        if (streamKey(event)) return true
        return super.onKeyMultiple(keyCode, repeatCount, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (handledKey(keyCode)) return true
        return super.onKeyUp(keyCode, event)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // A rotation or a size change renegotiates the render width, but only when the width
        // actually moved — a host reading a stream of identical watches would restart a screencast
        // for nothing.
        startWatching()
    }

    private fun startWatching() {
        if (width <= 0) return
        val asked = WatchMath.watchWidth(width)
        if (asked == requestedWidth) return
        requestedWidth = asked
        watch.watch(target, width)
    }

    /**
     * Stop the cast and let go of the sink.
     *
     * Called when the viewer leaves. Without it the machine keeps rendering JPEGs of a page nobody
     * is looking at, which is the one cost of this feature that a user cannot see.
     */
    fun tearDown() {
        // Idempotent: the viewer releases this view *and* disposes an effect that also releases it,
        // deliberately, so that a composition torn down without a release still stops the cast. A
        // second unwatch on the wire would be harmless but a second `shutdownNow` on a dead pool is
        // noise, so the flag makes the second call a no-op rather than a duplicate.
        if (torndown) return
        torndown = true
        // The keyboard goes with the cast — a system keyboard left up over a page that is no longer
        // being driven is half a phone screen offering to type into nothing.
        hideKeyboard()
        watch.frameHandler = null
        watch.unwatch(target)
        decoder.shutdownNow()
    }

    private var torndown = false

    /* ------------------------------------------------------------------- paint -- */

    private fun onFrame(frame: ServerMessage.BrowserFrame) {
        if (painting) {
            queued = frame
            return
        }
        painting = true
        paintFrame(frame)
    }

    private fun paintFrame(frame: ServerMessage.BrowserFrame) {
        if (frame.masked) {
            bitmap = null
            curtainText = frame.curtain
            lastFrame = frame
            armAck(frame.seq)
            return
        }
        val bytes = frame.bytes()
        if (bytes == null) {
            // A frame the phone could not decode is still acked, or the whole cast stalls on one bad
            // frame; the last good frame stays under the finger and its `seq` is what the next
            // gesture maps against.
            lastFrame = frame
            armAck(frame.seq)
            return
        }
        decoder.execute {
            val decoded = try {
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            } catch (e: OutOfMemoryError) {
                null
            }
            post {
                if (decoded != null) {
                    bitmap = decoded
                    curtainText = null
                }
                lastFrame = frame
                armAck(frame.seq)
            }
        }
    }

    /** Queue the ack for the next draw, and ask for one. */
    private fun armAck(seq: Int) {
        pendingAck = seq
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val image = bitmap
        if (image != null) {
            fit(image.width, image.height)
            source.set(0, 0, image.width, image.height)
            canvas.drawBitmap(image, source, drawn, paint)
        } else {
            curtainText?.let { prompt ->
                // A lock card, drawn rather than composed, because the pixels of the page are not
                // here to draw and this view owns the whole rectangle either way.
                canvas.drawText("🔒", width / 2f, height / 2f - 40f, curtainPaint)
                val small = Paint(curtainPaint).apply { textSize = 34f }
                wrap(prompt, small, width - 96f).forEachIndexed { line, text ->
                    canvas.drawText(text, width / 2f, height / 2f + 30f + line * 42f, small)
                }
            }
        }
        // The ack, from the paint callback and nowhere else. Posted rather than sent inline so the
        // frame this asks for cannot arrive in the middle of the draw that asked for it.
        pendingAck?.let { seq ->
            pendingAck = null
            post {
                watch.ack(target, seq)
                painting = false
                queued?.let { next ->
                    queued = null
                    onFrame(next)
                }
            }
        }
    }

    /** The rectangle the image is drawn into: fit, centred, never stretched. */
    private fun fit(imageW: Int, imageH: Int) {
        if (imageW <= 0 || imageH <= 0 || width <= 0 || height <= 0) {
            drawn.set(0f, 0f, width.toFloat(), height.toFloat())
            return
        }
        val scale = min(width.toFloat() / imageW, height.toFloat() / imageH)
        val w = imageW * scale
        val h = imageH * scale
        val left = (width - w) / 2f
        val top = (height - h) / 2f
        drawn.set(left, top, left + w, top + h)
    }

    private fun wrap(text: String, paint: Paint, maxWidth: Float): List<String> {
        val words = text.split(' ')
        val lines = mutableListOf<String>()
        var line = StringBuilder()
        for (word in words) {
            val candidate = if (line.isEmpty()) word else "$line $word"
            if (paint.measureText(candidate) > maxWidth && line.isNotEmpty()) {
                lines += line.toString()
                line = StringBuilder(word)
            } else {
                line = StringBuilder(candidate)
            }
        }
        if (line.isNotEmpty()) lines += line.toString()
        return lines
    }

    /* ---------------------------------------------------------------- gestures -- */

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val frame = lastFrame
        if (frame == null || frame.masked) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                startX = event.x
                startY = event.y
                lastX = startX
                lastY = startY
                // A touch has not decided whether it is a tap or a scroll — that is settled by
                // whether it travels, so nothing is sent on the way down.
                gesture = Gesture.PENDING
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (gesture == Gesture.NONE) return false
                if (gesture == Gesture.PENDING &&
                    abs(event.x - startX) < TAP_SLOP_PX && abs(event.y - startY) < TAP_SLOP_PX
                ) {
                    return true
                }
                gesture = Gesture.SCROLL
                val at = locate(frame, event.x, event.y) ?: return true
                val scaleX = frame.w.toDouble() / drawn.width().coerceAtLeast(1f)
                val scaleY = frame.h.toDouble() / drawn.height().coerceAtLeast(1f)
                val dx = ((event.x - lastX) * scaleX).roundToInt()
                val dy = ((event.y - lastY) * scaleY).roundToInt()
                if (dx != 0 || dy != 0) watch.scroll(target, frame.seq, at.first, at.second, dx, dy)
                lastX = event.x
                lastY = event.y
                return true
            }

            MotionEvent.ACTION_UP -> {
                val wasPending = gesture == Gesture.PENDING
                gesture = Gesture.NONE
                if (!wasPending) return true
                val at = locate(frame, event.x, event.y) ?: return true
                // A touch that never travelled: a tap, synthesised as a click so a page with no
                // touch handlers still responds.
                watch.tap(target, frame.seq, at.first, at.second)
                // And the keyboard comes up — a tap on a field is how a person asks to type into it,
                // exactly as it is in any browser. It rises whatever was tapped, because this side
                // cannot know a field from a heading, and a keyboard raised over a heading is a swipe
                // away; a field that could not raise one would be a field that cannot be filled.
                showKeyboard()
                performClick()
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                gesture = Gesture.NONE
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    /** Image coordinates for a point, measured against the rectangle the frame was drawn into. */
    private fun locate(frame: ServerMessage.BrowserFrame, x: Float, y: Float): Pair<Int, Int>? {
        if (drawn.width() <= 0f || drawn.height() <= 0f) return null
        return WatchMath.imageCoords(
            frameW = frame.w,
            frameH = frame.h,
            viewW = drawn.width(),
            viewH = drawn.height(),
            px = x - drawn.left,
            py = y - drawn.top,
        )
    }

    private companion object {
        /** The PWA's curtain colours (`#e6e8ec` on `#101216`), written out rather than themed. */
        const val CURTAIN_INK = 0xFFE6E8EC.toInt()
        const val CURTAIN_PAPER = 0xFF101216.toInt()
    }
}
