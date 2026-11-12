package org.phonelink.proxy;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

/**
 * Where {@link ProxyConfig} lives: private preferences for the activity, plus
 * the adb extras that override them for one start.
 *
 * <p>The extras keep their meaning when absent: a start that only changes the
 * port reuses the stored credentials, which is what the scripts rely on. They
 * are persisted afterwards, so a sticky restart or the boot receiver starts the
 * same listener again.
 */
final class ConfigStore {

    static final String EXTRA_PORT = "port";
    static final String EXTRA_USER = "user";
    static final String EXTRA_PASSWORD = "password";
    static final String EXTRA_ANONYMOUS = "anonymous";
    static final String EXTRA_SSID = "ssid";
    static final String EXTRA_ANY_NETWORK = "any_network";
    static final String EXTRA_AUTO_START = "auto_start";

    private static final String PREFS = "config";
    private static final String KEY_PORT = "port";
    private static final String KEY_USER = "user";
    private static final String KEY_PASSWORD = "password";
    private static final String KEY_ANONYMOUS = "anonymous";
    private static final String KEY_SSID = "ssid";
    private static final String KEY_ANY_NETWORK = "any_network";
    private static final String KEY_AUTO_START = "auto_start";

    private ConfigStore() {
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static boolean isConfigured(Context context) {
        return prefs(context).contains(KEY_PORT);
    }

    /**
     * Whether the service should come back by itself after a reboot, so the
     * SSID gate opens the port when the phone reaches the AP without anybody
     * touching the tile. Not part of {@link ProxyConfig}: it says what should
     * happen to the service, not what the listener is.
     */
    static boolean autoStart(Context context) {
        return prefs(context).getBoolean(KEY_AUTO_START, false);
    }

    static void setAutoStart(Context context, boolean enabled) {
        prefs(context).edit().putBoolean(KEY_AUTO_START, enabled).apply();
    }

    /** Stored values, unvalidated: the panel uses them to fill its fields. */
    static ProxyConfig load(Context context) {
        SharedPreferences prefs = prefs(context);
        return ProxyConfig.raw(
                prefs.getInt(KEY_PORT, ProxyConfig.DEFAULT_PORT),
                prefs.getString(KEY_USER, ""),
                prefs.getString(KEY_PASSWORD, ""),
                prefs.getString(KEY_SSID, ProxyConfig.DEFAULT_SSID),
                prefs.getBoolean(KEY_ANY_NETWORK, false),
                prefs.getBoolean(KEY_ANONYMOUS, false));
    }

    static void save(Context context, ProxyConfig config) {
        prefs(context)
                .edit()
                .putInt(KEY_PORT, config.port)
                .putString(KEY_USER, config.user)
                .putString(KEY_PASSWORD, config.password)
                .putBoolean(KEY_ANONYMOUS, config.anonymous)
                .putString(KEY_SSID, config.ssid)
                .putBoolean(KEY_ANY_NETWORK, config.anyNetwork)
                .apply();
    }

    /**
     * The configuration for this start: stored values with the intent's extras on
     * top, validated and persisted.
     */
    static ProxyConfig resolve(Context context, Intent intent) {
        ProxyConfig stored = load(context);
        int port = stored.port;
        String user = stored.user;
        String password = stored.password;
        String ssid = stored.ssid;
        boolean anyNetwork = stored.anyNetwork;
        boolean anonymous = stored.anonymous;

        if (intent != null && intent.hasExtra(EXTRA_AUTO_START)) {
            setAutoStart(context, intent.getBooleanExtra(EXTRA_AUTO_START, autoStart(context)));
        }

        if (intent != null) {
            if (intent.hasExtra(EXTRA_PORT)) {
                port = intent.getIntExtra(EXTRA_PORT, port);
            }
            if (intent.hasExtra(EXTRA_USER)) {
                user = value(intent.getStringExtra(EXTRA_USER));
            }
            if (intent.hasExtra(EXTRA_PASSWORD)) {
                password = value(intent.getStringExtra(EXTRA_PASSWORD));
            }
            if (intent.hasExtra(EXTRA_SSID)) {
                ssid = value(intent.getStringExtra(EXTRA_SSID));
            }
            if (intent.hasExtra(EXTRA_ANY_NETWORK)) {
                anyNetwork = intent.getBooleanExtra(EXTRA_ANY_NETWORK, anyNetwork);
            }
            if (intent.hasExtra(EXTRA_ANONYMOUS)) {
                anonymous = intent.getBooleanExtra(EXTRA_ANONYMOUS, anonymous);
            }
        }

        ProxyConfig config = ProxyConfig.of(port, user, password, ssid, anyNetwork, anonymous);
        save(context, config);
        return config;
    }

    private static String value(String given) {
        return given == null ? "" : given;
    }
}
