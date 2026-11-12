package org.phonelink.proxy;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * The last few things that happened, for the panel's Log page.
 *
 * <p>Plain Java, no Android types, because the service, the panel and the adb
 * actions all write here and the ring is small enough to keep in memory only:
 * this is what just happened, not an audit trail — `adb logcat -s
 * phone-link-proxy` remains the complete record.
 */
final class EventLog {

    /** Enough for a session of starts, profile changes and uplink changes. */
    private static final int LIMIT = 200;

    private static final List<String> entries = new ArrayList<>();
    private static final List<Runnable> listeners = new ArrayList<>();
    private static final SimpleDateFormat clock = new SimpleDateFormat("HH:mm:ss", Locale.US);

    private EventLog() {
    }

    static void add(String message) {
        synchronized (entries) {
            entries.add(clock.format(new Date()) + "  " + message);
            while (entries.size() > LIMIT) {
                entries.remove(0);
            }
        }
        notifyListeners();
    }

    /** Newest first, so the page does not have to be scrolled to the end. */
    static List<String> newestFirst() {
        synchronized (entries) {
            List<String> copy = new ArrayList<>(entries);
            Collections.reverse(copy);
            return copy;
        }
    }

    static void clear() {
        synchronized (entries) {
            entries.clear();
        }
        notifyListeners();
    }

    static void addListener(Runnable listener) {
        synchronized (listeners) {
            listeners.add(listener);
        }
    }

    static void removeListener(Runnable listener) {
        synchronized (listeners) {
            listeners.remove(listener);
        }
    }

    private static void notifyListeners() {
        List<Runnable> snapshot;
        synchronized (listeners) {
            snapshot = new ArrayList<>(listeners);
        }
        for (Runnable listener : snapshot) {
            listener.run();
        }
    }
}
