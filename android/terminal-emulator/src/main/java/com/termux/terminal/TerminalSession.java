package com.termux.terminal;

import android.annotation.SuppressLint;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

/**
 * MODIFIED BY TERMINAL DECK — see ../../../../../../MODIFICATIONS.md.
 *
 * <p>Upstream this class owns a pseudo-terminal: the constructor takes a shell path and the
 * emulator is initialised by forking a child process through {@code JNI.createSubprocess}. Terminal
 * Deck never runs a shell on the phone. The process it is displaying is already running on a Mac
 * on the tailnet, and the phone is a window onto it — so the fork/exec half of this class has been
 * replaced by {@link Transport}, and {@code JNI.java} together with {@code src/main/jni} is not
 * vendored at all. That is deliberate: a phone build that cannot link a pty cannot grow one by
 * accident later.
 *
 * <p>What is kept verbatim is the part that matters — the byte path. Output still lands in
 * {@link #mProcessToTerminalIOQueue} from some other thread and is drained into the emulator on the
 * main thread by {@link MainThreadHandler}, because {@link TerminalEmulator} is not thread-safe and
 * a socket callback is no more entitled to touch it than a pty reader was. {@link #writeCodePoint}
 * is untouched.
 *
 * <p>The one behavioural difference worth knowing: {@link #write} is synchronous here. Upstream it
 * queued into {@code mTerminalToProcessIOQueue} for a writer thread to drain into a file
 * descriptor; there is no file descriptor, so keystrokes go straight to the transport, which is
 * expected to be non-blocking (a socket send that buffers, not one that waits).
 *
 * <p>Original: https://github.com/termux/termux-app — {@code terminal-emulator}, Apache 2.0.
 */
public final class TerminalSession extends TerminalOutput {

    /**
     * The seam the wire protocol plugs into.
     *
     * <p>Everything crossing it is already sanitised terminal bytes in one direction and a measured
     * viewport in the other. Nothing in this package knows what a WebSocket is, and nothing in this
     * package knows what a device token is — that belongs to the transport, which is why the
     * interface carries no notion of either.
     *
     * <p>Called on the main thread, always.
     */
    public interface Transport {

        /**
         * Keystrokes and pastes leaving the phone, UTF-8.
         *
         * <p>The array is reused by the caller — {@link #writeCodePoint} hands over a five-byte
         * scratch buffer — so an implementation that cannot send synchronously must copy the range
         * rather than retain it.
         */
        void onInput(TerminalSession session, byte[] data, int offset, int count);

        /**
         * The view measured itself.
         *
         * <p>{@code initial} marks the first size, which is the one that travels with the protocol's
         * {@code attach} so the first screen arrives already the right shape; later ones are a
         * {@code resize}. Splitting these in the transport rather than here keeps the ordering
         * decision — attach-then-resize versus attach-with-size — in the layer that owns the socket.
         */
        void onSizeChanged(TerminalSession session, int columns, int rows, boolean initial);

        /** The view is finished with this session. Not a request to kill anything on the desktop. */
        void onDetach(TerminalSession session);
    }

    private static final int MSG_NEW_INPUT = 1;
    private static final int MSG_PROCESS_EXITED = 4;

    public final String mHandle = UUID.randomUUID().toString();

    /** The id this session has on the desktop. What {@code attach} and {@code input} carry. */
    public final String mRemoteId;

    TerminalEmulator mEmulator;

    /**
     * A queue written to from a separate thread when the remote outputs, and read by main thread to
     * process by terminal emulator.
     */
    final ByteQueue mProcessToTerminalIOQueue = new ByteQueue(64 * 1024);

    /** Buffer to write translate code points into utf8 before writing to the transport. */
    private final byte[] mUtf8InputBuffer = new byte[5];

    /** Callback which gets notified when a session finishes or changes title. */
    TerminalSessionClient mClient;

    private Transport mTransport;

    /** False once the remote session has exited, or once this one has been closed locally. */
    private boolean mRunning = true;

    /** Only meaningful once {@link #isRunning()} is false. */
    private int mExitStatus;

    /** Set by the application for user identification of session, not by terminal. */
    public String mSessionName;

    /** The remote working directory, as reported in the session list. Display only. */
    public String mRemoteCwd;

    final Handler mMainThreadHandler = new MainThreadHandler();

    private final Integer mTranscriptRows;

