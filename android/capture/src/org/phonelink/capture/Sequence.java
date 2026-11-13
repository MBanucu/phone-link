package org.phonelink.capture;

import android.content.BroadcastReceiver;
import android.graphics.Path;
import android.os.SystemClock;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A short script of steps, run on the phone in one broadcast.
 *
 * <p>A harness that says every tap, every wait and every capture as its own
 * {@code am broadcast} pays an adb round trip each time — about a tenth of a
 * second, which for a form with four fields and a button is most of a second
 * before the phone has done anything. This takes the whole straight line at
 * once and answers when it is over, with the instruction that failed.
 *
 * <p>The script is one string, instructions separated by {@code ;}:
 *
 * <pre>
 * tap 540 1200                 a point
 * tap-id save                  the centre of a node by resource id (waits 5 s)
 * tap-text Save 2000           by the text on it, once its place holds still
 * swipe 540 2200 540 1200 200
 * text 18099                   into the field that has the input focus
 * keyboard-off                 puts the keyboard away, if one is up
 * back
 * home
 * wait text=Running 3000       until the screen holds it
 * wait-gone text=Saved 3000    until it stops holding it
 * wait-change 2000             until the screen says anything at all     * wait-quiet 250               until it has been still that long (from now)
 * expect text=Stopped          now, or the sequence fails
 * expect-gone text=Saving
 * </pre>
 *
 * <p>A matcher is {@code text=} (exactly that text), {@code contains=} (any
 * text with it in), {@code id=} (a resource id's last part), {@code desc=}
 * (content description), {@code class=} or {@code xml=} (the raw dump as
 * written, quotes and all — {@code xml=class="android.widget.EditText"}). A
 * value with spaces is quoted: {@code wait contains="saved configuration"}.
 * Arguments in {@code [...]} are optional and default to five seconds for a
 * tap and three for a wait.
 *
 * <p>Everything is stamped with the phone's own clock and written to
 * {@code actions.csv}, waits included, so a step that ran here looks the same
 * in the record as one the host drove. The broadcast's result says how it
 * went: {@code 0} for the end of the script, {@code 1} for a step that failed
 * (its number and text are the result data), {@code 2} for a script that could
 * not be read or a sequence already running.
 */
final class Sequence implements Runnable {

    private static final String TAG = "phone-link-capture";

    /** A tap looks for its node for this long before giving up. */
    private static final int DEFAULT_TAP_MS = 5000;

    /** Long enough for a dialog to draw; short enough not to hide a hang. */
    private static final int DEFAULT_WAIT_MS = 3000;

    /** How long the screen is watched between two looks at it. */
    private static final long LOOK_MS = 100;

    private static final Pattern BOUNDS =
            Pattern.compile("bounds=\"\\[(-?\\d+),(-?\\d+)\\]\\[(-?\\d+),(-?\\d+)\\]\"");

    /** One instruction: what it says and where it is in the script. */
    private static final class Step {
        final int number;
        final String verb;
        final String[] args;

        Step(int number, String verb, String[] args) {
            this.number = number;
            this.verb = verb;
            this.args = args;
        }

        /** What goes into the record: the instruction as it was written. */
        String text() {
            StringBuilder line = new StringBuilder(verb);
            for (String arg : args) {
                line.append(' ');
                // The needle is quoted so a line of the record reads like the
                // script did, spaces and all.
                if (arg.indexOf(' ') >= 0) {
                    line.append('"').append(arg).append('"');
                } else {
                    line.append(arg);
                }
            }
            return line.toString();
        }
    }

    private final DumpService service;
    private final List<Step> steps;
    private final BroadcastReceiver.PendingResult pending;
    /** Guards the answer: a sequence must be finished once, whatever happens. */
    private final Object answer = new Object();
    private boolean answered;

    private Sequence(DumpService service, List<Step> steps,
            BroadcastReceiver.PendingResult pending) {
        this.service = service;
        this.steps = steps;
        this.pending = pending;
    }

    /**
     * Read the script, so a typo is reported before the phone starts doing
     * things rather than half way through them.
     */
    static Sequence parse(String script, DumpService service,
            BroadcastReceiver.PendingResult pending) {
        if (script == null || script.trim().isEmpty()) {
            throw new IllegalArgumentException("no script");
        }
        List<Step> steps = new ArrayList<>();
        int number = 0;
        for (String line : script.split(";")) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) {
                continue;
            }
            number++;
            steps.add(parse(number, trimmed));
        }
        if (steps.isEmpty()) {
            throw new IllegalArgumentException("no instructions");
        }
        return new Sequence(service, steps, pending);
    }

    private static Step parse(int number, String line) {
        List<String> words = new ArrayList<>();
        StringBuilder word = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '"') {
                quoted = !quoted;
            } else if (!quoted && Character.isWhitespace(c)) {
                if (word.length() > 0) {
                    words.add(word.toString());
                    word.setLength(0);
                }
            } else {
                word.append(c);
            }
        }
        if (quoted) {
            throw new IllegalArgumentException(number + ": an unclosed quote");
        }
        if (word.length() > 0) {
            words.add(word.toString());
        }
        if (words.isEmpty()) {
            throw new IllegalArgumentException(number + ": nothing to do");
        }
        String verb = words.remove(0);
        String[] args = words.toArray(new String[0]);
        check(number, verb, args);
        return new Step(number, verb, args);
    }

    /** The arity each instruction needs, and the matcher it takes. */
    private static void check(int number, String verb, String[] args) {
        switch (verb) {
            case "tap":
                arity(number, verb, args, 2, 2);
                number(number, verb, args[0]);
                number(number, verb, args[1]);
                return;
            case "swipe":
                arity(number, verb, args, 4, 5);
                for (String arg : args) {
                    number(number, verb, arg);
                }
                return;
            case "tap-id":
            case "tap-text":
                arity(number, verb, args, 1, 2);
                if (args.length > 1) {
                    number(number, verb, args[1]);
                }
                return;
            case "wait":
            case "wait-gone":
                arity(number, verb, args, 1, 2);
                needle(number, args[0]);
                if (args.length > 1) {
                    number(number, verb, args[1]);
                }
                return;
            case "text":
                arity(number, verb, args, 1, 1);
                return;
            case "expect":
            case "expect-gone":
                arity(number, verb, args, 1, 1);
                needle(number, args[0]);
                return;
            case "wait-change":
                arity(number, verb, args, 0, 1);
                for (String arg : args) {
                    number(number, verb, arg);
                }
                return;
            case "wait-quiet":
                arity(number, verb, args, 1, 2);
                for (String arg : args) {
                    number(number, verb, arg);
                }
                return;
            case "back":
            case "home":
            case "keyboard-off":
                arity(number, verb, args, 0, 0);
                return;
            default:
                throw new IllegalArgumentException(number + ": no instruction called " + verb);
        }
    }

    private static void arity(int number, String verb, String[] args, int least, int most) {
        if (args.length < least || args.length > most) {
            throw new IllegalArgumentException(number + ": " + verb + " takes "
                    + (least == most ? Integer.toString(least) : least + " to " + most)
                    + " arguments, not " + args.length);
        }
    }

    private static void number(int number, String verb, String arg) {
        try {
            Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(number + ": " + verb + " wants a number, not "
                    + arg);
        }
    }

    /**
     * A matcher as the XML a node line contains, which is how the harness's
     * own needles are written and what the service already has: an id is
     * {@code id/NAME"}, a text is {@code text="NAME"}.
     */
    static String needle(int number, String spec) {
        int at = spec.indexOf('=');
        if (at <= 0) {
            throw new IllegalArgumentException(number + ": " + spec + " is no matcher");
        }
        String key = spec.substring(0, at);
        String value = spec.substring(at + 1);
        switch (key) {
            case "text":
                return "text=\"" + value + "\"";
            case "contains":
            case "xml":
                return value;
            case "id":
                return "id/" + value + "\"";
            case "desc":
                return "content-desc=\"" + value + "\"";
            case "class":
                return "class=\"" + value + "\"";
            default:
                throw new IllegalArgumentException(number + ": no matcher called " + key);
        }
    }

    //
    // --- running it -------------------------------------------------------

    @Override
    public void run() {
        try {
            for (Step step : steps) {
                if (!step(step)) {
                    answer(1, step.number + ": " + step.text());
                    return;
                }
            }
            answer(0, "");
        } catch (RuntimeException e) {
            Log.w(TAG, "the sequence fell over", e);
            answer(1, e.getClass().getSimpleName() + ": " + e.getMessage());
        } finally {
            service.sequenceFinished();
        }
    }

    private void answer(int code, String data) {
        synchronized (answer) {
            if (answered) {
                return;
            }
            answered = true;
            pending.setResultCode(code);
            pending.setResultData(data);
            pending.finish();
        }
    }

    /** One instruction, with its start and end in the record whatever it did. */
    private boolean step(Step step) {
        long start = SystemClock.elapsedRealtimeNanos();
        boolean done = exec(step);
        long end = SystemClock.elapsedRealtimeNanos();
        // A touch and a key already write their own line, with the instant the
        // gesture was dispatched; a second one here would say it twice.
        switch (step.verb) {
            case "tap":
            case "swipe":
            case "back":
            case "home":
            case "keyboard-off":
                break;
            default:
                service.action(step.verb, step.text() + (done ? "" : " — failed"), start, end);
                break;
        }
        if (!done) {
            Log.w(TAG, "sequence stopped at " + step.number + ": " + step.text());
        }
        return done;
    }

    private boolean exec(Step step) {
        String[] a = step.args;
        switch (step.verb) {
            case "tap":
                return service.tap(Integer.parseInt(a[0]), Integer.parseInt(a[1]));
            case "swipe":
                return service.swipe(Integer.parseInt(a[0]), Integer.parseInt(a[1]),
                        Integer.parseInt(a[2]), Integer.parseInt(a[3]),
                        a.length > 4 ? Math.max(1, Integer.parseInt(a[4])) : 200);
            case "back":
                return service.back();
            case "home":
                return service.home();
            case "keyboard-off":
                return service.hideKeyboard();
            case "text":
                return service.type(a[0]);
            case "tap-id":
                // An id, as the harness writes it: the last part of a resource id.
                return tapOn("id/" + a[0] + "\"",
                        a.length > 1 ? Integer.parseInt(a[1]) : DEFAULT_TAP_MS, false);
            case "tap-text":
                return tapOn("text=\"" + a[0] + "\"",
                        a.length > 1 ? Integer.parseInt(a[1]) : DEFAULT_TAP_MS, true);
            case "wait":
                return waitFor(needle(step.number, a[0]),
                        a.length > 1 ? Integer.parseInt(a[1]) : DEFAULT_WAIT_MS);
            case "wait-gone":
                return waitGone(needle(step.number, a[0]),
                        a.length > 1 ? Integer.parseInt(a[1]) : DEFAULT_WAIT_MS);
            case "wait-change":
                return waitChange(a.length > 0 ? Integer.parseInt(a[0]) : DEFAULT_WAIT_MS);
            case "wait-quiet":
                return waitQuiet(Integer.parseInt(a[0]),
                        a.length > 1 ? Integer.parseInt(a[1]) : DEFAULT_WAIT_MS);
            case "expect":
                return holds(needle(step.number, a[0]));
            case "expect-gone":
                return !holds(needle(step.number, a[0]));
            default:
                return false;
        }
    }

    //
    // --- looking at the screen --------------------------------------------

    private String screen() {
        return service.screen();
    }

    private boolean holds(String needle) {
        String xml = screen();
        return xml != null && xml.contains(needle);
    }

    /** The centre of the node the needle names, or null while it is not there. */
    private int[] centre(String needle) {
        String xml = screen();
        if (xml == null) {
            return null;
        }
        int at = xml.indexOf(needle);
        if (at < 0) {
            return null;
        }
        int lineEnd = xml.indexOf('\n', at);
        Matcher bounds = BOUNDS.matcher(lineEnd < 0 ? xml.substring(at) : xml.substring(at, lineEnd));
        if (!bounds.find()) {
            return null;
        }
        int left = Integer.parseInt(bounds.group(1));
        int top = Integer.parseInt(bounds.group(2));
        int right = Integer.parseInt(bounds.group(3));
        int bottom = Integer.parseInt(bounds.group(4));
        if (right <= left || bottom <= top) {
            return null;
        }
        return new int[] {(left + right) / 2, (top + bottom) / 2};
    }

    /**
     * Tap what a needle names, waiting for it to turn up. A text can be on a
     * menu that is still sliding in, so its place has to hold still for two
     * looks first — a tap at where the item was a moment ago lands on whatever
     * moved into it.
     */
    private boolean tapOn(String needle, int timeoutMs, boolean steady) {
        long deadline = SystemClock.uptimeMillis() + Math.max(1, timeoutMs);
        int[] seen = null;
        while (true) {
            int[] at = centre(needle);
            if (at != null) {
                if (!steady || (seen != null && seen[0] == at[0] && seen[1] == at[1])) {
                    return service.tap(at[0], at[1]);
                }
                seen = at;
            } else {
                seen = null;
            }
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0) {
                Log.w(TAG, "no " + needle + " to tap after " + timeoutMs + " ms");
                return false;
            }
            service.awaitScreenEvent(Math.min(left, LOOK_MS));
        }
    }

    private boolean waitFor(String needle, int timeoutMs) {
        long deadline = SystemClock.uptimeMillis() + Math.max(1, timeoutMs);
        while (true) {
            if (holds(needle)) {
                return true;
            }
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0) {
                Log.w(TAG, "the screen never held " + needle);
                return false;
            }
            service.awaitScreenEvent(Math.min(left, LOOK_MS));
        }
    }

    private boolean waitGone(String needle, int timeoutMs) {
        long deadline = SystemClock.uptimeMillis() + Math.max(1, timeoutMs);
        while (true) {
            if (!holds(needle)) {
                return true;
            }
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0) {
                Log.w(TAG, "the screen never let go of " + needle);
                return false;
            }
            service.awaitScreenEvent(Math.min(left, LOOK_MS));
        }
    }

    private boolean waitChange(int timeoutMs) {
        long events = service.screenEvents();
        long deadline = SystemClock.uptimeMillis() + Math.max(1, timeoutMs);
        while (true) {
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0) {
                return false;
            }
            service.awaitScreenEvent(left);
            if (service.screenEvents() != events) {
                return true;
            }
        }
    }

    /**
     * Still for that long: the barrier a step wants after a tap that animates.
     *
     * <p>The window starts now, not at the last event before the tap: a screen
     * that had already been quiet for a while says nothing about the tap that
     * has not been drawn yet, so waiting from the last event would be a wait
     * that ends the instant it starts. Every event restarts the window, which
     * is what "still" means.
     */
    private boolean waitQuiet(long quietMs, int timeoutMs) {
        long started = SystemClock.uptimeMillis();
        long deadline = started + Math.max(1, timeoutMs);
        while (true) {
            long since = Math.min(service.stillForMs(),
                    SystemClock.uptimeMillis() - started);
            if (since >= quietMs) {
                return true;
            }
            long left = deadline - SystemClock.uptimeMillis();
            if (left <= 0) {
                return false;
            }
            service.awaitScreenEvent(Math.min(left, quietMs - since));
        }
    }

}
