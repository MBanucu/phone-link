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
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Menu;
import android.view.View;
import android.view.WindowManager;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.PopupMenu;
import android.widget.RadioGroup;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * The panel: the same settings and the same two actions as the adb contract.
 *
 * <p>The activity and the service run in one process, so the live state comes
 * from {@link ProxyRuntime} rather than a binder. Starting the service from a
 * visible activity is allowed, including the location foreground type the SSID
 * match needs.
 */
public final class MainActivity extends Activity implements ProxyRuntime.Listener {

    /** Which page the menu had selected, so a rotation does not send it home. */
    private static final String STATE_TAB = "tab";

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
    private TextView status;
    private TextView active;
    private Spinner picker;
    private TextView profileSummary;
    private Button loadButton;
    private Button deleteButton;
    private RadioGroup tabs;
    private View listenerPage;
    private View savedPage;
    private View servicePage;
    private View logPage;
    private TextView logText;
    private TextView profileLabel;
    private View warning;
    private Button saveListener;
    private Button saveService;
    private ArrayAdapter<String> profileNames;
    private String selectedProfile;
    /** Set while a configuration is put into the form, so nothing is stored. */
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
                    // A configuration saved over adb is a new name in the picker.
                    refreshProfiles();
                } else {
                    // A configuration the service just stored: show it as in use
                    // without touching the form, which may be mid-edit.
                    renderActive();
                    renderPending();
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
        status = findViewById(R.id.status);
        active = findViewById(R.id.active);
        picker = findViewById(R.id.profiles);
        profileSummary = findViewById(R.id.profile_summary);
        loadButton = findViewById(R.id.load_profile);
        deleteButton = findViewById(R.id.delete_profile);
        tabs = findViewById(R.id.tabs);
        listenerPage = findViewById(R.id.page_listener);
        savedPage = findViewById(R.id.page_saved);
        servicePage = findViewById(R.id.page_service);
        logPage = findViewById(R.id.page_log);
        logText = findViewById(R.id.log_text);
        profileLabel = findViewById(R.id.profile_label);
        warning = findViewById(R.id.warning);
        tabs.setOnCheckedChangeListener((group, checked) -> showPage(checked));
        // The mark in the header is the same warning as the line on the Service
        // page, visible from every page and one tap from the fix.
        warning.setOnClickListener(view -> askForExemption());
        findViewById(R.id.menu).setOnClickListener(this::showMenu);
        saveListener = findViewById(R.id.save_listener);
        saveListener.setOnClickListener(view -> saveToSelected());
        saveService = findViewById(R.id.save_service);
        saveService.setOnClickListener(view -> saveToSelected());
        findViewById(R.id.log_clear).setOnClickListener(view -> EventLog.clear());

        profileNames = new ArrayAdapter<>(this, android.R.layout.simple_spinner_item);
        profileNames.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        picker.setAdapter(profileNames);
        picker.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(
                    AdapterView<?> parent, View view, int position, long id) {
                Object item = parent.getItemAtPosition(position);
                selectedProfile = item == null ? null : item.toString();
                ConfigStore.setSelectedProfile(MainActivity.this, selectedProfile);
                renderProfileSummary();
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {
                selectedProfile = null;
                renderProfileSummary();
            }
        });
        findViewById(R.id.info).setOnClickListener(view -> showHelp());
        findViewById(R.id.reset).setOnClickListener(view -> resetToActive());
        loadButton.setOnClickListener(view -> loadSelectedProfile());
        findViewById(R.id.save_profile).setOnClickListener(view -> askProfileName());
        deleteButton.setOnClickListener(view -> confirmDeleteProfile());

        ProxyConfig stored = ConfigStore.load(this);
        port.setText(Integer.toString(stored.port));
        user.setText(stored.user);
        password.setText(stored.password);
        ssid.setText(stored.ssid);
        anonymous.setChecked(stored.anonymous);
        anyNetwork.setChecked(stored.anyNetwork);
        autoStart.setChecked(ConfigStore.autoStart(this));
        watchForEdits();
        // The battery line is only a warning while auto-start promises a
        // restart the app cannot deliver.
        autoStart.setOnCheckedChangeListener((button, checked) -> {
            renderBattery();
            renderPending();
        });
        adbWireless.setChecked(ConfigStore.adbWireless(this));
        // Unlike the fields above this is one preference, not part of a start:
        // it takes effect on the next SSID match either way, so saving it now
        // is what the checkbox appears to promise.
        adbWireless.setOnCheckedChangeListener((button, checked) -> {
            if (loading) {
                // A loaded configuration is a draft until Start, like the fields.
                return;
            }
            ConfigStore.setAdbWireless(this, checked);
            EventLog.add(checked
                    ? "wireless debugging managed by the app"
                    : "wireless debugging left alone");
            renderPending();
            if (checked && !AdbWireless.granted(this)) {
                Toast.makeText(this, R.string.adb_wifi_ungranted, Toast.LENGTH_LONG).show();
            }
        });

        Button start = findViewById(R.id.start);
        start.setOnClickListener(view -> startListening());
        Button stop = findViewById(R.id.stop);
        stop.setOnClickListener(view -> stopListening());

        render(ProxyRuntime.state());
        renderPending();
        refreshProfiles();
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
        outState.putInt(STATE_TAB, tabs.getCheckedRadioButtonId());
    }

    /** The menu: exactly one page is up, so nothing has to be scrolled past. */
    private void showPage(int checked) {
        boolean saved = checked == R.id.tab_saved;
        boolean service = checked == R.id.tab_service;
        boolean log = checked == R.id.tab_log;
        listenerPage.setVisibility(saved || service || log ? View.GONE : View.VISIBLE);
        savedPage.setVisibility(saved ? View.VISIBLE : View.GONE);
        servicePage.setVisibility(service ? View.VISIBLE : View.GONE);
        logPage.setVisibility(log ? View.VISIBLE : View.GONE);
        if (log) {
            renderLog();
        }
    }

    /** The menu in the header: the profile actions that used to need a page. */
    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        Menu items = menu.getMenu();
        items.add(0, 1, 0, R.string.action_save).setEnabled(selectedProfile != null);
        items.add(0, 2, 1, R.string.action_save_as);
        items.add(0, 3, 2, R.string.menu_delete).setEnabled(selectedProfile != null);
        items.add(0, 4, 3, R.string.tab_saved);
        items.add(0, 5, 4, R.string.tab_log);
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    saveToSelected();
                    return true;
                case 2:
                    askProfileName();
                    return true;
                case 3:
                    confirmDeleteProfile();
                    return true;
                case 4:
                    tabs.check(R.id.tab_saved);
                    return true;
                case 5:
                    tabs.check(R.id.tab_log);
                    return true;
                default:
                    return false;
            }
        });
        menu.show();
    }

    /** Newest first; EventLog is small and lives only in memory. */
    private void renderLog() {
        List<String> entries = EventLog.newestFirst();
        logText.setText(entries.isEmpty()
                ? getString(R.string.log_empty)
                : String.join("\n", entries));
    }

    /** The panel's Log page follows what the service and the panel write. */
    private final Runnable logListener = () -> runOnUiThread(this::renderLog);

    /** The panel is already up and adb asked for the help again. */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (intent.getBooleanExtra(Help.EXTRA_HELP, false)) {
            showHelp();
        }
    }

    /** What the app is, in the words the service's dumpsys help uses. */
    private void showHelp() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.info_title)
                .setMessage(Help.text())
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    @Override
    protected void onStart() {
        super.onStart();
        ProxyRuntime.addListener(this);
        EventLog.addListener(logListener);
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
        renderPending();
    }

    @Override
    protected void onStop() {
        ProxyRuntime.removeListener(this);
        EventLog.removeListener(logListener);
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
        status.setText(state.describe());
        // "In use" is not only about the port: a run stops being the one that
        // matters the moment the service goes away.
        renderActive();
    }

    /**
     * A restart at boot is a background start, which Android only allows with
     * an exemption; the one a user can grant here is "no battery optimization".
     */
    private boolean batteryExempt() {
        PowerManager power = getSystemService(PowerManager.class);
        return power != null && power.isIgnoringBatteryOptimizations(getPackageName());
    }

    /** The configuration the service is or was running with, as one line. */
    private void renderActive() {
        boolean running = ProxyRuntime.state().running;
        active.setText(getString(
                running ? R.string.active_running : R.string.active_stopped,
                ConfigStore.load(this).summary()));
    }

    /** Put the configuration in use back into the form, dropping any edits. */
    private void resetToActive() {
        loadIntoFields(ConfigStore.load(this), ConfigStore.autoStart(this),
                ConfigStore.adbWireless(this));
        renderPending();
    }

    /** The whole panel: the listener's settings and the two service switches. */
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

    /** A saved configuration into the form; nothing is started or stored. */
    private void loadSelectedProfile() {
        ProxyConfig saved = selectedProfile == null
                ? null
                : ConfigStore.profile(this, selectedProfile);
        if (saved == null) {
            return;
        }
        loadIntoFields(saved, ConfigStore.profileAutoStart(this, selectedProfile),
                ConfigStore.profileAdbWireless(this, selectedProfile));
        EventLog.add("loaded \"" + selectedProfile + "\" into the form");
        renderPending();
    }

    /** Rebuild the picker from the store and keep the remembered selection. */
    private void refreshProfiles() {
        List<String> names = ConfigStore.profileNames(this);
        profileNames.clear();
        profileNames.addAll(names);
        profileNames.notifyDataSetChanged();

        boolean empty = names.isEmpty();
        // An empty Spinner is a bare dropdown arrow; the line below it already
        // says there is nothing saved.
        picker.setVisibility(empty ? View.GONE : View.VISIBLE);
        picker.setEnabled(!empty);
        loadButton.setEnabled(!empty);
        deleteButton.setEnabled(!empty);

        String remembered = ConfigStore.selectedProfile(this);
        int index = remembered == null ? -1 : names.indexOf(remembered);
        if (index < 0 && !empty) {
            index = Math.max(picker.getSelectedItemPosition(), 0);
        }
        if (index >= 0 && index < names.size()) {
            selectedProfile = names.get(index);
            picker.setSelection(index);
        } else {
            selectedProfile = null;
        }
        renderProfileSummary();
    }

    private void renderProfileSummary() {
        ProxyConfig saved = selectedProfile == null
                ? null
                : ConfigStore.profile(this, selectedProfile);
        profileSummary.setText(saved == null
                ? getString(R.string.profiles_none)
                : getString(R.string.profile_holds, saved.summary()
                        + serviceSummary(selectedProfile)));
        // The name the form is working on, visible from every page, and the
        // two Save buttons that write to it.
        profileLabel.setText(selectedProfile == null
                ? getString(R.string.profile_none)
                : getString(R.string.profile_current, selectedProfile));
        saveListener.setEnabled(selectedProfile != null);
        saveService.setEnabled(selectedProfile != null);
    }

    private void askProfileName() {
        EditText name = new EditText(this);
        name.setHint(R.string.profile_name_hint);
        name.setText(selectedProfile == null ? "" : selectedProfile);
        name.setSelection(name.getText().length());
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(R.string.profile_save_title)
                .setView(name)
                .setPositiveButton(android.R.string.ok,
                        (shown, which) -> saveAs(name.getText().toString().trim()))
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
        if (name.isEmpty()) {
            Toast.makeText(this, R.string.profile_name_required, Toast.LENGTH_LONG).show();
            return;
        }
        ProxyConfig config;
        try {
            config = readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        // Saving over the selected configuration is the expected "save again",
        // anything else that already exists is a decision.
        if (ConfigStore.profile(this, name) != null && !name.equals(selectedProfile)) {
            new AlertDialog.Builder(this)
                    .setTitle(getString(R.string.profile_overwrite_title, name))
                    .setMessage(R.string.profile_overwrite_message)
                    .setPositiveButton(android.R.string.ok,
                            (dialog, which) -> storeProfile(name, config))
                    .setNegativeButton(android.R.string.cancel, null)
                    .show();
            return;
        }
        storeProfile(name, config);
    }

    /** The two service switches of a saved configuration, for the summary. */
    private String serviceSummary(String name) {
        return " · auto-start " + (ConfigStore.profileAutoStart(this, name) ? "on" : "off")
                + " · wireless debugging "
                + (ConfigStore.profileAdbWireless(this, name) ? "on" : "off");
    }

    /** The header's and the pages' plain Save: write the form to its name. */
    private void saveToSelected() {
        if (selectedProfile == null) {
            Toast.makeText(this, R.string.profile_none_selected, Toast.LENGTH_LONG).show();
            return;
        }
        ProxyConfig config;
        try {
            config = readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        storeProfile(selectedProfile, config);
    }

    private void storeProfile(String name, ProxyConfig config) {
        ConfigStore.saveProfile(this, name, config, autoStart.isChecked(),
                adbWireless.isChecked());
        EventLog.add("saved configuration \"" + name + "\"");
        ConfigStore.setSelectedProfile(this, name);
        refreshProfiles();
        Toast.makeText(this, getString(R.string.profile_saved, name), Toast.LENGTH_SHORT).show();
    }

    private void confirmDeleteProfile() {
        if (selectedProfile == null) {
            return;
        }
        String name = selectedProfile;
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.profile_delete_title, name))
                .setMessage(R.string.profile_delete_message)
                .setPositiveButton(android.R.string.ok, (dialog, which) -> {
                    ConfigStore.deleteProfile(this, name);
                    EventLog.add("deleted \"" + name + "\"");
                    ConfigStore.setSelectedProfile(this, null);
                    selectedProfile = null;
                    refreshProfiles();
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    /**
     * The fields do nothing until Start, which is not obvious from a form that
     * looks applied, so edits get a line of their own.
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
        pending.setVisibility(pendingChanges() ? View.VISIBLE : View.GONE);
    }

    /** Whether the fields say something other than what the service would use. */
    private boolean pendingChanges() {
        ProxyConfig stored = ConfigStore.load(this);
        boolean anonymousNow = anonymous.isChecked();
        // An anonymous start stores no credentials at all, so the fields have
        // to be compared the way ProxyConfig.of() would keep them; otherwise
        // Start with "listen without authentication" would look unsaved
        // forever.
        String userNow = anonymousNow ? "" : user.getText().toString();
        String passwordNow = anonymousNow ? "" : password.getText().toString();
        return readPortOr(-1) != stored.port
                || !userNow.equals(stored.user)
                || !passwordNow.equals(stored.password)
                || !ssid.getText().toString().equals(stored.ssid)
                || anonymousNow != stored.anonymous
                || anyNetwork.isChecked() != stored.anyNetwork
                // The switches are part of a configuration too; a loaded one
                // is a draft until Start writes them.
                || autoStart.isChecked() != ConfigStore.autoStart(this)
                || adbWireless.isChecked() != ConfigStore.adbWireless(this);
    }

    /**
     * What Android's wireless debugging is doing right now — not what the
     * switch above promises — and why the app cannot help when the permission
     * that lets it write that setting was never granted.
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
        boolean warningNow = !exempt && autoStart.isChecked();
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

    private ProxyConfig readFields() {
        return ProxyConfig.of(
                readPort(),
                user.getText().toString(),
                password.getText().toString(),
                ssid.getText().toString(),
                anyNetwork.isChecked(),
                anonymous.isChecked());
    }

    private void startListening() {
        ProxyConfig config;
        try {
            config = readFields();
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        ConfigStore.save(this, config);
        ConfigStore.setAutoStart(this, autoStart.isChecked());
        ConfigStore.setAdbWireless(this, adbWireless.isChecked());
        EventLog.add("Start pressed: " + config.summary());
        renderActive();
        renderPending();
        if (autoStart.isChecked() && !batteryExempt()) {
            askForExemption();
        }
        startForegroundService(
                new Intent(this, ProxyService.class).setAction(ProxyService.ACTION_START));
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
