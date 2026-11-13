package org.phonelink.capture;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.BroadcastReceiver;
import android.graphics.Color;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Writes the screen to XML, takes the harness's touches, and marks the screen
 * with the phone's clock — everything printed with
 * {@link SystemClock#elapsedRealtimeNanos()}, so the record of a run and the
 * recording of it can be compared.
 *
 * <p>Why the XML: {@code adb shell uiautomator dump} costs about two and a half
 * seconds on this phone, most of it a cold JVM and the wait for a quiet
 * accessibility window. A service is already connected, so the same tree costs
 * milliseconds here — and the events say exactly when it changed, so there is
 * nothing to poll.
 *
 * <p>Why the touches: an {@code input tap} is a fresh JVM per call, so the phone
 * learns about the tap a third of a second after the command was sent, and
 * nobody knows when it actually landed. Dispatching the gesture from here is
 * both immediate and stamped — with the very clock the captures use. The same
 * goes for Back and Home.
 *
 * <p>Why the flash: the recording is the only record with every frame in it,
 * and its timeline starts whenever {@code screenrecord} got going, which
 * nothing on the phone can name. So the service paints the whole screen a
 * colour nothing else is, at instants it writes down, at the start and at the
 * end of a run; finding those flashes in the mp4 ties the two clocks together.
 *
 * <p>Files live in the app's own external directory,
 * {@code /sdcard/Android/data/org.phonelink.capture/files}, which adb can read
 * without any storage permission:
 *
 * <pre>
 * ui-NNNNN.xml   the screen, one per capture (+ latest.xml, the last one)
 * index.csv      n, device_ns, wall_ms, trigger
 * actions.csv    start_ns, end_ns, kind, detail — one per touch or key
 * clock.csv      device_ns, wall_ms, on|off — one per flash edge
 * </pre>
 */
public final class DumpService extends AccessibilityService {

    private static final String TAG = "phone-link-capture";

    /**
     * How long a burst is allowed to settle first. One tap arrives as about
     * five events and a fling as one per frame, all describing the same screen;
     * without this the record would be mostly duplicates of one frame.
     */
    private static final long QUIET_MS = 100;

    /** Long enough to be a tap, short enough not to be a press. */
    private static final int TAP_MS = 50;

    /** The flash colour: nothing else on this phone is a full screen of it. */
    private static final int FLASH_COLOUR = 0xFFFF00FF;

    private static DumpService instance;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable pending = () -> capture("change");

    private File dir;
    private int index;
    private volatile boolean watching;
    private View flash;
    /** The one broadcast parked until the screen says what it is waiting for. */
    private Waiter waiter;
    /**
     * What a sequence waits on: the count of events and when the last one came.
     * Guarded by itself, so a wait can sleep until the screen says something
     * instead of asking it again and again.
     */
    private final Object screenLock = new Object();
    private long screenEvents;
    private long lastScreenEventMs = SystemClock.uptimeMillis();
    /** One sequence at a time: two would tap over each other. */
    private final java.util.concurrent.atomic.AtomicBoolean sequencing =
            new java.util.concurrent.atomic.AtomicBoolean();
    private HandlerThread sequenceThread;

    /** The enabled service, or null while accessibility is not handing it work. */
    static DumpService running() {
        return instance;
    }

    @Override
    public void onServiceConnected() {
        instance = this;
        dir = getExternalFilesDir(null);
        index = lastName(dir);
        Log.i(TAG, "capturing into " + dir + " from " + index);
    }

    //
    // The counter lives on disk, not in the process: Android may restart this
    // service between two captures, and a counter that started over would
    // overwrite the record it is supposed to keep.
    private static int lastName(File base) {
        if (base == null) {
            return 0;
        }
        String[] names = base.list();
        if (names == null) {
            return 0;
        }
        int last = 0;
        for (String name : names) {
            if (!name.startsWith("ui-") || !name.endsWith(".xml") || name.length() < 9) {
                continue;
            }
            try {
                last = Math.max(last, Integer.parseInt(name.substring(3, name.length() - 4)));
            } catch (NumberFormatException e) {
                // Not one of ours.
            }
        }
        return last;
    }

    @Override
    public void onDestroy() {
        instance = null;
        finish(2);
        handler.removeCallbacksAndMessages(null);
        removeFlash();
        if (sequenceThread != null) {
            sequenceThread.quitSafely();
            sequenceThread = null;
        }
        super.onDestroy();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // Before anything else: a sequence waiting on the screen is woken by
        // this, whether or not the screen is being recorded.
        noteScreenEvent();
        // A waiter watches even when the record is off: it is waiting for the
        // screen to say something, and the screen is the only thing that can.
        Waiter parked = waiter;
        if (!watching && parked == null) {
            return;
        }
        handler.removeCallbacks(pending);
        handler.postDelayed(pending, QUIET_MS);
        // A quiet wait is the same idea as the debounce the record uses: the
        // screen is still when it has stopped saying anything for a moment.
        if (parked != null && parked.quietMs > 0) {
            handler.removeCallbacks(parked.quiet);
            handler.postDelayed(parked.quiet, parked.quietMs);
        }
    }

    @Override
    public void onInterrupt() {
        // Nothing to interrupt: a capture is a read of one tree.
    }

    /** Whether changed screens are being recorded by themselves. */
    boolean watching() {
        return watching;
    }

    void setWatching(boolean on) {
        watching = on;
        handler.removeCallbacks(pending);
        Log.i(TAG, on ? "watching for changes" : "not watching");
    }

    /** A capture now, whatever the watching state; true when one was written. */
    boolean requestCapture(String why) {
        handler.removeCallbacks(pending);
        return capture(why);
    }

    //
    // --- the screen a sequence reads and waits on -------------------------

    /**
     * The screen as the same XML a capture writes, without writing it: a
     * sequence that has to look at the screen looks many times a second, and
     * the record of it is the captures, not the looks.
     */
    String screen() {
        List<AccessibilityNodeInfo> roots = windows();
        if (roots.isEmpty()) {
            return null;
        }
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        return Hierarchy.of(roots, metrics.widthPixels, metrics.heightPixels);
    }

    private void noteScreenEvent() {
        synchronized (screenLock) {
            screenEvents++;
            lastScreenEventMs = SystemClock.uptimeMillis();
            screenLock.notifyAll();
        }
    }

    long screenEvents() {
        synchronized (screenLock) {
            return screenEvents;
        }
    }

    /** How long the screen has said nothing at all. */
    long stillForMs() {
        synchronized (screenLock) {
            return SystemClock.uptimeMillis() - lastScreenEventMs;
        }
    }

    /**
     * Sleep until the screen says something, or {@code ms} runs out; true when
     * it did. The cap matters as much as the wake-up: an event this service
     * never saw — a still screen, an event swallowed by the system — must not
     * turn into a wait that outlives its timeout.
     */
    boolean awaitScreenEvent(long ms) {
        synchronized (screenLock) {
            long seen = screenEvents;
            long deadline = SystemClock.uptimeMillis() + Math.max(1, ms);
            try {
                while (screenEvents == seen) {
                    long left = deadline - SystemClock.uptimeMillis();
                    if (left <= 0) {
                        return false;
                    }
                    screenLock.wait(left);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
            return true;
        }
    }

    /**
     * Whether a keyboard is on screen. It is a window of its own, of another
     * app, so it is not in the captures — but it covers the bottom half of the
     * page, and a button under it cannot be tapped until it goes.
     */
    boolean keyboardUp() {
        List<AccessibilityWindowInfo> all = getWindows();
        if (all == null) {
            return false;
        }
        for (AccessibilityWindowInfo window : all) {
            if (window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                return true;
            }
        }
        return false;
    }

    /**
     * Put the keyboard away, if one is up. Back means exactly that while a
     * keyboard is showing and something quite different when none is — it
     * leaves the page — which is why the phone asks before pressing it.
     */
    boolean hideKeyboard() {
        if (!keyboardUp()) {
            return true;
        }
        return back();
    }

    /**
     * Text into the field that has the input focus, the way a keyboard would:
     * an accessibility action replaces the whole value, so there is nothing to
     * clear first — which is most of what typing a field used to cost.
     */
    boolean type(String value) {
        Bundle args = new Bundle();
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
        // The focus can be a moment behind the dialog that was just tapped.
        for (int attempt = 0; attempt < 6; attempt++) {
            AccessibilityNodeInfo root = getRootInActiveWindow();
            AccessibilityNodeInfo field = root == null ? null
                    : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (field != null && field.isEditable()
                    && field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                return true;
            }
            SystemClock.sleep(80);
        }
        Log.w(TAG, "no field with the input focus to put text in");
        return false;
    }

    //
    // --- sequences --------------------------------------------------------

    /**
     * Run a script of steps on a thread of its own and answer the broadcast
     * when it is over. A sequence blocks — it waits on the screen — and the
     * main thread is where the events it waits for arrive.
     */
    void runSequence(String script, BroadcastReceiver.PendingResult pending) {
        Sequence sequence;
        try {
            sequence = Sequence.parse(script, this, pending);
        } catch (IllegalArgumentException e) {
            Log.w(TAG, "cannot run this sequence: " + e.getMessage());
            pending.setResultCode(2);
            pending.setResultData("script: " + e.getMessage());
            pending.finish();
            return;
        }
        if (!sequencing.compareAndSet(false, true)) {
            Log.w(TAG, "a sequence is already running");
            pending.setResultCode(2);
            pending.setResultData("busy");
            pending.finish();
            return;
        }
        sequenceThread().post(sequence);
    }

    private Handler sequenceThread() {
        if (sequenceThread == null) {
            sequenceThread = new HandlerThread("sequence");
            sequenceThread.start();
        }
        return new Handler(sequenceThread.getLooper());
    }

    /** Called by the sequence however it ended, so the next one may start. */
    void sequenceFinished() {
        sequencing.set(false);
    }

    //
    // --- waiting on the screen --------------------------------------------

    /**
     * One parked broadcast: the screen is looked at until it holds the needle
     * (or stops holding it, or has changed at all), and the caller is released
     * with the answer. This is what lets the harness wait for the thing a step
     * caused instead of sleeping and hoping it happened in time.
     */
    private static final class Waiter {
        final String needle;
        final boolean gone;
        final boolean change;
        /** Quiet mode: finished when the screen has been still this long. */
        final long quietMs;
        final BroadcastReceiver.PendingResult pending;
        final Runnable timeout;
        final Runnable quiet;

        Waiter(String needle, boolean gone, boolean change, long quietMs,
                BroadcastReceiver.PendingResult pending, Runnable timeout, Runnable quiet) {
            this.needle = needle;
            this.gone = gone;
            this.change = change;
            this.quietMs = quietMs;
            this.pending = pending;
            this.timeout = timeout;
            this.quiet = quiet;
        }

        boolean matches(String xml) {
            boolean there = needle == null || xml.contains(needle);
            return gone ? !there : there;
        }
    }

    /**
     * Park {@code pending} until the screen matches, or the timeout runs out.
     * The answer is the broadcast's result: 0 for the screen, 1 for the clock.
     */
    void await(String needle, boolean gone, boolean change, long quietMs, int timeoutMs,
            BroadcastReceiver.PendingResult pending) {
        if (waiter != null) {
            // Someone is already waiting for the screen; two would race for it.
            pending.setResultCode(2);
            pending.finish();
            return;
        }
        if (needle != null && needle.isEmpty()) {
            needle = null;
        }
        boolean changed = change || needle == null;
        Waiter parked = new Waiter(needle, gone, changed, quietMs, pending,
                () -> finish(1), () -> finish(0));
        waiter = parked;
        handler.postDelayed(parked.timeout, Math.max(1, timeoutMs));
        // The screen may already be saying it: a step that taps and then waits
        // for what the tap did must not be told to wait for the next change.
        if (!changed && matchesNow(parked)) {
            finish(0);
        }
        if (quietMs > 0) {
            handler.postDelayed(parked.quiet, quietMs);
        }
    }

    private boolean matchesNow(Waiter parked) {
        List<AccessibilityNodeInfo> roots = windows();
        if (roots.isEmpty()) {
            return false;
        }
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        return parked.matches(Hierarchy.of(roots, metrics.widthPixels, metrics.heightPixels));
    }

    private void finish(int result) {
        // Both the timeout and the quiet timer can be in flight; whichever is
        // second finds no waiter and does nothing.
        Waiter parked = waiter;
        if (parked == null) {
            return;
        }
        waiter = null;
        handler.removeCallbacks(parked.timeout);
        handler.removeCallbacks(parked.quiet);
        parked.pending.setResultCode(result);
        parked.pending.finish();
        Log.i(TAG, "wait over: " + (result == 0 ? "the screen" : "the clock"));
    }

    //
    // --- the touches ------------------------------------------------------

    /**
     * A tap at a point, dispatched from here so the instant it lands is known.
     * The dispatch is refused while another gesture is in flight, which is
     * waited out: the harness taps, looks at the screen and taps again, but a
     * gesture it no longer needs must not swallow the next one.
     */
    boolean tap(int x, int y) {
        Path path = new Path();
        path.moveTo(x, y);
        return stroke(path, TAP_MS, "tap", x + "," + y);
    }

    boolean swipe(int x1, int y1, int x2, int y2, int ms) {
        Path path = new Path();
        path.moveTo(x1, y1);
        path.lineTo(x2, y2);
        return stroke(path, ms, "swipe", x1 + "," + y1 + " " + x2 + "," + y2);
    }

    private boolean stroke(Path path, int ms, String kind, String detail) {
        GestureDescription description = new GestureDescription.Builder()
                .addStroke(new GestureDescription.StrokeDescription(path, 0, ms))
                .build();
        for (int attempt = 0; attempt < 10; attempt++) {
            long start = SystemClock.elapsedRealtimeNanos();
            if (dispatchGesture(description, null, null)) {
                action(kind, detail, start, start + ms * 1_000_000L);
                return true;
            }
            SystemClock.sleep(20);
        }
        Log.w(TAG, "the phone would not take a " + kind + " at " + detail);
        return false;
    }

    boolean back() {
        return global(GLOBAL_ACTION_BACK, "back");
    }

    boolean home() {
        return global(GLOBAL_ACTION_HOME, "home");
    }

    private boolean global(int action, String kind) {
        long start = SystemClock.elapsedRealtimeNanos();
        if (!performGlobalAction(action)) {
            Log.w(TAG, "the phone would not go " + kind);
            return false;
        }
        action(kind, "", start, start);
        return true;
    }

    synchronized void action(String kind, String detail, long start, long end) {
        if (dir == null) {
            return;
        }
        append(new File(dir, "actions.csv"), "start_ns,end_ns,kind,detail\n",
                String.format(Locale.ROOT, "%d,%d,%s,%s%n", start, end, kind, detail));
    }

    //
    // --- the flash --------------------------------------------------------

    /**
     * Paints the screen the flash colour for {@code edges} transitions, holding
     * each for {@code periodMs}, and writes down when each one happened. Even
     * counts end on the screen behind, which is what a caller wants.
     *
     * <p>The overlay window is made once, up front, and the edges only change
     * its colour: putting a window up costs tens of milliseconds more than
     * repainting one, and an edge that cost more than its neighbours would put
     * its own latency into the fit instead of the phone's screen.
     */
    void flash(int edges, long periodMs) {
        if (edges < 1) {
            return;
        }
        // Only the debounced capture is dropped, not everything this handler
        // holds: a broadcast waiting on the screen has its timeout parked here
        // too, and it must still time out.
        handler.removeCallbacks(pending);
        setFlash(false);
        handler.postDelayed(() -> step(edges, periodMs, 0), 100);
    }

    private void step(int edges, long periodMs, int i) {
        boolean on = i % 2 == 0;
        setFlash(on);
        long now = SystemClock.elapsedRealtimeNanos();
        if (dir != null) {
            append(new File(dir, "clock.csv"), "device_ns,wall_ms,state\n",
                    String.format(Locale.ROOT, "%d,%d,%s%n", now,
                            System.currentTimeMillis(), on ? "on" : "off"));
        }
        if (i + 1 < edges) {
            handler.postDelayed(() -> step(edges, periodMs, i + 1), periodMs);
        } else {
            // The window stays up, clear, for a moment after the last edge and
            // then goes: taking it away must not be a change the recording
            // keeps as the last one, since the last one is what the clock is
            // counted back from.
            handler.postDelayed(this::removeFlash, periodMs * 2);
        }
    }

    /** The overlay window, made the first time it is asked for. */
    private View flashWindow() {
        if (flash != null) {
            return flash;
        }
        WindowManager windows = (WindowManager) getSystemService(WINDOW_SERVICE);
        if (windows == null) {
            return null;
        }
        View view = new View(this);
        view.setBackgroundColor(Color.TRANSPARENT);
        // Not focusable and not touchable: the screen underneath is what the
        // harness is about to act on, and this must only colour it.
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        try {
            windows.addView(view, params);
            flash = view;
            return view;
        } catch (RuntimeException e) {
            Log.w(TAG, "cannot paint the flash", e);
            return null;
        }
    }

    /** On is the flash colour, off is nothing at all — the same window either way. */
    private void setFlash(boolean on) {
        View view = flashWindow();
        if (view != null) {
            view.setBackgroundColor(on ? FLASH_COLOUR : Color.TRANSPARENT);
        }
    }

    private void removeFlash() {
        View view = flash;
        flash = null;
        WindowManager windows = (WindowManager) getSystemService(WINDOW_SERVICE);
        if (view != null && windows != null) {
            try {
                windows.removeView(view);
            } catch (RuntimeException e) {
                Log.w(TAG, "cannot take the flash away", e);
            }
        }
    }

    //
    // --- the screen -------------------------------------------------------

    private boolean capture(String why) {
        if (dir == null || (!dir.exists() && !dir.mkdirs())) {
            Log.w(TAG, "no directory to capture into (" + why + ")");
            return false;
        }
        // The instant the tree is read, not the instant it is written: the
        // recording shows what was on the screen when the read started.
        long now = SystemClock.elapsedRealtimeNanos();
        long wall = System.currentTimeMillis();
        // Gone first: a caller that asks and then reads back must never be
        // handed the screen of a minute ago because this capture failed.
        File latest = new File(dir, "latest.xml");
        if (!latest.delete() && latest.exists()) {
            Log.w(TAG, "cannot replace " + latest);
            return false;
        }
        List<AccessibilityNodeInfo> roots = windows();
        if (roots.isEmpty()) {
            Log.w(TAG, "no window to capture (" + why + ")");
            return false;
        }
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        String xml = Hierarchy.of(roots, metrics.widthPixels, metrics.heightPixels);
        synchronized (this) {
            index++;
            String name = String.format(Locale.ROOT, "ui-%05d.xml", index);
            if (!write(new File(dir, name), xml) || !write(latest, xml)) {
                return false;
            }
            append(new File(dir, "index.csv"), "n,device_ns,wall_ms,trigger\n",
                    String.format(Locale.ROOT, "%d,%d,%d,%s%n", index, now, wall, why));
        }
        // Every capture is the chance a parked broadcast was waiting for: the
        // screen it was told to watch for is the one just written.
        // Only a capture the screen itself caused counts as a change: one a
        // caller asked for is no news to a broadcast waiting for news. A quiet
        // wait is answered by its own timer, not by any single capture.
        Waiter parked = waiter;
        if (parked != null && parked.quietMs == 0
                && (parked.change ? "change".equals(why) : parked.matches(xml))) {
            finish(0);
        }
        return true;
    }

    /**
     * Every window's tree, the one with the focus first.
     *
     * <p>The active window alone is not enough: the panel's own dialogs — the
     * name prompt, the battery request, the Info page — are windows of their
     * own, and a caller that asks for the screen and gets only the page behind
     * the dialog cannot find the button it means to press. Windows this service
     * may not read come back as null roots and are left out.
     */
    private List<AccessibilityNodeInfo> windows() {
        List<AccessibilityNodeInfo> roots = new ArrayList<>();
        AccessibilityNodeInfo active = getRootInActiveWindow();
        if (active != null) {
            roots.add(active);
        }
        // Only windows of the same app as the active one: its dialogs and
        // popups belong to the screen it is showing, while the status bar, the
        // launcher behind it and the keyboard are other apps and would turn a
        // dump of the panel into a dump of the phone.
        CharSequence activePackage = active == null ? null : active.getPackageName();
        List<AccessibilityWindowInfo> all = getWindows();
        if (all != null && activePackage != null) {
            for (AccessibilityWindowInfo window : all) {
                AccessibilityNodeInfo root = window.getRoot();
                if (root != null && activePackage.equals(root.getPackageName())
                        && !roots.contains(root)) {
                    roots.add(root);
                }
            }
        }
        return roots;
    }

    private static boolean write(File file, String text) {
        try (Writer out = new OutputStreamWriter(new FileOutputStream(file),
                StandardCharsets.UTF_8)) {
            out.write(text);
            return true;
        } catch (IOException e) {
            Log.w(TAG, "cannot write " + file, e);
            return false;
        }
    }

    /** One more line in a log of this run; the header goes in with the first. */
    private static boolean append(File file, String header, String line) {
        try (Writer out = new OutputStreamWriter(new FileOutputStream(file, true),
                StandardCharsets.UTF_8)) {
            if (file.length() == 0) {
                out.write(header);
            }
            out.write(line);
            return true;
        } catch (IOException e) {
            Log.w(TAG, "cannot append to " + file, e);
            return false;
        }
    }
}
