package org.phonelink.proxy;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
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
    private TextView status;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        port = findViewById(R.id.port);
        user = findViewById(R.id.user);
        password = findViewById(R.id.password);
        ssid = findViewById(R.id.ssid);
        anyNetwork = findViewById(R.id.any_network);
        status = findViewById(R.id.status);

        ProxyConfig stored = ConfigStore.load(this);
        port.setText(Integer.toString(stored.port));
        user.setText(stored.user);
        password.setText(stored.password);
        ssid.setText(stored.ssid);
        anyNetwork.setChecked(stored.anyNetwork);

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
        render(ProxyRuntime.state());
    }

    @Override
    protected void onStop() {
        ProxyRuntime.removeListener(this);
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
