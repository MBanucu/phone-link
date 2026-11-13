package org.phonelink.proxy;

import java.util.Locale;

/**
 * Byte counters and a minute of one-second rate samples, for one listener's
 * page in the panel.
 *
 * <p>Plain Java, no Android types: the relay threads add bytes here, the panel
 * samples it once a second while it is in front, and the tests drive it
 * directly. One instance belongs to one running proxy, so the page under it
 * answers "what has this proxy moved", not "what has this phone ever moved";
 * a listener that is started again gets fresh counters, because that is a new
 * run of that proxy.
 */
final class Traffic {

    /** One per second; a minute of history fits a sparkline comfortably. */
    static final int SAMPLES = 60;

    private final long[] down = new long[SAMPLES];
    private final long[] up = new long[SAMPLES];
    private long totalDown;
    private long totalUp;
    private long lastDown;
    private long lastUp;
    private int next;
    private int filled;

    /** Called from the relay threads: bytes moved in each direction. */
    void add(long uploaded, long downloaded) {
        synchronized (this) {
            totalUp += uploaded;
            totalDown += downloaded;
        }
    }

    /** {uploaded, downloaded} since this listener started. */
    long[] totals() {
        synchronized (this) {
            return new long[] {totalUp, totalDown};
        }
    }

    void reset() {
        synchronized (this) {
            totalDown = 0;
            totalUp = 0;
            lastDown = 0;
            lastUp = 0;
            next = 0;
            filled = 0;
            for (int i = 0; i < SAMPLES; i++) {
                down[i] = 0;
                up[i] = 0;
            }
        }
    }

    /** Close one interval; returns {uploaded, downloaded} bytes per second. */
    long[] sample() {
        synchronized (this) {
            long downRate = totalDown - lastDown;
            long upRate = totalUp - lastUp;
            lastDown = totalDown;
            lastUp = totalUp;
            down[next] = downRate;
            up[next] = upRate;
            next = (next + 1) % SAMPLES;
            if (filled < SAMPLES) {
                filled++;
            }
            return new long[] {upRate, downRate};
        }
    }

    /** {uploaded, downloaded} per interval, oldest first, for a sparkline. */
    long[][] history() {
        synchronized (this) {
            long[] upRates = new long[filled];
            long[] downRates = new long[filled];
            int start = (next - filled + SAMPLES) % SAMPLES;
            for (int i = 0; i < filled; i++) {
                upRates[i] = up[(start + i) % SAMPLES];
                downRates[i] = down[(start + i) % SAMPLES];
            }
            return new long[][] {upRates, downRates};
        }
    }

    /** "512 B", "1.4 kB", "3.2 MB": decimal units, like a file manager. */
    static String human(long bytes) {
        if (bytes < 1000) {
            return bytes + " B";
        }
        String[] units = {"kB", "MB", "GB"};
        double value = bytes;
        int unit = -1;
        while (value >= 1000 && unit < units.length - 1) {
            value /= 1000;
            unit++;
        }
        return String.format(Locale.US, "%.1f %s", value, units[unit]);
    }
}
