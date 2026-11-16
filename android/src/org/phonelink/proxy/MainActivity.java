package org.phonelink.proxy;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.ContentObserver;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.Menu;
import android.view.View;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.PopupMenu;
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
 * <p>The screens are asked for rather than built here: {@link HomeScreen} draws
 * the cards and {@link ProxyScreen} the open proxy's page, and this class keeps
 * what a press means — Start, Save, Rename, Delete, the dialogs — plus the
 * header both screens live under.
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
    /** The list page, cards and the button under them, as one thing to hide. */
    private View homeScreen;
    private View profileScreen;

    private HomeScreen home;
    private ProxyScreen page;

    /**
     * The two preferences behind the checkboxes can also be changed over adb
     * ({@code --ez auto_start …}, {@code --ez adb_wifi …}), so the panel follows
     * the store instead of trusting what it wrote itself.
     */
    private final SharedPreferences.OnSharedPreferenceChangeListener preferences =
            (sharedPreferences, key) -> runOnUiThread(() -> {
                if (ConfigStore.KEY_ADB_WIFI.equals(key)) {
                    page.syncSwitches();
                    page.renderAdbState();
                } else if (ConfigStore.KEY_AUTO_START.equals(key)) {
                    page.syncSwitches();
                } else if (ConfigStore.KEY_SELECTED_PROFILE.equals(key)) {
                    return;
                } else if (ConfigStore.KEY_PROFILES.equals(key)) {
                    // A proxy saved, started, renamed or deleted over adb is a card.
                    home.render();
                    if (page.isOpen() && ConfigStore.profile(this, page.name()) == null) {
                        showHome();
                    }
                } else {
                    home.refresh();
                }
            });

    /** Android's own switch can change under us — the service flips it too. */
    private final ContentObserver adbSetting = new ContentObserver(
            new Handler(Looper.getMainLooper())) {
        @Override
        public void onChange(boolean selfChange) {
            page.renderAdbState();
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

        page = new ProxyScreen(this, profileScreen, new ProxyScreen.Actions() {
            @Override
            public void toggle() {
                toggleOpenProxy();
            }

            @Override
            public void save() {
                saveForm();
            }

            @Override
            public void revert() {
                revertForm();
            }

            @Override
            public void autoStartChanged() {
                renderBattery();
            }

            @Override
            public void adbWirelessChanged(boolean on) {
                MainActivity.this.adbWirelessChanged(on);
            }

            @Override
            public void tileChanged(boolean on) {
                MainActivity.this.tileChanged(on);
            }

            @Override
            public void batteryHelp() {
                askForExemption();
            }
        });
        home = new HomeScreen(this, findViewById(R.id.profile_list),
                findViewById(R.id.home_empty), new HomeScreen.Actions() {
                    @Override
                    public void open(String name) {
                        openProfile(name);
                    }

                    @Override
                    public void toggle(String name) {
                        toggleFromCard(name);
                    }
                });

        // The warning mark is the same warning as the battery line, and one tap
        // from the fix.
        warning.setOnClickListener(view -> askForExemption());
        findViewById(R.id.info).setOnClickListener(view -> showHelp());
        findViewById(R.id.menu).setOnClickListener(this::showMenu);
        back.setOnClickListener(view -> showHome());
        findViewById(R.id.new_profile).setOnClickListener(view -> askProfileName(null));
        wireHelp();

        render();
        String open = savedInstanceState == null
                ? null
                : savedInstanceState.getString(STATE_PROFILE);
        if (open != null && ConfigStore.profile(this, open) != null) {
            openProfile(open);
        } else {
            showHome();
        }
        page.showPage(savedInstanceState == null
                ? R.id.tab_listener
                : savedInstanceState.getInt(STATE_TAB, R.id.tab_listener));
        // check() only reports a change, so a page restored by the framework
        // would otherwise stay hidden.
        page.showPage(page.checkedTab());
        if (getIntent().getBooleanExtra(Help.EXTRA_HELP, false)) {
            showHelp();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putString(STATE_PROFILE, page.name());
        outState.putInt(STATE_TAB, page.checkedTab());
    }

    /** One level up: from a proxy back to the list. */
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (page.isOpen()) {
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
        info(R.id.info_tile, R.string.info_tile_title, R.string.info_tile);
        info(R.id.info_save, R.string.info_save_title, R.string.info_save);
        info(R.id.info_save_service, R.string.info_save_title, R.string.info_save);
        info(R.id.info_revert, R.string.info_revert_title, R.string.info_revert);
        info(R.id.info_revert_service, R.string.info_revert_title, R.string.info_revert);
        info(R.id.info_toggle, R.string.info_toggle_title, R.string.info_toggle);
        info(R.id.info_new, R.string.info_new_title, R.string.info_new);
        info(R.id.info_log, R.string.info_log_title, R.string.info_log);
    }

    // -- the two screens -------------------------------------------------

    private void showHome() {
        page.close();
        headerTitle.setText(R.string.home_title);
        back.setVisibility(View.GONE);
        profileScreen.setVisibility(View.GONE);
        homeScreen.setVisibility(View.VISIBLE);
        home.render();
        renderBattery();
    }

    private void openProfile(String name) {
        if (ConfigStore.profile(this, name) == null) {
            showHome();
            return;
        }
        page.open(name);
        headerTitle.setText(name);
        back.setVisibility(View.VISIBLE);
        homeScreen.setVisibility(View.GONE);
        profileScreen.setVisibility(View.VISIBLE);
        renderBattery();
    }

    // -- one proxy ------------------------------------------------------

    /** Throw the edits away and show what the store holds again. */
    private void revertForm() {
        if (!page.isOpen()) {
            return;
        }
        page.revert();
        if (ConfigStore.profile(this, page.name()) == null) {
            showHome();
            return;
        }
        page.renderPending();
        renderBattery();
    }

    private void saveForm() {
        if (!page.isOpen()) {
            return;
        }
        ProxyConfig config;
        try {
            config = page.readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        storeProfile(page.name(), config);
    }

    private void storeProfile(String name, ProxyConfig config) {
        ConfigStore.saveProfile(this, name, config, page.autoStartChecked(),
                page.adbWirelessChecked());
        EventLog.addTo(name, "saved configuration \"" + name + "\"");
        ConfigStore.setSelectedProfile(this, name);
        home.render();
        page.renderPending();
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
        home.render();
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
            config = page.readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        // Saving over the opened proxy is the expected "save again", anything
        // else that already exists is a decision.
        if (ConfigStore.profile(this, name) != null && !name.equals(page.name())) {
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
        if (!page.isOpen()) {
            return;
        }
        final String from = page.name();
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
        // A listener that was running under the old name keeps its port but has
        // to be listed under the new one, or the panel would show a card that
        // is not the one listening. The service adopts the new name; the store
        // was renamed here, so it only moves the listener.
        if (isRunning(from)) {
            EventLog.setActiveTag(to);
            startService(new Intent(this, ProxyService.class)
                    .setAction(ProxyService.ACTION_RENAME_PROFILE)
                    .putExtra(ConfigStore.EXTRA_PROFILE, from)
                    .putExtra(ConfigStore.EXTRA_TO, to));
        }
        Toast.makeText(this, getString(R.string.profile_renamed, from, to),
                Toast.LENGTH_SHORT).show();
        home.render();
        openProfile(to);
    }

    private void confirmDeleteProfile() {
        if (!page.isOpen()) {
            return;
        }
        String name = page.name();
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.profile_delete_title, name))
                .setMessage(R.string.profile_delete_message)
                .setPositiveButton(android.R.string.ok, (dialog, which) -> {
                    boolean wasRunning = isRunning(name);
                    ConfigStore.deleteProfile(this, name);
                    EventLog.addTo(name, "deleted \"" + name + "\"");
                    ConfigStore.setSelectedProfile(this, null);
                    if (name.equals(ConfigStore.inUse(this))) {
                        ConfigStore.setInUse(this, null);
                    }
                    if (wasRunning) {
                        // A listener whose proxy is gone would keep a port open
                        // under a name the list no longer has.
                        startService(new Intent(this, ProxyService.class)
                                .setAction(ProxyService.ACTION_STOP)
                                .putExtra(ConfigStore.EXTRA_PROFILE, name));
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
        boolean open = page.isOpen();
        items.add(0, 1, 0, R.string.action_new);
        items.add(0, 2, 1, R.string.action_save).setEnabled(open);
        items.add(0, 3, 2, R.string.action_save_as).setEnabled(open);
        items.add(0, 4, 3, R.string.action_rename).setEnabled(open);
        items.add(0, 5, 4, R.string.action_delete).setEnabled(open);
        items.add(0, 6, 5, R.string.menu_all_events);
        items.add(0, 7, 6, R.string.menu_tile);
        items.add(0, 8, 7, R.string.menu_info);
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    askProfileName(null);
                    return true;
                case 2:
                    saveForm();
                    return true;
                case 3:
                    askProfileName(page.name());
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
                    // The tile's own page: what a click starts, what it stops,
                    // and which proxies are on it. Long-pressing the tile keeps
                    // Android's answer, App info, which is where a user looks
                    // for the app itself.
                    TileSettingsDialog.show(this, page::renderTileState);
                    return true;
                case 8:
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
                .setMessage(Help.text(getPackageName()))
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    // -- state ----------------------------------------------------------

    /** Whether this proxy has a listener of its own right now. */
    private boolean isRunning(String name) {
        return name != null && ProxyRuntime.forName(name) != null;
    }

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
        page.start();
        ConfigStore.shared(this).registerOnSharedPreferenceChangeListener(preferences);
        getContentResolver().registerContentObserver(
                Settings.Global.getUriFor(AdbWireless.SETTING), false, adbSetting);
        render();
        page.renderAdbState();
    }

    @Override
    protected void onResume() {
        super.onResume();
        // The exemption is granted in the system's own screen, so the answer
        // arrives with the next resume rather than with a result code.
        renderBattery();
        page.renderAdbState();
    }

    @Override
    protected void onStop() {
        ProxyRuntime.removeListener(this);
        page.stop();
        ConfigStore.shared(this).unregisterOnSharedPreferenceChangeListener(preferences);
        getContentResolver().unregisterContentObserver(adbSetting);
        super.onStop();
    }

    /** May arrive on a connection thread; the render hop is deliberate. */
    @Override
    public void onStatesChanged(List<ProxyState> states) {
        runOnUiThread(this::render);
    }

    private void render() {
        home.refresh();
        page.render();
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
        if (page.isOpen()) {
            return page.autoStartChecked();
        }
        String inUse = ConfigStore.inUse(this);
        return inUse == null
                ? ConfigStore.autoStart(this)
                : ConfigStore.profileAutoStart(this, inUse);
    }

    private void renderBattery() {
        boolean exempt = batteryExempt();
        // Only a promise the app cannot keep is worth a colour: with auto-start
        // off, the line is a fact about the phone rather than a warning about
        // what this app will not do after a reboot.
        boolean warningNow = !exempt && autoStartWanted();
        page.renderBattery(exempt, warningNow);
        warning.setVisibility(warningNow ? View.VISIBLE : View.GONE);
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

    /** A proxy's settings are a draft until Save or Start; this one is not. */
    private void adbWirelessChanged(boolean on) {
        ConfigStore.setAdbWireless(this, on);
        EventLog.add(on
                ? "wireless debugging managed by the app"
                : "wireless debugging left alone");
        if (on && !AdbWireless.granted(this)) {
            Toast.makeText(this, R.string.adb_wifi_ungranted, Toast.LENGTH_LONG).show();
        }
    }

    /**
     * Which proxies the tile switches is a preference about the tile, not part
     * of what a listener is, so it stores as it is ticked instead of waiting for
     * Save — and Save does not write it back.
     */
    private void tileChanged(boolean on) {
        String name = page.name();
        if (name == null) {
            return;
        }
        ConfigStore.setProfileTile(this, name, on);
        EventLog.addTo(name, on
                ? "bound to the Quick Settings tile"
                : "no longer bound to the tile");
        page.renderTileState();
    }

    // -- what a press means ----------------------------------------------

    /**
     * Start this proxy from its card, with the settings it already has — the
     * form of another proxy on screen is not involved.
     */
    private void toggleFromCard(String name) {
        if (isRunning(name)) {
            stopListening(name);
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
        if (!page.isOpen()) {
            return;
        }
        String name = page.name();
        if (isRunning(name)) {
            stopListening(name);
            return;
        }
        ProxyConfig config;
        try {
            config = page.readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        ConfigStore.saveProfile(this, name, config, page.autoStartChecked(),
                page.adbWirelessChecked());
        ConfigStore.save(this, config);
        ConfigStore.setAutoStart(this, page.autoStartChecked());
        ConfigStore.setAdbWireless(this, page.adbWirelessChecked());
        ConfigStore.setInUse(this, name);
        home.render();
        page.renderPending();
        if (autoStartWanted() && !batteryExempt()) {
            askForExemption();
        }
        startForegroundService(new Intent(this, ProxyService.class)
                .setAction(ProxyService.ACTION_START)
                .putExtra(ConfigStore.EXTRA_PROFILE, name));
    }

    /**
     * Stop one proxy's listener; the others keep listening and the service goes
     * away with the last one. A page and a card both mean that card's proxy, so
     * neither can stop a proxy the button is not about.
     */
    private void stopListening(String name) {
        startService(new Intent(this, ProxyService.class)
                .setAction(ProxyService.ACTION_STOP)
                .putExtra(ConfigStore.EXTRA_PROFILE, name));
    }
}
