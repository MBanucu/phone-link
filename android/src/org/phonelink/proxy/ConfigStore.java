package org.phonelink.proxy;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

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
    static final String EXTRA_ADB_WIFI = "adb_wifi";
    /** The saved configuration to start with, see {@link #resolve}. */
    static final String EXTRA_PROFILE = "profile";
    /** The new name, for {@link #EXTRA_PROFILE}'s rename. */
    static final String EXTRA_TO = "to";

    private static final String PREFS = "config";
    private static final String KEY_PORT = "port";
    private static final String KEY_USER = "user";
    private static final String KEY_PASSWORD = "password";
    private static final String KEY_ANONYMOUS = "anonymous";
    private static final String KEY_SSID = "ssid";
    private static final String KEY_ANY_NETWORK = "any_network";
    // Package-private so the panel can follow a preference that adb changed
    // while it is open, through a shared-preferences listener.
    static final String KEY_AUTO_START = "auto_start";
    static final String KEY_ADB_WIFI = "adb_wifi";
    /** Whether this proxy is one the Quick Settings tile switches. */
    private static final String KEY_TILE = "tile";
    /** What a click on the tile starts, and what it stops, as {@link TileScope}. */
    private static final String KEY_TILE_START = "tile_start";
    private static final String KEY_TILE_STOP = "tile_stop";
    private static final String KEY_TILE_CYCLE = "tile_cycle";
    static final String KEY_SELECTED_PROFILE = "selected_profile";
    static final String KEY_IN_USE = "in_use";

    // Package-private for the same reason as KEY_AUTO_START: the panel shows a
    // configuration the moment adb saves one.
    static final String KEY_PROFILES = "profiles";
    private static final String PROFILE_PREFIX = "profile.";

    private ConfigStore() {
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /** The same store, for a listener the panel registers while it is visible. */
    static SharedPreferences shared(Context context) {
        return prefs(context);
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

    /**
     * Whether joining the configured SSID should also switch Android's wireless
     * debugging back on. Off by choice is a real choice — the setting is also
     * reachable from Developer options — so the panel owns it, and it is on by
     * default because the host has no other way in after a reboot.
     */
    static boolean adbWireless(Context context) {
        return prefs(context).getBoolean(KEY_ADB_WIFI, true);
    }

    static void setAdbWireless(Context context, boolean enabled) {
        prefs(context).edit().putBoolean(KEY_ADB_WIFI, enabled).apply();
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

    // -- saved configurations -------------------------------------------

    /**
     * Named configurations the panel can load into the form.
     *
     * <p>Kept in the same private preferences as the configuration in use, one
     * set of keys per name, so the store stays a list of names plus plain
     * fields rather than a serialised blob that would need its own escaping.
     * The password is stored like the active one: private preferences of an
     * app that is not backed up.
     *
     * <p>A configuration is the whole panel: the listener's settings and the two
     * service switches, so "that setup" means the same thing after a restart.
     */
    static List<String> profileNames(Context context) {
        Set<String> names = prefs(context).getStringSet(KEY_PROFILES, null);
        List<String> sorted = names == null ? new ArrayList<>() : new ArrayList<>(names);
        Collections.sort(sorted, String.CASE_INSENSITIVE_ORDER);
        return sorted;
    }

    /** The saved configuration called `name`, or null when there is none. */
    static ProxyConfig profile(Context context, String name) {
        if (name == null || !profileNames(context).contains(name)) {
            return null;
        }
        SharedPreferences prefs = prefs(context);
        return ProxyConfig.raw(
                prefs.getInt(profileKey(name, KEY_PORT), ProxyConfig.DEFAULT_PORT),
                prefs.getString(profileKey(name, KEY_USER), ""),
                prefs.getString(profileKey(name, KEY_PASSWORD), ""),
                prefs.getString(profileKey(name, KEY_SSID), ProxyConfig.DEFAULT_SSID),
                prefs.getBoolean(profileKey(name, KEY_ANY_NETWORK), false),
                prefs.getBoolean(profileKey(name, KEY_ANONYMOUS), false));
    }

    static void saveProfile(
            Context context,
            String name,
            ProxyConfig config,
            boolean autoStart,
            boolean adbWireless) {
        Set<String> names = new HashSet<>(profileNames(context));
        names.add(name);
        prefs(context)
                .edit()
                .putStringSet(KEY_PROFILES, names)
                .putInt(profileKey(name, KEY_PORT), config.port)
                .putString(profileKey(name, KEY_USER), config.user)
                .putString(profileKey(name, KEY_PASSWORD), config.password)
                .putBoolean(profileKey(name, KEY_ANONYMOUS), config.anonymous)
                .putString(profileKey(name, KEY_SSID), config.ssid)
                .putBoolean(profileKey(name, KEY_ANY_NETWORK), config.anyNetwork)
                .putBoolean(profileKey(name, KEY_AUTO_START), autoStart)
                .putBoolean(profileKey(name, KEY_ADB_WIFI), adbWireless)
                .apply();
    }

    /** Whether the saved configuration wants the service to survive a reboot. */
    static boolean profileAutoStart(Context context, String name) {
        return prefs(context).getBoolean(profileKey(name, KEY_AUTO_START), false);
    }

    /** Whether the saved configuration manages wireless debugging. */
    static boolean profileAdbWireless(Context context, String name) {
        return prefs(context).getBoolean(profileKey(name, KEY_ADB_WIFI), true);
    }

    /**
     * Whether this proxy belongs to the Quick Settings tile. Not part of
     * {@link #saveProfile}: it says nothing about the listener, and the panel
     * stores it the moment the switch moves instead of waiting for Save.
     */
    static boolean profileTile(Context context, String name) {
        return prefs(context).getBoolean(profileKey(name, KEY_TILE), false);
    }

    static void setProfileTile(Context context, String name, boolean on) {
        prefs(context).edit().putBoolean(profileKey(name, KEY_TILE), on).apply();
    }

    /** What a click on the tile starts while it is off. */
    static TileScope tileStart(Context context) {
        return TileScope.named(prefs(context).getString(KEY_TILE_START, null), TileScope.TILE);
    }

    static void setTileStart(Context context, TileScope scope) {
        prefs(context).edit().putString(KEY_TILE_START, scope.name()).apply();
    }

    /** What a click on the tile stops while it is on. */
    static TileScope tileStop(Context context) {
        return TileScope.named(prefs(context).getString(KEY_TILE_STOP, null), TileScope.TILE);
    }

    static void setTileStop(Context context, TileScope scope) {
        prefs(context).edit().putString(KEY_TILE_STOP, scope.name()).apply();
    }

    /**
     * The sets a click brings up between the start side and the stop side, in
     * the order it walks them; empty is the switch the tile always was.
     */
    static List<TileScope> tileCycle(Context context) {
        return TileCycle.parse(prefs(context).getString(KEY_TILE_CYCLE, null));
    }

    static void setTileCycle(Context context, List<TileScope> cycle) {
        prefs(context).edit().putString(KEY_TILE_CYCLE, TileCycle.format(cycle)).apply();
    }

    /** The proxies the tile starts and stops, by name; empty means none bound. */
    static List<String> tileProfiles(Context context) {
        List<String> bound = new ArrayList<>();
        for (String name : profileNames(context)) {
            if (profileTile(context, name)) {
                bound.add(name);
            }
        }
        return bound;
    }

    /**
     * Another name for the same configuration: settings, switches, the mark of
     * which proxy is in use and the remembered selection all move with it.
     *
     * @return false when there is nothing to rename or the new name is taken
     */
    static boolean renameProfile(Context context, String from, String to) {
        if (from == null || to == null || from.equals(to)) {
            return false;
        }
        ProxyConfig saved = profile(context, from);
        if (saved == null || profile(context, to) != null) {
            return false;
        }
        saveProfile(context, to, saved, profileAutoStart(context, from),
                profileAdbWireless(context, from));
        setProfileTile(context, to, profileTile(context, from));
        deleteProfile(context, from);
        if (from.equals(inUse(context))) {
            setInUse(context, to);
        }
        if (from.equals(selectedProfile(context))) {
            setSelectedProfile(context, to);
        }
        return true;
    }

    static void deleteProfile(Context context, String name) {
        Set<String> names = new HashSet<>(profileNames(context));
        if (!names.remove(name)) {
            return;
        }
        prefs(context)
                .edit()
                .putStringSet(KEY_PROFILES, names)
                .remove(profileKey(name, KEY_PORT))
                .remove(profileKey(name, KEY_USER))
                .remove(profileKey(name, KEY_PASSWORD))
                .remove(profileKey(name, KEY_ANONYMOUS))
                .remove(profileKey(name, KEY_SSID))
                .remove(profileKey(name, KEY_ANY_NETWORK))
                .remove(profileKey(name, KEY_AUTO_START))
                .remove(profileKey(name, KEY_ADB_WIFI))
                .remove(profileKey(name, KEY_TILE))
                .apply();
    }

    /** Which saved configuration the picker had selected, across restarts. */
    static String selectedProfile(Context context) {
        return prefs(context).getString(KEY_SELECTED_PROFILE, null);
    }

    static void setSelectedProfile(Context context, String name) {
        prefs(context).edit().putString(KEY_SELECTED_PROFILE, name).apply();
    }

    /**
     * The saved configuration the service is (or was last) running, so the list
     * can say which card is the live one. Not part of a configuration: it says
     * what is happening, not what should happen.
     */
    static String inUse(Context context) {
        return prefs(context).getString(KEY_IN_USE, null);
    }

    static void setInUse(Context context, String name) {
        prefs(context).edit().putString(KEY_IN_USE, name).apply();
    }

    /**
     * The saved configuration these settings came from, or null when a start
     * over adb used values no name holds. Lets a plain
     * {@code START --ei port 1081} still show up as "that proxy is running".
     */
    static String profileMatching(Context context, ProxyConfig config) {
        if (config == null) {
            return null;
        }
        for (String name : profileNames(context)) {
            ProxyConfig saved = profile(context, name);
            if (saved != null
                    && saved.port == config.port
                    && saved.user.equals(config.user)
                    && saved.password.equals(config.password)
                    && saved.ssid.equals(config.ssid)
                    && saved.anyNetwork == config.anyNetwork
                    && saved.anonymous == config.anonymous) {
                return name;
            }
        }
        return null;
    }

    private static String profileKey(String name, String field) {
        return PROFILE_PREFIX + name + "." + field;
    }

    /**
     * The configuration for this start: stored values with the intent's extras on
     * top, validated and persisted.
     */
    static ProxyConfig resolve(Context context, Intent intent) {
        // A saved configuration replaces the stored one before the extras are
        // applied, so `START --es profile hotel --es port 1081` means "that
        // configuration on another port" rather than a mix of the two.
        if (intent != null && intent.hasExtra(EXTRA_PROFILE)) {
            String name = value(intent.getStringExtra(EXTRA_PROFILE));
            ProxyConfig saved = profile(context, name);
            if (saved == null) {
                throw new IllegalArgumentException(
                        "no saved configuration called \"" + name + "\"");
            }
            save(context, saved);
            // The two service switches belong to a configuration as well; an
            // explicit --ez auto_start/--ez adb_wifi still overrides them below.
            setAutoStart(context, profileAutoStart(context, name));
            setAdbWireless(context, profileAdbWireless(context, name));
        }
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
        if (intent != null && intent.hasExtra(EXTRA_ADB_WIFI)) {
            setAdbWireless(
                    context, intent.getBooleanExtra(EXTRA_ADB_WIFI, adbWireless(context)));
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