    public TerminalSession(String remoteId, Integer transcriptRows, TerminalSessionClient client) {
        this.mRemoteId = remoteId;
        this.mTranscriptRows = transcriptRows;
        this.mClient = client;
    }

    /** Wire this session to a transport. Null detaches it and makes input a no-op. */
    public void setTransport(Transport transport) {
        mTransport = transport;
    }

    public Transport getTransport() {
        return mTransport;
    }

    /**
     * @param client The {@link TerminalSessionClient} interface implementation to allow
     *               for communication between {@link TerminalSession} and its client.
     */
    public void updateTerminalSessionClient(TerminalSessionClient client) {
        mClient = client;

        if (mEmulator != null)
            mEmulator.updateTerminalSessionClient(client);
    }

    /** Inform the transport of the new size and reflow or initialize the emulator. */
    public void updateSize(int columns, int rows, int cellWidthPixels, int cellHeightPixels) {
        if (mEmulator == null) {
            initializeEmulator(columns, rows, cellWidthPixels, cellHeightPixels);
        } else {
            mEmulator.resize(columns, rows, cellWidthPixels, cellHeightPixels);
            if (mTransport != null) mTransport.onSizeChanged(this, columns, rows, false);
        }
    }

    /** The terminal title as set through escape sequences or null if none set. */
    public String getTitle() {
        return (mEmulator == null) ? null : mEmulator.getTitle();
    }

    /**
     * Set the terminal emulator's window size and start terminal emulation.
     *
     * @param columns The number of columns in the terminal window.
     * @param rows    The number of rows in the terminal window.
     */
    public void initializeEmulator(int columns, int rows, int cellWidthPixels, int cellHeightPixels) {
        mEmulator = new TerminalEmulator(this, columns, rows, cellWidthPixels, cellHeightPixels, mTranscriptRows, mClient);
        if (mTransport != null) mTransport.onSizeChanged(this, columns, rows, true);
    }

    /**
     * Feed output from the desktop into the emulator. Safe to call from any thread.
     *
     * <p>The bytes are copied into {@link #mProcessToTerminalIOQueue} and drained on the main
     * thread, so a socket thread never touches {@link TerminalEmulator}. A caller that outruns the
     * main thread by more than the queue's 64 KiB blocks in {@link ByteQueue#write} rather than
     * growing without bound — the same backpressure the pty reader thread got.
     */
    public void feedOutput(byte[] data, int offset, int count) {
        if (count <= 0) return;
        if (!mProcessToTerminalIOQueue.write(data, offset, count)) return;
        mMainThreadHandler.sendEmptyMessage(MSG_NEW_INPUT);
    }

    /** Feed output that arrived as a protocol string. */
    public void feedOutput(String data) {
        byte[] bytes = data.getBytes(StandardCharsets.UTF_8);
        feedOutput(bytes, 0, bytes.length);
    }

    /**
     * The remote process exited. Safe to call from any thread.
     *
     * <p>Goes through the handler rather than acting directly so that any output still sitting in
     * the queue is drained into the emulator before the exit notice is appended — otherwise a
     * session that printed something on its way out would show the notice above the last line.
     */
    public void remoteExited(int exitCode) {
        mMainThreadHandler.sendMessage(mMainThreadHandler.obtainMessage(MSG_PROCESS_EXITED, exitCode));
    }

    /** Write data to the remote session. */
    @Override
    public void write(byte[] data, int offset, int count) {
        if (!mRunning || mTransport == null) return;
        mTransport.onInput(this, data, offset, count);
    }

