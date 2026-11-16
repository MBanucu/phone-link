package org.phonelink.proxytest;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.content.res.Resources;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.TextView;

import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The panel's own checks, run inside the proxy's process instead of looked at
 * from a capture.
 *
 * <p>No JUnit and no androidx: {@code am instrument} loads this class into the
 * app's process, {@link #onStart()} starts the activity and walks its views, so
 * a check about the page is a check about the page — text, visibility, the word
 * on a button — with nothing between the assertion and the view. Waiting is a
 * poll of the view, not of a captured hierarchy, and a failure reports the text
 * it actually found.
 *
 * <p>What this cannot check, and does not try to: anything outside the app's own
 * process. A port serving is the laptop's business (the harness connects to it
 * over the network), a capture of the screen is the capture service's, dumpsys
 * and logcat belong to adb. That is also why the harness still decides what a
 * verdict means: this reports claims, the harness records them.
 *
 * <p>One thing to know before putting this in the middle of a run:
 * {@code am instrument} starts the app's process again, so a listener that was
 * running before it goes away with the old one. The checks below start what
 * they need from the page and stop it again, and the harness runs them where
 * nothing else is supposed to be listening.
 */
public final class PanelTests extends Instrumentation {

    /**
     * The package the app's classes and its adb actions are named in. It stays
     * this whatever the app is installed as: build.sh relinks the manifest
     * under a second id (org.phonelink.proxy.test) and the classes keep their
     * package, so a component is the installed id plus a class from here, and
     * an action string is a literal from here.
     */
    private static final String CODE = "org.phonelink.proxy";

    /** The application id of the app under test, which is whatever it is installed as. */
    private String target;
    /** Long enough for a foreground service to come up and the page to hear it. */
    private static final long RUN_TIMEOUT_MS = 20000;
    /** How many claims the run above makes, so a run that stopped early says so. */
    private static final int CLAIMS = 9;

