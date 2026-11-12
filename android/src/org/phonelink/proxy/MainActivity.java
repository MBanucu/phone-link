package org.phonelink.proxy;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.database.ContentObserver;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Menu;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * The panel: the same settings and the same two actions as the adb contract.
 *
 * <p>Home is the list of saved proxies, each with the state it is in and its own
 * Start/Stop, because that is what the app is for. Opening one splits it into
 * three segments — what the listener is, what the service does with it, and what
 * it has done — with a single toggle that follows that proxy's state. Every
 * control that is not self-explanatory carries the same "i" mark, and the
 * header's marks are icons rather than the platform's old text buttons.
 *
 * <p>The activity and the service run in one process, so the live state comes
 * from {@link ProxyRuntime} rather than a binder. Starting the service from a
 * visible activity is allowed, including the location foreground type the SSID
 * match needs.
 */
public final class MainActivity extends Activity implements ProxyRuntime.Listener {

    /** The proxy that was open, so a rotation does not send the user home. */
    private static final String STATE_PROFILE = "open_profile";
    /** The segment that was showing for the same reason. */
    private static final String STATE_TAB = "tab";

    private View back;
    private TextView headerTitle;
    private View warning;
    private ScrollView homeScreen;
    private LinearLayout profileScreen;
    private LinearLayout profileList;
    private TextView homeEmpty;

    private RadioGroup tabs;
    private View listenerPage;
    private View servicePage;
    private View logPage;

    private EditText port;
    private EditText user;
    private EditText password;
    private EditText ssid;
    private CheckBox anonymous;
    private CheckBox anyNetwork;
    private CheckBox autoStart;
    private CheckBox adbWireless;
    private TextView battery;
    /** The colour the battery line has when it is not a warning. */
    private int batteryColor;
    private TextView adbState;
    private TextView pending;
    private TextView pendingService;
    private TextView footerState;
    private TextView logText;
    private TextView traffic;
    private TrafficView trafficGraph;
    private Button toggle;

    /** The saved proxy the fields belong to; null while the list is up. */
    private String editing;
    /** Set while a proxy is put into the form, so nothing is stored. */
    private boolean loading;

    /**
     * The two preferences behind the checkboxes can also be changed over adb
     * ({@code --ez auto_start …}, {@code --ez adb_wifi …}), so the panel follows
     * the store instead of trusting what it wrote itself.
     */
    private final SharedPreferences.OnSharedPreferenceChangeListener preferences =
            (sharedPreferences, key) -> runOnUiThread(() -> {
                if (ConfigStore.KEY_ADB_WIFI.equals(key)) {
                    adbWireless.setChecked(ConfigStore.adbWireless(this));
                    renderAdbState();
                } else if (ConfigStore.KEY_AUTO_START.equals(key)) {
                    autoStart.setChecked(ConfigStore.autoStart(this));
                } else if (ConfigStore.KEY_SELECTED_PROFILE.equals(key)) {
                    return;
                } else if (ConfigStore.KEY_PROFILES.equals(key)) {
                    // A proxy saved, started, renamed or deleted over adb is a card.
                    renderHome();
                    if (editing != null && ConfigStore.profile(this, editing) == null) {
                        showHome();
                    }
                } else {
                    refreshCards();
                }
            });

