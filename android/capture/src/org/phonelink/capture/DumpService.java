package org.phonelink.capture;

import android.accessibilityservice.AccessibilityService;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
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
 * Writes the screen to XML: once for every changed screen while watching, and
 * once for every request from adb.
 *
 * <p>Why this exists: {@code adb shell uiautomator dump} costs about two and a
 * half seconds on this phone, most of it a cold JVM and the wait for a quiet
 * accessibility window. A service is already connected, so the same tree costs
 * milliseconds here — and the events say exactly when it changed, so there is
 * nothing to poll.
 *
 * <p>Every capture is written three ways: a numbered file (the record),
 * {@code latest.xml} (what a request reads back, overwritten each time) and one
 * line in {@code index.csv} with the time it was taken and why. Files live in
 * the app's own external directory,
 * {@code /sdcard/Android/data/org.phonelink.capture/files}, which adb can read
 * without any storage permission.
 */
public final class DumpService extends AccessibilityService {

    private static final String TAG = "phone-link-capture";

    /**
     * How long a burst is allowed to settle first. One tap arrives as about
     * five events and a fling as one per frame, all describing the same screen;
     * without this the record would be mostly duplicates of one frame.
     */
    private static final long QUIET_MS = 100;

    private static DumpService instance;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable pending = () -> capture("change");

    private File dir;
    private int index;
    private volatile boolean watching;

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
        super.onDestroy();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (!watching) {
            return;
        }
        handler.removeCallbacks(pending);
        handler.postDelayed(pending, QUIET_MS);
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

    private boolean capture(String why) {
        if (dir == null || (!dir.exists() && !dir.mkdirs())) {
            Log.w(TAG, "no directory to capture into (" + why + ")");
            return false;
        }
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
        long now = System.currentTimeMillis();
        synchronized (this) {
            index++;
            String name = String.format(Locale.ROOT, "ui-%05d.xml", index);
            if (!write(new File(dir, name), xml) || !write(latest, xml)) {
                return false;
            }
            append(new File(dir, "index.csv"),
                    String.format(Locale.ROOT, "%d,%d,%s%n", index, now, why));
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

    private static boolean append(File file, String line) {
        try (Writer out = new OutputStreamWriter(new FileOutputStream(file, true),
                StandardCharsets.UTF_8)) {
            out.write(line);
            return true;
        } catch (IOException e) {
            Log.w(TAG, "cannot append " + file, e);
            return false;
        }
    }
}
