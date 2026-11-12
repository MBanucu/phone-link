package org.phonelink.proxy;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * The last few things that happened, for the panel.
 *
 * <p>Every entry remembers which saved proxy it happened to, because the panel
 * shows one proxy at a time and a start, a failure or an uplink change is about
 * that proxy rather than about the app. The service sets the tag while it runs
 * ({@link #setActiveTag}); the panel writes about a named proxy with
 * {@link #addTo}. Entries written with neither belong to the app as a whole and
 * show up under "All events".
 *
 * <p>Plain Java, no Android types, because the service, the panel and the adb
 * actions all write here and the ring is small enough to keep in memory only:
 * this is what just happened, not an audit trail — `adb logcat -s
 * phone-link-proxy` remains the complete record.
 */
final class EventLog {

    /** Enough for a session of starts, profile changes and uplink changes. */
    private static final int LIMIT = 200;

    /** One line plus the proxy it belongs to; null for the app itself. */
    private static final class Entry {
        final String tag;
        final String line;

        Entry(String tag, String line) {
            this.tag = tag;
            this.line = line;
        }
    }

    private static final List<Entry> entries = new ArrayList<>();
    private static final List<Runnable> listeners = new ArrayList<>();
    private static final SimpleDateFormat clock = new SimpleDateFormat("HH:mm:ss", Locale.US);
    /** The proxy the service is running, set by it and cleared when it goes. */
    private static volatile String activeTag;

    private EventLog() {
    }

    static void setActiveTag(String tag) {
        activeTag = tag;
    }

    /** About the proxy the service is running, or about the app when none is. */
    static void add(String message) {
        addTo(activeTag, message);
    }

    /** About a named proxy, whether or not it is the one running. */
    static void addTo(String tag, String message) {
        synchronized (entries) {
            entries.add(new Entry(tag, clock.format(new Date()) + "  " + message));
            while (entries.size() > LIMIT) {
                entries.remove(0);
            }
        }
        notifyListeners();
    }

    /** Newest first, so the page does not have to be scrolled to the end. */
    static List<String> newestFirst() {
        List<String> lines = new ArrayList<>();
        synchronized (entries) {
            for (Entry entry : entries) {
                lines.add(entry.line);
            }
        }
        Collections.reverse(lines);
        return lines;
    }

    /** One proxy's events, newest first; everything when the name is null. */
    static List<String> forProfile(String name) {
        if (name == null) {
            return newestFirst();
        }
        List<String> lines = new ArrayList<>();
        synchronized (entries) {
            for (Entry entry : entries) {
                if (name.equals(entry.tag)) {
                    lines.add(entry.line);
                }
            }
        }
        Collections.reverse(lines);
        return lines;
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