    /** Android's own switch can change under us — the service flips it too. */
    private final ContentObserver adbSetting = new ContentObserver(
            new Handler(Looper.getMainLooper())) {
        @Override
        public void onChange(boolean selfChange) {
            renderAdbState();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        back = findViewById(R.id.back);
        headerTitle = findViewById(R.id.header_title);
        warning = findViewById(R.id.warning);
        homeScreen = findViewById(R.id.screen_home);
        profileScreen = findViewById(R.id.screen_profile);
        profileList = findViewById(R.id.profile_list);
        homeEmpty = findViewById(R.id.home_empty);
        tabs = findViewById(R.id.tabs);
        listenerPage = findViewById(R.id.page_listener);
        servicePage = findViewById(R.id.page_service);
        logPage = findViewById(R.id.page_log);
        port = findViewById(R.id.port);
        user = findViewById(R.id.user);
        password = findViewById(R.id.password);
        ssid = findViewById(R.id.ssid);
        anonymous = findViewById(R.id.anonymous);
        anyNetwork = findViewById(R.id.any_network);
        autoStart = findViewById(R.id.auto_start);
        adbWireless = findViewById(R.id.adb_wifi);
        battery = findViewById(R.id.battery);
        batteryColor = battery.getCurrentTextColor();
        adbState = findViewById(R.id.adb_state);
        pending = findViewById(R.id.pending);
        pendingService = findViewById(R.id.pending_service);
        footerState = findViewById(R.id.footer_state);
        logText = findViewById(R.id.log_text);
        traffic = findViewById(R.id.traffic);
        trafficGraph = findViewById(R.id.traffic_graph);
        toggle = findViewById(R.id.toggle);

        tabs.setOnCheckedChangeListener((group, checked) -> showPage(checked));
        // The warning mark is the same warning as the battery line, and one tap
        // from the fix.
        warning.setOnClickListener(view -> askForExemption());
        findViewById(R.id.info).setOnClickListener(view -> showHelp());
        findViewById(R.id.menu).setOnClickListener(this::showMenu);
        back.setOnClickListener(view -> showHome());
        findViewById(R.id.new_profile).setOnClickListener(view -> askProfileName(null));
        findViewById(R.id.save).setOnClickListener(view -> saveForm());
        findViewById(R.id.save_service).setOnClickListener(view -> saveForm());
        findViewById(R.id.revert).setOnClickListener(view -> revertForm());
        findViewById(R.id.revert_service).setOnClickListener(view -> revertForm());
        findViewById(R.id.log_clear).setOnClickListener(view -> EventLog.clear());
        toggle.setOnClickListener(view -> toggleOpenProxy());
        wireHelp();

        autoStart.setOnCheckedChangeListener((button, checked) -> renderBattery());
        // Unlike the fields this is one preference, not part of a start: it takes
        // effect on the next SSID match either way, so saving it now is what the
        // checkbox appears to promise.
        adbWireless.setOnCheckedChangeListener((button, checked) -> {
            if (loading) {
                // A proxy's settings are a draft until Save or Start.
                return;
            }
            ConfigStore.setAdbWireless(this, checked);
            EventLog.add(checked
                    ? "wireless debugging managed by the app"
                    : "wireless debugging left alone");
            if (checked && !AdbWireless.granted(this)) {
                Toast.makeText(this, R.string.adb_wifi_ungranted, Toast.LENGTH_LONG).show();
            }
        });
        watchForEdits();

        render(ProxyRuntime.state());
        String open = savedInstanceState == null
                ? null
                : savedInstanceState.getString(STATE_PROFILE);
        if (open != null && ConfigStore.profile(this, open) != null) {
            openProfile(open);
        } else {
            showHome();
        }
        tabs.check(savedInstanceState == null
                ? R.id.tab_listener
                : savedInstanceState.getInt(STATE_TAB, R.id.tab_listener));
        // check() only reports a change, so a page restored by the framework
        // would otherwise stay hidden.
        showPage(tabs.getCheckedRadioButtonId());
        if (getIntent().getBooleanExtra(Help.EXTRA_HELP, false)) {
            showHelp();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putString(STATE_PROFILE, editing);
        outState.putInt(STATE_TAB, tabs.getCheckedRadioButtonId());
    }

    /** One level up: from a proxy back to the list. */
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (editing != null) {
            showHome();
            return;
        }
        super.onBackPressed();
    }

    // -- the marks that explain ------------------------------------------

    /**
     * The "i" next to a control. One dialog, the same shape everywhere, so the
     * panel can say what a field is without spending a paragraph of the page on
     * it.
     */
    private void info(int mark, int title, int message) {
        findViewById(mark).setOnClickListener(view -> explain(title, message));
    }

    private void explain(int title, int message) {
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setMessage(message)
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    private void wireHelp() {
        info(R.id.info_port, R.string.info_port_title, R.string.info_port);
        info(R.id.info_user, R.string.info_user_title, R.string.info_user);
        info(R.id.info_password, R.string.info_password_title, R.string.info_password);
        info(R.id.info_ssid, R.string.info_ssid_title, R.string.info_ssid);
        info(R.id.info_anonymous, R.string.info_anonymous_title, R.string.info_anonymous);
        info(R.id.info_any_network, R.string.info_any_network_title, R.string.info_any_network);
        info(R.id.info_auto_start, R.string.info_auto_start_title, R.string.info_auto_start);
        info(R.id.info_adb_wifi, R.string.info_adb_wifi_title, R.string.info_adb_wifi);
        info(R.id.info_save, R.string.info_save_title, R.string.info_save);
        info(R.id.info_save_service, R.string.info_save_title, R.string.info_save);
        info(R.id.info_revert, R.string.info_revert_title, R.string.info_revert);
        info(R.id.info_revert_service, R.string.info_revert_title, R.string.info_revert);
        info(R.id.info_toggle, R.string.info_toggle_title, R.string.info_toggle);
        info(R.id.info_new, R.string.info_new_title, R.string.info_new);
        info(R.id.info_log, R.string.info_log_title, R.string.info_log);
    }

    // -- the segments ----------------------------------------------------

    /** One of the three segments of an open proxy, and nothing else. */
    private void showPage(int checked) {
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

    // -- the list -------------------------------------------------------

    private void showHome() {
        editing = null;
        headerTitle.setText(R.string.home_title);
        back.setVisibility(View.GONE);
        profileScreen.setVisibility(View.GONE);
        homeScreen.setVisibility(View.VISIBLE);
        renderHome();
        renderBattery();
    }

    /** Every saved proxy: what the app is for. */
    private void renderHome() {
        List<String> names = ConfigStore.profileNames(this);
        profileList.removeAllViews();
        homeEmpty.setVisibility(names.isEmpty() ? View.VISIBLE : View.GONE);
        for (String name : names) {
            ProxyConfig config = ConfigStore.profile(this, name);
            if (config == null) {
                continue;
            }
            View card = getLayoutInflater().inflate(R.layout.item_profile, profileList, false);
            card.setTag(name);
            ((TextView) card.findViewById(R.id.card_name)).setText(name);
            ((TextView) card.findViewById(R.id.card_summary)).setText(config.summary());
            ((TextView) card.findViewById(R.id.card_flags)).setText(getString(
                    R.string.card_flags,
                    ConfigStore.profileAutoStart(this, name) ? "on" : "off",
                    ConfigStore.profileAdbWireless(this, name) ? "on" : "off"));
            card.setOnClickListener(view -> openProfile(name));
            card.findViewById(R.id.card_toggle).setOnClickListener(
                    view -> toggleFromCard(name));
            profileList.addView(card);
        }
        refreshCards();
    }

    /**
     * A card's state is that proxy's own state: the in-use one follows the
     * service, everything else is stopped. Only the parts that change are
     * touched, so the list is not rebuilt for every connection.
     */
    private void refreshCards() {
        ProxyState state = ProxyRuntime.state();
        String inUse = ConfigStore.inUse(this);
        for (int index = 0; index < profileList.getChildCount(); index++) {
            View card = profileList.getChildAt(index);
            Object tag = card.getTag();
            String name = tag == null ? null : tag.toString();
            boolean mine = name != null && name.equals(inUse);
            int label;
            int color;
            if (mine && state.listening) {
                label = R.string.state_running;
                color = R.color.running;
            } else if (mine && state.running) {
                label = R.string.state_waiting;
                color = R.color.waiting;
            } else {
                label = R.string.state_stopped;
                color = R.color.traffic_base;
            }
            TextView badge = card.findViewById(R.id.card_state);
            badge.setText(label);
            badge.setTextColor(getColor(color));
            card.findViewById(R.id.card_dot).setBackgroundTintList(
                    ColorStateList.valueOf(getColor(color)));
            ProxyConfig config = name == null ? null : ConfigStore.profile(this, name);
            if (config != null) {
                ((TextView) card.findViewById(R.id.card_summary)).setText(mine && state.running
                        ? getString(R.string.card_in_use, config.summary())
                        : config.summary());
            }
            Button startStop = card.findViewById(R.id.card_toggle);
            boolean running = mine && state.running;
            startStop.setText(running ? R.string.action_stop : R.string.action_start);
            startStop.setBackgroundTintList(ColorStateList.valueOf(
                    running ? getColor(R.color.traffic_base) : accent()));
            startStop.setTextColor(getColor(android.R.color.white));
        }
    }

    // -- one proxy ------------------------------------------------------

    private void openProfile(String name) {
        ProxyConfig config = ConfigStore.profile(this, name);
        if (config == null) {
            showHome();
            return;
        }
        editing = name;
        loadIntoFields(config, ConfigStore.profileAutoStart(this, name),
                ConfigStore.profileAdbWireless(this, name));
        headerTitle.setText(name);
        back.setVisibility(View.VISIBLE);
        homeScreen.setVisibility(View.GONE);
        profileScreen.setVisibility(View.VISIBLE);
        listenerPage.scrollTo(0, 0);
        servicePage.scrollTo(0, 0);
        renderBattery();
        renderAdbState();
        renderPending();
        renderLog();
        renderTraffic();
        renderToggle();
    }

    /** The whole proxy: the listener's settings and the two service switches. */
    private void loadIntoFields(ProxyConfig config, boolean autoStartOn, boolean adbOn) {
        loading = true;
        try {
            port.setText(Integer.toString(config.port));
            user.setText(config.user);
            password.setText(config.password);
            ssid.setText(config.ssid);
            anonymous.setChecked(config.anonymous);
            anyNetwork.setChecked(config.anyNetwork);
            autoStart.setChecked(autoStartOn);
            adbWireless.setChecked(adbOn);
        } finally {
            loading = false;
        }
    }

    /** Throw the edits away and show what the store holds again. */
    private void revertForm() {
        if (editing == null) {
            return;
        }
        ProxyConfig saved = ConfigStore.profile(this, editing);
        if (saved == null) {
            showHome();
            return;
        }
        loadIntoFields(saved, ConfigStore.profileAutoStart(this, editing),
                ConfigStore.profileAdbWireless(this, editing));
        renderBattery();
        renderPending();
    }

    private void saveForm() {
        if (editing == null) {
            return;
        }
        ProxyConfig config;
        try {
            config = readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        storeProfile(editing, config);
    }

    private void storeProfile(String name, ProxyConfig config) {
        ConfigStore.saveProfile(this, name, config, autoStart.isChecked(),
                adbWireless.isChecked());
        EventLog.addTo(name, "saved configuration \"" + name + "\"");
        ConfigStore.setSelectedProfile(this, name);
        renderHome();
        renderPending();
        Toast.makeText(this, getString(R.string.profile_saved, name), Toast.LENGTH_SHORT).show();
    }

    /**
     * A new proxy starts as a copy of the one in use — same credentials, same
     * network, next free port — which is what a second proxy on the same phone
     * almost always is. Everything after that is the form, so the wizard is the
     * opened proxy itself.
     */
    private void createProfile(String name) {
        if (ConfigStore.profile(this, name) != null) {
            Toast.makeText(this, getString(R.string.profile_exists, name),
                    Toast.LENGTH_LONG).show();
            return;
        }
        ProxyConfig base = ConfigStore.load(this);
        ProxyConfig seed = ProxyConfig.raw(nextFreePort(base.port), base.user, base.password,
                base.ssid, base.anyNetwork, base.anonymous);
        ConfigStore.saveProfile(this, name, seed, ConfigStore.autoStart(this),
                ConfigStore.adbWireless(this));
        EventLog.addTo(name, "created \"" + name + "\"");
        Toast.makeText(this, getString(R.string.new_created, name), Toast.LENGTH_LONG).show();
        renderHome();
        openProfile(name);
    }

    /** The first port from `wanted` up that no saved proxy is using. */
    private int nextFreePort(int wanted) {
        java.util.Set<Integer> taken = new java.util.HashSet<>();
        for (String name : ConfigStore.profileNames(this)) {
            ProxyConfig saved = ConfigStore.profile(this, name);
            if (saved != null) {
                taken.add(saved.port);
            }
        }
        int free = wanted;
        while (taken.contains(free) && free < 65535) {
            free++;
        }
        return free;
    }

    /** The name dialog: a new proxy, or the form under another name. */
    private void askProfileName(String suggested) {
        boolean copy = suggested != null;
        EditText name = new EditText(this);
        name.setHint(R.string.profile_name_hint);
        name.setText(suggested == null ? "" : suggested);
        name.setSelection(name.getText().length());
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(copy ? R.string.profile_save_title : R.string.new_title)
                .setView(name)
                .setPositiveButton(android.R.string.ok, (shown, which) -> {
                    String given = name.getText().toString().trim();
                    if (given.isEmpty()) {
                        Toast.makeText(this, R.string.profile_name_required,
                                Toast.LENGTH_LONG).show();
                        return;
                    }
                    if (copy) {
                        saveAs(given);
                    } else {
                        createProfile(given);
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .create();
        dialog.show();
        // A name is the only thing this dialog is for, so give it the keyboard
        // instead of making the user tap the field first.
        name.requestFocus();
        dialog.getWindow().setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
    }

    private void saveAs(String name) {
        ProxyConfig config;
        try {
            config = readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        // Saving over the opened proxy is the expected "save again", anything
        // else that already exists is a decision.
        if (ConfigStore.profile(this, name) != null && !name.equals(editing)) {
            new AlertDialog.Builder(this)
                    .setTitle(getString(R.string.profile_overwrite_title, name))
                    .setMessage(R.string.profile_overwrite_message)
                    .setPositiveButton(android.R.string.ok,
                            (dialog, which) -> {
                                storeProfile(name, config);
                                openProfile(name);
                            })
                    .setNegativeButton(android.R.string.cancel, null)
                    .show();
            return;
        }
        storeProfile(name, config);
        openProfile(name);
    }

    /** Another name for the same proxy; its settings and its state move with it. */
    private void askRename() {
        if (editing == null) {
            return;
        }
        final String from = editing;
        EditText name = new EditText(this);
        name.setText(from);
        name.setSelection(from.length());
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(getString(R.string.rename_title, from))
                .setView(name)
                .setPositiveButton(android.R.string.ok, (shown, which) ->
                        renameTo(from, name.getText().toString().trim()))
                .setNegativeButton(android.R.string.cancel, null)
                .create();
        dialog.show();
        name.requestFocus();
        dialog.getWindow().setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
    }

    private void renameTo(String from, String to) {
        if (to.isEmpty()) {
            Toast.makeText(this, R.string.profile_name_required, Toast.LENGTH_LONG).show();
            return;
        }
        if (to.equals(from)) {
            return;
        }
        if (!ConfigStore.renameProfile(this, from, to)) {
            Toast.makeText(this, getString(R.string.profile_exists, to),
                    Toast.LENGTH_LONG).show();
            return;
        }
        EventLog.addTo(to, "renamed \"" + from + "\" to \"" + to + "\"");
        // The running proxy, if this was the one, keeps logging under the new
        // name instead of one that no longer exists.
        if (ProxyRuntime.state().running && to.equals(ConfigStore.inUse(this))) {
            EventLog.setActiveTag(to);
        }
        Toast.makeText(this, getString(R.string.profile_renamed, from, to),
                Toast.LENGTH_SHORT).show();
        renderHome();
        openProfile(to);
    }

    private void confirmDeleteProfile() {
        if (editing == null) {
            return;
        }
        String name = editing;
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.profile_delete_title, name))
                .setMessage(R.string.profile_delete_message)
                .setPositiveButton(android.R.string.ok, (dialog, which) -> {
                    ConfigStore.deleteProfile(this, name);
                    EventLog.addTo(name, "deleted \"" + name + "\"");
                    ConfigStore.setSelectedProfile(this, null);
                    if (name.equals(ConfigStore.inUse(this))) {
                        ConfigStore.setInUse(this, null);
                    }
                    showHome();
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    // -- the header -----------------------------------------------------

    /** The menu: the proxy actions, the app's own two views, and its Info. */
    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        Menu items = menu.getMenu();
        boolean open = editing != null;
        items.add(0, 1, 0, R.string.action_new);
        items.add(0, 2, 1, R.string.action_save).setEnabled(open);
        items.add(0, 3, 2, R.string.action_save_as).setEnabled(open);
        items.add(0, 4, 3, R.string.action_rename).setEnabled(open);
        items.add(0, 5, 4, R.string.action_delete).setEnabled(open);
        items.add(0, 6, 5, R.string.menu_all_events);
        items.add(0, 7, 6, R.string.menu_info);
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    askProfileName(null);
                    return true;
                case 2:
                    saveForm();
                    return true;
                case 3:
                    askProfileName(editing);
                    return true;
                case 4:
                    askRename();
                    return true;
                case 5:
                    confirmDeleteProfile();
                    return true;
                case 6:
                    showAllEvents();
                    return true;
                case 7:
                    showHelp();
                    return true;
                default:
                    return false;
            }
        });
        menu.show();
    }

    /** Everything, not just this proxy's events, in one scrollable dialog. */
    private void showAllEvents() {
        List<String> entries = EventLog.newestFirst();
        TextView text = new TextView(this);
        text.setPadding(48, 24, 48, 24);
        text.setTextSize(12);
        text.setTypeface(Typeface.MONOSPACE);
        text.setText(entries.isEmpty()
                ? getString(R.string.all_events_empty)
                : String.join("\n", entries));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(text);
        new AlertDialog.Builder(this)
                .setTitle(R.string.all_events_title)
                .setView(scroll)
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    /** What the app is, in the words the service's dumpsys help uses. */
    private void showHelp() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.info_title)
                .setMessage(Help.text())
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    // -- state ----------------------------------------------------------

    /** The accent of the theme, for the button that does something. */
    private int accent() {
        TypedValue value = new TypedValue();
        getTheme().resolveAttribute(android.R.attr.colorAccent, value, true);
        return value.data;
    }

    /** Whether this proxy is the one the service is running right now. */
    private boolean isRunning(String name) {
        ProxyState state = ProxyRuntime.state();
        return state.running && name != null && name.equals(ConfigStore.inUse(this));
    }

    /** The one button under an open proxy: Start, or Stop when it is running. */
    private void renderToggle() {
        ProxyState state = ProxyRuntime.state();
        boolean running = isRunning(editing);
        toggle.setText(running ? R.string.action_stop : R.string.action_start);
        toggle.setBackgroundTintList(ColorStateList.valueOf(
                running ? getColor(R.color.traffic_base) : accent()));
        toggle.setTextColor(getColor(android.R.color.white));
        if (editing == null) {
            return;
        }
        if (!state.running) {
            footerState.setText(R.string.footer_stopped);
        } else if (!editing.equals(ConfigStore.inUse(this))) {
            footerState.setText(R.string.footer_not_this);
        } else {
            footerState.setText(state.describe());
        }
        renderBattery();
    }

    /** The totals line above the sparkline; the graph reads Traffic itself. */
    private void renderTraffic() {
        long[] totals = Traffic.totals();
        long[] rates = Traffic.history()[0].length == 0
                ? new long[] {0, 0}
                : lastSample();
        // A graph with no line in it is a hole in the page; the sentence says
        // the same thing in less room.
        boolean idle = totals[0] == 0 && totals[1] == 0;
        trafficGraph.setVisibility(idle ? View.GONE : View.VISIBLE);
        if (idle) {
            traffic.setText(R.string.traffic_none);
        } else {
            traffic.setText(getString(R.string.traffic_totals,
                    Traffic.human(totals[1]), Traffic.human(totals[0]),
                    Traffic.human(rates[1]), Traffic.human(rates[0])));
        }
        trafficGraph.invalidate();
    }

    /** The newest interval's {up, down} rates. */
    private long[] lastSample() {
        long[][] history = Traffic.history();
        long[] rates = history[0];
        return new long[] {rates[rates.length - 1], history[1][history[1].length - 1]};
    }

    /** This proxy's events, newest first; EventLog is small and in memory. */
    private void renderLog() {
        List<String> entries = EventLog.forProfile(editing);
        logText.setText(entries.isEmpty()
                ? getString(R.string.log_empty)
                : String.join("\n", entries));
    }

    private final Runnable logListener = () -> runOnUiThread(() -> {
        if (editing != null) {
            renderLog();
        }
    });

    private final Handler handler = new Handler(Looper.getMainLooper());

    /**
     * One sample per second while the panel is in front: the counters are
     * integers, and the graph's resolution is exactly this interval.
     */
    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            Traffic.sample();
            if (editing != null) {
                renderTraffic();
            }
            handler.postDelayed(this, 1000);
        }
    };

    /** The panel is already up and adb asked for the help again. */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (intent.getBooleanExtra(Help.EXTRA_HELP, false)) {
            showHelp();
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        ProxyRuntime.addListener(this);
        EventLog.addListener(logListener);
        handler.post(ticker);
        ConfigStore.shared(this).registerOnSharedPreferenceChangeListener(preferences);
        getContentResolver().registerContentObserver(
                Settings.Global.getUriFor(AdbWireless.SETTING), false, adbSetting);
        render(ProxyRuntime.state());
        renderAdbState();
    }

    @Override
    protected void onResume() {
        super.onResume();
        // The exemption is granted in the system's own screen, so the answer
        // arrives with the next resume rather than with a result code.
        renderBattery();
        renderAdbState();
    }

    @Override
    protected void onStop() {
        ProxyRuntime.removeListener(this);
        EventLog.removeListener(logListener);
        handler.removeCallbacks(ticker);
        ConfigStore.shared(this).unregisterOnSharedPreferenceChangeListener(preferences);
        getContentResolver().unregisterContentObserver(adbSetting);
        super.onStop();
    }

    /** May arrive on a connection thread; the render hop is deliberate. */
    @Override
    public void onStateChanged(ProxyState state) {
        runOnUiThread(() -> render(state));
    }

    private void render(ProxyState state) {
        refreshCards();
        renderToggle();
    }

    // -- Android's promises ----------------------------------------------

    /**
     * A restart at boot is a background start, which Android only allows with
     * an exemption; the one a user can grant here is "no battery optimization".
     */
    private boolean batteryExempt() {
        PowerManager power = getSystemService(PowerManager.class);
        return power != null && power.isIgnoringBatteryOptimizations(getPackageName());
    }

    /** Whether the proxy being looked at promises a restart after a reboot. */
    private boolean autoStartWanted() {
        if (editing != null) {
            return autoStart.isChecked();
        }
        String inUse = ConfigStore.inUse(this);
        return inUse == null
                ? ConfigStore.autoStart(this)
                : ConfigStore.profileAutoStart(this, inUse);
    }

    /**
     * What Android's wireless debugging is doing right now — not what the
     * switch promises — and why the app cannot help when the permission that
     * lets it write that setting was never granted.
     */
    private void renderAdbState() {
        if (!AdbWireless.granted(this)) {
            adbState.setText(R.string.adb_wifi_ungranted);
            return;
        }
        if (AdbWireless.on(this)) {
            adbState.setText(R.string.adb_wifi_state_on);
            return;
        }
        adbState.setText(ConfigStore.adbWireless(this)
                ? R.string.adb_wifi_state_off
                : R.string.adb_wifi_state_off_manual);
    }

    private void renderBattery() {
        boolean exempt = batteryExempt();
        battery.setText(getString(exempt ? R.string.battery_exempt : R.string.battery_optimized));
        // Only a promise the app cannot keep is worth a colour: with auto-start
        // off, the line is a fact about the phone rather than a warning about
        // what this app will not do after a reboot.
        boolean warningNow = !exempt && autoStartWanted();
        battery.setTextColor(warningNow ? getColor(R.color.warning) : batteryColor);
        battery.setTypeface(null, warningNow ? Typeface.BOLD : Typeface.NORMAL);
        this.warning.setVisibility(warningNow ? View.VISIBLE : View.GONE);
        battery.setClickable(!exempt);
        battery.setOnClickListener(exempt ? null : view -> askForExemption());
    }

    private void askForExemption() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.battery_title)
                .setMessage(R.string.battery_message)
                .setPositiveButton(R.string.battery_open,
                        (dialog, which) -> openBatterySettings())
                .setNegativeButton(R.string.battery_later, null)
                .show();
    }

    private void openBatterySettings() {
        Intent request = new Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:" + getPackageName()));
        try {
            startActivity(request);
        } catch (ActivityNotFoundException e) {
            // Some builds only offer the list of all apps.
            startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
        }
    }

    // -- form ------------------------------------------------------------

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

    private void renderPending() {
        boolean changed = pendingChanges();
        pending.setVisibility(changed ? View.VISIBLE : View.GONE);
        pendingService.setVisibility(changed ? View.VISIBLE : View.GONE);
    }

    /** Whether the fields say something other than the saved proxy does. */
    private boolean pendingChanges() {
        ProxyConfig stored = editing == null ? null : ConfigStore.profile(this, editing);
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
                || autoStart.isChecked() != ConfigStore.profileAutoStart(this, editing)
                || adbWireless.isChecked() != ConfigStore.profileAdbWireless(this, editing);
    }

    private ProxyConfig readFields() {
        return ProxyConfig.of(
                readPort(),
                user.getText().toString(),
                password.getText().toString(),
                ssid.getText().toString(),
                anyNetwork.isChecked(),
                anonymous.isChecked());
    }

    /**
     * Start this proxy from its card, with the settings it already has — the
     * form of another proxy on screen is not involved.
     */
    private void toggleFromCard(String name) {
        if (isRunning(name)) {
            stopListening();
            return;
        }
        if (ConfigStore.profile(this, name) == null) {
            return;
        }
        ConfigStore.setInUse(this, name);
        startForegroundService(new Intent(this, ProxyService.class)
                .setAction(ProxyService.ACTION_START)
                .putExtra(ConfigStore.EXTRA_PROFILE, name));
    }

    /** The button under an open proxy: stop it, or store the form and start it. */
    private void toggleOpenProxy() {
        if (editing == null) {
            return;
        }
        if (isRunning(editing)) {
            stopListening();
            return;
        }
        ProxyConfig config;
        try {
            config = readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        ConfigStore.saveProfile(this, editing, config, autoStart.isChecked(),
                adbWireless.isChecked());
        ConfigStore.save(this, config);
        ConfigStore.setAutoStart(this, autoStart.isChecked());
        ConfigStore.setAdbWireless(this, adbWireless.isChecked());
        ConfigStore.setInUse(this, editing);
        renderHome();
        renderPending();
        if (autoStartWanted() && !batteryExempt()) {
            askForExemption();
        }
        startForegroundService(new Intent(this, ProxyService.class)
                .setAction(ProxyService.ACTION_START)
                .putExtra(ConfigStore.EXTRA_PROFILE, editing));
    }

    private void stopListening() {
        startService(new Intent(this, ProxyService.class).setAction(ProxyService.ACTION_STOP));
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