    /** Write the Unicode code point to the terminal encoded in UTF-8. */
    public void writeCodePoint(boolean prependEscape, int codePoint) {
        if (codePoint > 1114111 || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
            // 1114111 (= 2**16 + 1024**2 - 1) is the highest code point, [0xD800,0xDFFF] is the surrogate range.
            throw new IllegalArgumentException("Invalid code point: " + codePoint);
        }

        int bufferPosition = 0;
        if (prependEscape) mUtf8InputBuffer[bufferPosition++] = 27;

        if (codePoint <= /* 7 bits */0b1111111) {
            mUtf8InputBuffer[bufferPosition++] = (byte) codePoint;
        } else if (codePoint <= /* 11 bits */0b11111111111) {
            /* 110xxxxx leading byte with leading 5 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b11000000 | (codePoint >> 6));
            /* 10xxxxxx continuation byte with following 6 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b10000000 | (codePoint & 0b111111));
        } else if (codePoint <= /* 16 bits */0b1111111111111111) {
            /* 1110xxxx leading byte with leading 4 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b11100000 | (codePoint >> 12));
            /* 10xxxxxx continuation byte with following 6 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b10000000 | ((codePoint >> 6) & 0b111111));
            /* 10xxxxxx continuation byte with following 6 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b10000000 | (codePoint & 0b111111));
        } else { /* We have checked codePoint <= 1114111 above, so we have max 21 bits = 0b111111111111111111111 */
            /* 11110xxx leading byte with leading 3 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b11110000 | (codePoint >> 18));
            /* 10xxxxxx continuation byte with following 6 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b10000000 | ((codePoint >> 12) & 0b111111));
            /* 10xxxxxx continuation byte with following 6 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b10000000 | ((codePoint >> 6) & 0b111111));
            /* 10xxxxxx continuation byte with following 6 bits */
            mUtf8InputBuffer[bufferPosition++] = (byte) (0b10000000 | (codePoint & 0b111111));
        }
        write(mUtf8InputBuffer, 0, bufferPosition);
    }

    public TerminalEmulator getEmulator() {
        return mEmulator;
    }

    /** Notify the {@link #mClient} that the screen has changed. */
    protected void notifyScreenUpdate() {
        mClient.onTextChanged(this);
    }

    /** Reset state for terminal emulator state. */
    public void reset() {
        mEmulator.reset();
        notifyScreenUpdate();
    }

    /**
     * Stop displaying this session.
     *
     * <p>Named as upstream names it so callers written against the Termux API keep working, but the
     * meaning is narrower: the desktop's process is not ours to kill, so this only tells the
     * transport we are done reading it.
     */
    public void finishIfRunning() {
        if (isRunning()) {
            mProcessToTerminalIOQueue.close();
            if (mTransport != null) mTransport.onDetach(this);
        }
    }

    @Override
    public void titleChanged(String oldTitle, String newTitle) {
        mClient.onTitleChanged(this);
    }

    public synchronized boolean isRunning() {
        return mRunning;
    }

    /** Only valid if not {@link #isRunning()}. */
    public synchronized int getExitStatus() {
        return mExitStatus;
    }

    @Override
    public void onCopyTextToClipboard(String text) {
        mClient.onCopyTextToClipboard(this, text);
    }

    @Override
    public void onPasteTextFromClipboard() {
        mClient.onPasteTextFromClipboard(this);
    }

    @Override
    public void onBell() {
        mClient.onBell(this);
    }

    @Override
    public void onColorsChanged() {
        mClient.onColorsChanged(this);
    }

    /** The remote working directory, or null if the session list did not carry one. */
    public String getCwd() {
        return mRemoteCwd;
    }

    @SuppressLint("HandlerLeak")
    class MainThreadHandler extends Handler {

        MainThreadHandler() {
            super(Looper.getMainLooper());
        }

        final byte[] mReceiveBuffer = new byte[64 * 1024];

        @Override
        public void handleMessage(Message msg) {
            int bytesRead = mProcessToTerminalIOQueue.read(mReceiveBuffer, false);
            if (bytesRead > 0 && mEmulator != null) {
                mEmulator.append(mReceiveBuffer, bytesRead);
                notifyScreenUpdate();
            }

            if (msg.what == MSG_PROCESS_EXITED) {
                int exitCode = (Integer) msg.obj;
                synchronized (TerminalSession.this) {
                    mRunning = false;
                    mExitStatus = exitCode;
                }
                mProcessToTerminalIOQueue.close();

                String exitDescription = "\r\n[Process completed";
                if (exitCode > 0) {
                    // Non-zero process exit.
                    exitDescription += " (code " + exitCode + ")";
                } else if (exitCode < 0) {
                    // Negated signal.
                    exitDescription += " (signal " + (-exitCode) + ")";
                }
                exitDescription += "]";

                if (mEmulator != null) {
                    byte[] bytesToWrite = exitDescription.getBytes(StandardCharsets.UTF_8);
                    mEmulator.append(bytesToWrite, bytesToWrite.length);
                    notifyScreenUpdate();
                }

                mClient.onSessionFinished(TerminalSession.this);
            }
        }

    }

}
