package org.phonelink.proxy;

import java.util.Locale;

/**
 * Byte counters and a minute of one-second rate samples, for the panel's Log
 * page.
 *
 * <p>Plain Java, no Android types: the relay threads add bytes here, the panel
 * samples it once a second while it is in front, and the tests drive it
 * directly. The counters are per run — {@link ProxyService} resets them when it
 * is asked to start again — because the question the page answers is "what has
 * this run moved", not "what has this phone ever moved".
 */
final class Traffic {

    /** One per second; a minute of history fits a sparkline comfortably. */
    static final int SAMPLES = 60;

    private static final long[] down = new long[SAMPLES];
    private static final long[] up = new long[SAMPLES];
    private static long totalDown;
    private static long totalUp;
    private static long lastDown;
    private static long lastUp;
    private static int next;
    private static int filled;

    private Traffic() {
    }

    /** Called from the relay threads: bytes moved in each direction. */
    static void add(long uploaded, long downloaded) {
        synchronized (Traffic.class) {
            totalUp += uploaded;
            totalDown += downloaded;
        }
    }

    /** {uploaded, downloaded} since the last {@link #reset()}. */
    static long[] totals() {
        synchronized (Traffic.class) {
            return new long[] {totalUp, totalDown};
        }
    }

    static void reset() {
        synchronized (Traffic.class) {
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
    static long[] sample() {
        synchronized (Traffic.class) {
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
    static long[][] history() {
        synchronized (Traffic.class) {
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
