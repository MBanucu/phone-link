package org.phonelink.proxy;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.RadioGroup;
import android.widget.TextView;

import java.util.List;

/**
 * The page of an open proxy: its settings, the three segments, the line under
 * the button, the counters and the log.
 *
 * <p>Asked for by the activity, which keeps what a press means — Save, Rename,
 * Start — and asks this for the form it would save. The page knows which proxy
 * it is showing, so the name a card is drawn under and the name a page starts
 * cannot drift apart.
 *
 * <p>Rendering is split the same way as the list's: a proxy's own state arrives
 * as often as a connection comes and goes, and only the parts that change are
 * touched; the form is loaded in one go when the page opens.
 */
final class ProxyScreen {

    /** What the page asks the activity for: the decisions it does not make. */
    interface Actions {
        /** The one button under the page: start this proxy, or stop it. */
        void toggle();

        /** Save the form under the name the page is showing. */
        void save();

        /** Throw the edits away. */
        void revert();

        /** The auto-start switch moved, so the warning above may have too. */
        void autoStartChanged();

        /** The wireless-debugging switch moved; whether it may be stored is policy. */
        void adbWirelessChanged(boolean on);

        /** The battery line was tapped: open the system's exemption screen. */
        void batteryHelp();
    }

    private final Activity activity;
    private final RadioGroup tabs;
    private final View listenerPage;
    private final View servicePage;
    private final View logPage;
    private final EditText port;
    private final EditText user;
    private final EditText password;
    private final EditText ssid;
    private final CheckBox anonymous;
    private final CheckBox anyNetwork;
    private final CheckBox autoStart;
    private final CheckBox adbWireless;
    private final TextView battery;
    private final TextView adbState;
    private final TextView pending;
    private final TextView pendingService;
    private final TextView footerState;
    private final TextView logText;
    private final TextView traffic;
    private final TrafficView trafficGraph;
    private final Button toggle;
    private final int batteryColor;
    private final Actions actions;

    /** The saved proxy the fields belong to; null while the list is up. */
    private String name;
    /** Set while a proxy is put into the form, so nothing is stored. */
    private boolean loading;

    /** Assigned with the views: it needs the activity it hops to. */
    private final Runnable logListener;

    private final Handler handler = new Handler(Looper.getMainLooper());