    private Activity activity;
    private Resources res;
    private int passed;
    private int failed;
    /** Set when a check proved false, so the checks after it are not attempted. */
    private boolean aborted;
    /** What the harness passed with -e; onCreate is the only place it arrives. */
    private Bundle args;

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        args = arguments;
        start();
    }

    @Override
    public void onStart() {
        String first = args == null ? null : args.getString("first");
        String second = args == null ? null : args.getString("second");
        try {
            target = getTargetContext().getPackageName();
            res = getTargetContext().getResources();
            if (first == null || second == null) {
                check("the harness names two saved proxies", false,
                        "first=" + first + " second=" + second);
            } else {
                run(first, second);
            }
        } catch (Throwable e) {
            check("the page checks run to the end", false, e.toString());
        }
        // A run that stopped at a failed claim reports fewer than the claims it
        // meant to make; saying so keeps a half-run from looking like a shorter
        // green one.
        int ran = passed + failed;
        meta("the phone made all " + CLAIMS + " of the page's checks",
                ran == CLAIMS, ran + " of " + CLAIMS + " reported");
        if (failed > 0) {
            // Nothing here may leave a listener behind: that would turn one
            // failed check into every later step's failure.
            stopEverything();
        }
        Bundle result = new Bundle();
        result.putString(REPORT_KEY_STREAMRESULT,
                passed + " passed, " + failed + " failed\n");
        finish(failed == 0 ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }

    private void run(String first, String second) {
        launch();

        View a = card(first);
        View b = card(second);
        check("the list shows both saved proxies, both stopped and offering Start",
                a != null && b != null && stopped(a) && stopped(b),
                outline(first) + " / " + outline(second));
        if (abandoned()) {
            return;
        }

        // The card's own button: a real foreground service, in this process.
        click(a.findViewById(id("card_toggle")));
        check("starting one from its card runs it, and marks it in use",
                await(() -> running(card(first))),
                outline(first));
        if (abandoned()) {
            return;
        }

        // The claim the footer was rewritten for: with one proxy up, opening
        // the other says a start adds it rather than replacing anything.
        View page = card(second);
        click(page);
        String beside = string("footer_beside");
        check("the other's page says Start adds it beside the running one",
                await(() -> beside.equals(footer())),
                "footer=" + footer() + " header=" + header());
        if (abandoned()) {
            return;
        }
        check("and the page is the second proxy's own",
                second.equals(header()), "header=" + header());

        String port = field("port");
        click(id("toggle"));
        check("the page's Start runs it, and the page says on which port",
                await(() -> string("action_stop").equals(toggleText())
                        && footer().startsWith("listening on 0.0.0.0:" + port)),
                "footer=" + footer() + " button=" + toggleText() + " port=" + port);
        if (abandoned()) {
            return;
        }

        click(id("back"));
        check("the list marks both running, both in use, each offering Stop",
                await(() -> running(card(first)) && running(card(second))),
                outline(first) + " / " + outline(second));
        if (abandoned()) {
            return;
        }

        // A page's Stop is about the proxy on it: the other keeps listening,
        // and this page goes back to saying what a start would do.
        click(card(second));
        click(id("toggle"));
        check("the page's Stop stops that one and says it is beside the other",
                await(() -> string("action_start").equals(toggleText())
                        && beside.equals(footer())),
                "footer=" + footer() + " button=" + toggleText());
        click(id("back"));
        check("and the other one still runs with its mark, the second back to Start",
                running(card(first)) && stopped(card(second)),
                outline(first) + " / " + outline(second));
        if (abandoned()) {
            return;
        }

        click(card(first).findViewById(id("card_toggle")));
        check("the card stops the last one, which goes back to Start without the mark",
                await(() -> stopped(card(first))),
                outline(first));
    }

    // -- driving the app -------------------------------------------------

    private void launch() {
        Intent intent = new Intent(Intent.ACTION_MAIN)
                .setClassName(target, CODE + ".MainActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        activity = startActivitySync(intent);
        waitForIdleSync();
        // The first render is a broadcast away; the checks that follow wait on
        // what they need, so this is only about not reading a half-built list.
        SystemClock.sleep(500);
        waitForIdleSync();
    }

    /** The card of a saved proxy on the home screen, or null. */
    private View card(String name) {
        ViewGroup list = (ViewGroup) activity.findViewById(id("profile_list"));
        for (int index = 0; index < list.getChildCount(); index++) {
            View child = list.getChildAt(index);
            if (name.equals(String.valueOf(child.getTag()))) {
                return child;
            }
        }
        return null;
    }

    private void click(View view) {
        runOnMainSync(view::performClick);
        waitForIdleSync();
    }

    private void click(int viewId) {
        View view = activity.findViewById(viewId);
        if (view != null) {
            click(view);
        }
    }

    /** Stopped, and its button offering the one thing a stopped proxy can do. */
    private boolean stopped(View card) {
        return card != null
                && badge(card).equals(string("state_stopped"))
                && button(card).equals(string("action_start"));
    }

    /** Running, wearing the in-use mark, and its button offering Stop. */
    private boolean running(View card) {
        return card != null
                && badge(card).equals(string("state_running"))
                && summary(card).startsWith(string("card_in_use", "").trim())
                && button(card).equals(string("action_stop"));
    }

    private String button(View card) {
        return ((Button) card.findViewById(id("card_toggle"))).getText().toString();
    }

    private String badge(View card) {
        return text(card, "card_state");
    }

    private String summary(View card) {
        return text(card, "card_summary");
    }

    private String outline(String name) {
        View card = card(name);
        if (card == null) {
            return name + ": no card";
        }
        return name + ": " + badge(card) + " · \"" + summary(card) + "\" · "
                + button(card);
    }

    private String footer() {
        return text(id("footer_state"));
    }

    private String toggleText() {
        return text(id("toggle"));
    }

    private String header() {
        return text(id("header_title"));
    }

    private String field(String name) {
        TextView view = (TextView) activity.findViewById(id(name));
        return view.getText().toString();
    }

    private String text(View parent, String name) {
        TextView view = (TextView) parent.findViewById(id(name));
        return view.getText().toString();
    }

    private String text(int viewId) {
        TextView view = (TextView) activity.findViewById(viewId);
        return view == null ? "" : view.getText().toString();
    }

    // -- results ---------------------------------------------------------

    /**
     * One claim, printed for the harness. The keys are fixed because the harness
     * reads them line by line out of {@code am instrument -w}: `check`,
     * `verdict`, and `detail`, which is what the phone actually saw.
     */
    private void check(String claim, boolean pass, String detail) {
        Bundle status = new Bundle();
        status.putString("check", claim);
        status.putString("verdict", pass ? "pass" : "fail");
        status.putString("detail", oneLine(detail));
        sendStatus(pass ? 0 : 1, status);
        if (pass) {
            passed++;
        } else {
            failed++;
        }
        if (!pass) {
            aborted = true;
        }
    }

    /** A claim about this run itself: reported, counted, never attempted after. */
    private void meta(String claim, boolean pass, String detail) {
        Bundle status = new Bundle();
        status.putString("check", claim);
        status.putString("verdict", pass ? "pass" : "fail");
        status.putString("detail", oneLine(detail));
        sendStatus(pass ? 0 : 1, status);
        if (!pass) {
            failed++;
        }
    }

    private boolean abandoned() {
        if (aborted) {
            check("the rest of the page's checks could not run", false,
                    "stopped at the check above");
        }
        return aborted;
    }

    private static String oneLine(String text) {
        if (text == null) {
            return "";
        }
        String flat = text.replace('\n', ' ').replace('\r', ' ');
        return flat.length() > 300 ? flat.substring(0, 300) : flat;
    }

    // -- waiting ---------------------------------------------------------

    private boolean await(Callable<Boolean> until) {
        long deadline = SystemClock.uptimeMillis() + RUN_TIMEOUT_MS;
        while (SystemClock.uptimeMillis() < deadline) {
            if (is(until)) {
                return true;
            }
            SystemClock.sleep(100);
        }
        return is(until);
    }

    private boolean is(Callable<Boolean> call) {
        AtomicReference<Boolean> out = new AtomicReference<>(false);
        runOnMainSync(() -> {
            try {
                out.set(Boolean.TRUE.equals(call.call()));
            } catch (Exception e) {
                out.set(false);
            }
        });
        return out.get();
    }

    // -- the app's own words ---------------------------------------------

    private int id(String name) {
        // The resource table is not renamed with the app id, so an id keeps the
        // code package whatever the app is installed as.
        return res.getIdentifier(name, "id", CODE);
    }

    private String string(String name, Object... args) {
        int id = res.getIdentifier(name, "string", CODE);
        return args.length == 0 ? res.getString(id) : res.getString(id, args);
    }

    /** Last resort, so a failed run does not leave a port open. */
    private void stopEverything() {
        try {
            getTargetContext().startService(new Intent()
                    .setClassName(target, CODE + ".ProxyService")
                    .setAction(CODE + ".action.STOP"));
        } catch (RuntimeException e) {
            // The service may already be gone with the activity; nothing to do.
        }
    }
}
