package org.phonelink.proxy;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

/**
 * The panel: the same settings and the same two actions as the adb contract.
 *
 * <p>The activity and the service run in one process, so the live state comes
 * from {@link ProxyRuntime} rather than a binder. Starting the service from a
 * visible activity is allowed, including the location foreground type the SSID
 * match needs.
 */
public final class MainActivity extends Activity implements ProxyRuntime.Listener {

    private EditText port;
    private EditText user;
    private EditText password;
    private EditText ssid;
    private CheckBox anyNetwork;
    private CheckBox autoStart;
    private CheckBox adbWireless;
    private TextView battery;
    private TextView status;

    /**
     * The two preferences behind the checkboxes can also be changed over adb
     * ({@code --ez auto_start …}, {@code --ez adb_wifi …}), so the panel follows
     * the store instead of trusting what it wrote itself.
     */
    private final SharedPreferences.OnSharedPreferenceChangeListener preferences =
            (sharedPreferences, key) -> runOnUiThread(() -> {
                if (ConfigStore.KEY_ADB_WIFI.equals(key)) {
                    adbWireless.setChecked(ConfigStore.adbWireless(this));
                } else if (ConfigStore.KEY_AUTO_START.equals(key)) {
                    autoStart.setChecked(ConfigStore.autoStart(this));
                }
            });

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        port = findViewById(R.id.port);
        user = findViewById(R.id.user);
        password = findViewById(R.id.password);
        ssid = findViewById(R.id.ssid);
        anyNetwork = findViewById(R.id.any_network);
        autoStart = findViewById(R.id.auto_start);
        adbWireless = findViewById(R.id.adb_wifi);
        battery = findViewById(R.id.battery);
        status = findViewById(R.id.status);

        ProxyConfig stored = ConfigStore.load(this);
        port.setText(Integer.toString(stored.port));
        user.setText(stored.user);
        password.setText(stored.password);
        ssid.setText(stored.ssid);
        anyNetwork.setChecked(stored.anyNetwork);
        autoStart.setChecked(ConfigStore.autoStart(this));
        adbWireless.setChecked(ConfigStore.adbWireless(this));
        // Unlike the fields above this is one preference, not part of a start:
        // it takes effect on the next SSID match either way, so saving it now
        // is what the checkbox appears to promise.
        adbWireless.setOnCheckedChangeListener((button, checked) -> {
            ConfigStore.setAdbWireless(this, checked);
            if (checked && !AdbWireless.granted(this)) {
                Toast.makeText(this, R.string.adb_wifi_ungranted, Toast.LENGTH_LONG).show();
            }
        });

        Button start = findViewById(R.id.start);
        start.setOnClickListener(view -> startListening());
        Button stop = findViewById(R.id.stop);
        stop.setOnClickListener(view -> stopListening());

        render(ProxyRuntime.state());
    }

    @Override
    protected void onStart() {
        super.onStart();
        ProxyRuntime.addListener(this);
        ConfigStore.shared(this).registerOnSharedPreferenceChangeListener(preferences);
        render(ProxyRuntime.state());
    }

    @Override
    protected void onResume() {
        super.onResume();
        // The exemption is granted in the system's own screen, so the answer
        // arrives with the next resume rather than with a result code.
        renderBattery();
    }

    @Override
    protected void onStop() {
        ProxyRuntime.removeListener(this);
        ConfigStore.shared(this).unregisterOnSharedPreferenceChangeListener(preferences);
        super.onStop();
    }

    /** May arrive on a connection thread; the render hop is deliberate. */
    @Override
    public void onStateChanged(ProxyState state) {
        runOnUiThread(() -> render(state));
    }

    private void render(ProxyState state) {
        status.setText(state.describe());
    }

    /**
     * A restart at boot is a background start, which Android only allows with
     * an exemption; the one a user can grant here is "no battery optimization".
     */
    private boolean batteryExempt() {
        PowerManager power = getSystemService(PowerManager.class);
        return power != null && power.isIgnoringBatteryOptimizations(getPackageName());
    }

    private void renderBattery() {
        boolean exempt = batteryExempt();
        battery.setText(getString(exempt ? R.string.battery_exempt : R.string.battery_optimized));
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

    private void startListening() {
        ProxyConfig config;
        try {
            config = ProxyConfig.of(
                    readPort(),
                    user.getText().toString(),
                    password.getText().toString(),
                    ssid.getText().toString(),
                    anyNetwork.isChecked(),
                    false);
        } catch (IllegalArgumentException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        ConfigStore.save(this, config);
        ConfigStore.setAutoStart(this, autoStart.isChecked());
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
}