    /**
     * One sample per second while the panel is in front: the counters are
     * integers, and the graph's resolution is exactly this interval.
     */
    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            // Every running proxy is sampled, so its graph has no hole in it
            // when it is opened; the page shows the one being looked at.
            for (ProxyRuntime.Proxy live : ProxyRuntime.running()) {
                live.traffic.sample();
            }
            if (name != null) {
                renderTraffic();
            }
            handler.postDelayed(this, 1000);
        }
    };

    ProxyScreen(Activity activity, View screen, Actions actions) {
        this.activity = activity;
        this.actions = actions;
        tabs = screen.findViewById(R.id.tabs);
        listenerPage = screen.findViewById(R.id.page_listener);
        servicePage = screen.findViewById(R.id.page_service);
        logPage = screen.findViewById(R.id.page_log);
        port = screen.findViewById(R.id.port);
        user = screen.findViewById(R.id.user);
        password = screen.findViewById(R.id.password);
        ssid = screen.findViewById(R.id.ssid);
        anonymous = screen.findViewById(R.id.anonymous);
        anyNetwork = screen.findViewById(R.id.any_network);
        autoStart = screen.findViewById(R.id.auto_start);
        adbWireless = screen.findViewById(R.id.adb_wifi);
        battery = screen.findViewById(R.id.battery);
        adbState = screen.findViewById(R.id.adb_state);
        pending = screen.findViewById(R.id.pending);
        pendingService = screen.findViewById(R.id.pending_service);
        footerState = screen.findViewById(R.id.footer_state);
        logText = screen.findViewById(R.id.log_text);
        traffic = screen.findViewById(R.id.traffic);
        trafficGraph = screen.findViewById(R.id.traffic_graph);
        toggle = screen.findViewById(R.id.toggle);
        batteryColor = battery.getCurrentTextColor();
        logListener = () -> activity.runOnUiThread(() -> {
            if (name != null) {
                renderLog();
            }
        });

        tabs.setOnCheckedChangeListener((group, checked) -> showPage(checked));
        screen.findViewById(R.id.log_clear).setOnClickListener(view -> EventLog.clear());
        screen.findViewById(R.id.save).setOnClickListener(view -> actions.save());
        screen.findViewById(R.id.save_service).setOnClickListener(view -> actions.save());
        screen.findViewById(R.id.revert).setOnClickListener(view -> actions.revert());
        screen.findViewById(R.id.revert_service).setOnClickListener(view -> actions.revert());
        toggle.setOnClickListener(view -> actions.toggle());
        // Unlike the fields this is one preference, not part of a start: it takes
        // effect on the next SSID match either way, so saving it now is what the
        // checkbox appears to promise.
        adbWireless.setOnCheckedChangeListener((button, checked) -> {
            if (!loading) {
                actions.adbWirelessChanged(checked);
            }
        });
        autoStart.setOnCheckedChangeListener((button, checked) -> actions.autoStartChanged());
        watchForEdits();
    }

    // -- what the page is showing ----------------------------------------

    /** Put a saved proxy into the form and draw its page. */
    void open(String name) {
        ProxyConfig config = ConfigStore.profile(activity, name);
        if (config == null) {
            close();
            return;
        }
        this.name = name;
        loading = true;
        try {
            port.setText(Integer.toString(config.port));
            user.setText(config.user);
            password.setText(config.password);
            ssid.setText(config.ssid);
            anonymous.setChecked(config.anonymous);
            anyNetwork.setChecked(config.anyNetwork);
            autoStart.setChecked(ConfigStore.profileAutoStart(activity, name));
            adbWireless.setChecked(ConfigStore.profileAdbWireless(activity, name));
        } finally {
            loading = false;
        }
        listenerPage.scrollTo(0, 0);
        servicePage.scrollTo(0, 0);
        renderAdbState();
        renderPending();
        renderLog();
        renderTraffic();
        renderToggle();
    }

    /** The page is not showing a proxy any more. */
    void close() {
        name = null;
    }

    String name() {
        return name;
    }

    boolean isOpen() {
        return name != null;
    }

    // -- rendering -------------------------------------------------------

    /** What the service says about the proxies, which is all the page follows. */
    void render() {
        renderToggle();
        renderTraffic();
    }

    /** The one button under an open proxy: Start, or Stop when it is running. */
    void renderToggle() {
        boolean running = isRunning();
        toggle.setText(running ? R.string.action_stop : R.string.action_start);
        toggle.setBackgroundTintList(ColorStateList.valueOf(
                running ? activity.getColor(R.color.traffic_base) : Accent.of(activity)));
        toggle.setTextColor(activity.getColor(android.R.color.white));
        if (name == null) {
            return;
        }
        ProxyRuntime.Proxy live = ProxyRuntime.forName(name);
        if (live != null) {
            // This proxy's own line, whether or not others are running too.
            footerState.setText(live.state.describe());
        } else {
            // A start adds this proxy; only a listener that already holds its
            // port is replaced, so the line says which one this would be.
            int open = formPort();
            switch (ProxyState.footer(ProxyRuntime.states(), open)) {
                case REPLACES:
                    footerState.setText(activity.getString(R.string.footer_replaces, open));
                    break;
                case BESIDE:
                    footerState.setText(R.string.footer_beside);
                    break;
                default:
                    footerState.setText(R.string.footer_stopped);
                    break;
            }
        }
    }

    /** The totals line above the sparkline; the graph reads the same counters. */
    void renderTraffic() {
        Traffic counts = traffic();
        if (counts == null) {
            counts = new Traffic();
        }
        long[] totals = counts.totals();
        long[] rates = counts.history()[0].length == 0
                ? new long[] {0, 0}
                : lastSample(counts);
        trafficGraph.setTraffic(traffic());
        // A graph with no line in it is a hole in the page; the sentence says
        // the same thing in less room.
        boolean idle = totals[0] == 0 && totals[1] == 0;
        trafficGraph.setVisibility(idle ? View.GONE : View.VISIBLE);
        if (idle) {
            traffic.setText(R.string.traffic_none);
        } else {
            traffic.setText(activity.getString(R.string.traffic_totals,
                    Traffic.human(totals[1]), Traffic.human(totals[0]),
                    Traffic.human(rates[1]), Traffic.human(rates[0])));
        }
        trafficGraph.invalidate();
    }

    /** This proxy's events, newest first; EventLog is small and in memory. */
    void renderLog() {
        List<String> entries = EventLog.forProfile(name);
        logText.setText(entries.isEmpty()
                ? activity.getString(R.string.log_empty)
                : String.join("\n", entries));
    }

    void renderPending() {
        boolean changed = pendingChanges();
        pending.setVisibility(changed ? View.VISIBLE : View.GONE);
        pendingService.setVisibility(changed ? View.VISIBLE : View.GONE);
    }

    /**
     * What Android's wireless debugging is doing right now — not what the
     * switch promises — and why the app cannot help when the permission that
     * lets it write that setting was never granted.
     */
    void renderAdbState() {
        if (!AdbWireless.granted(activity)) {
            adbState.setText(R.string.adb_wifi_ungranted);
            return;
        }
        if (AdbWireless.on(activity)) {
            adbState.setText(R.string.adb_wifi_state_on);
            return;
        }
        adbState.setText(ConfigStore.adbWireless(activity)
                ? R.string.adb_wifi_state_off
                : R.string.adb_wifi_state_off_manual);
    }

    /**
     * The battery line. What the phone allows is the activity's question; this
     * only says it, and colours it when a promise would not be kept.
     */
    void renderBattery(boolean exempt, boolean warning) {
        battery.setText(activity.getString(
                exempt ? R.string.battery_exempt : R.string.battery_optimized));
        battery.setTextColor(warning ? activity.getColor(R.color.warning) : batteryColor);
        battery.setTypeface(null, warning ? Typeface.BOLD : Typeface.NORMAL);
        battery.setClickable(!exempt);
        battery.setOnClickListener(exempt ? null : view -> actions.batteryHelp());
    }

    /** One of the three segments of an open proxy, and nothing else. */
    void showPage(int checked) {
        boolean service = checked == R.id.tab_service;
        boolean log = checked == R.id.tab_log;
        listenerPage.setVisibility(service || log ? View.GONE : View.VISIBLE);
        servicePage.setVisibility(service ? View.VISIBLE : View.GONE);
        logPage.setVisibility(log ? View.VISIBLE : View.GONE);
        if (log) {
            renderLog();
            renderTraffic();
        }
    }

    int checkedTab() {
        return tabs.getCheckedRadioButtonId();
    }

    // -- the form --------------------------------------------------------

    void start() {
        EventLog.addListener(logListener);
        handler.post(ticker);
    }

    void stop() {
        EventLog.removeListener(logListener);
        handler.removeCallbacks(ticker);
    }

    /**
     * The two switches, as the store has them: adb can change either one
     * ({@code --ez auto_start}, {@code --ez adb_wifi}) while the page is open.
     */
    void syncSwitches() {
        loading = true;
        try {
            autoStart.setChecked(ConfigStore.autoStart(activity));
            adbWireless.setChecked(ConfigStore.adbWireless(activity));
        } finally {
            loading = false;
        }
    }

    boolean autoStartChecked() {
        return autoStart.isChecked();
    }

    boolean adbWirelessChecked() {
        return adbWireless.isChecked();
    }

    /** Throw the edits away: the form is filled from the store again. */
    void revert() {
        if (name != null) {
            open(name);
        }
    }

    ProxyConfig readFields() {
        return ProxyConfig.of(
                readPort(),
                user.getText().toString(),
                password.getText().toString(),
                ssid.getText().toString(),
                anyNetwork.isChecked(),
                anonymous.isChecked());
    }

    /** The port the form would start on, for a footer that has to name it. */
    int formPort() {
        ProxyConfig saved = name == null ? null : ConfigStore.profile(activity, name);
        return readPortOr(saved == null ? 0 : saved.port);
    }

    /** Whether the fields say something other than the saved proxy does. */
    boolean pendingChanges() {
        ProxyConfig stored = name == null ? null : ConfigStore.profile(activity, name);
        if (stored == null) {
            return false;
        }
        boolean anonymousNow = anonymous.isChecked();
        // An anonymous proxy stores no credentials at all, so the fields have
        // to be compared the way ProxyConfig.of() would keep them; otherwise a
        // proxy that listens without authentication would look unsaved forever.
        String userNow = anonymousNow ? "" : user.getText().toString();
        String passwordNow = anonymousNow ? "" : password.getText().toString();
        return readPortOr(-1) != stored.port
                || !userNow.equals(stored.user)
                || !passwordNow.equals(stored.password)
                || !ssid.getText().toString().equals(stored.ssid)
                || anonymousNow != stored.anonymous
                || anyNetwork.isChecked() != stored.anyNetwork
                || autoStart.isChecked() != ConfigStore.profileAutoStart(activity, name)
                || adbWireless.isChecked() != ConfigStore.profileAdbWireless(activity, name);
    }

    // -- the details -----------------------------------------------------

    /**
     * The fields do nothing until Save or Start, which is not obvious from a
     * form that looks applied, so edits get a line of their own on both of the
     * pages that hold fields.
     */
    private void watchForEdits() {
        TextWatcher watcher = new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence text, int start, int count, int after) {
            }

            @Override
            public void onTextChanged(CharSequence text, int start, int before, int count) {
                renderPending();
            }

            @Override
            public void afterTextChanged(Editable text) {
            }
        };
        port.addTextChangedListener(watcher);
        user.addTextChangedListener(watcher);
        password.addTextChangedListener(watcher);
        ssid.addTextChangedListener(watcher);
        anonymous.setOnCheckedChangeListener((button, checked) -> renderPending());
        anyNetwork.setOnCheckedChangeListener((button, checked) -> renderPending());
    }

    private boolean isRunning() {
        return name != null && ProxyRuntime.forName(name) != null;
    }

    /** This proxy's counters, or nothing while it is not running. */
    private Traffic traffic() {
        ProxyRuntime.Proxy live = name == null ? null : ProxyRuntime.forName(name);
        return live == null ? null : live.traffic;
    }

    /** The newest interval's {up, down} rates. */
    private long[] lastSample(Traffic counts) {
        long[][] history = counts.history();
        long[] rates = history[0];
        return new long[] {rates[rates.length - 1], history[1][history[1].length - 1]};
    }

    private int readPort() {
        try {
            return Integer.parseInt(port.getText().toString().trim());
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("port must be a number");
        }
    }

    /** The field as an int, or `fallback` while it is not a number at all. */
    private int readPortOr(int fallback) {
        try {
            return Integer.parseInt(port.getText().toString().trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
