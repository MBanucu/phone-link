package org.phonelink.proxy;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.provider.Settings;
import android.util.Log;

/**
 * Turns Android's wireless debugging back on when the phone joins PhoneLink.
 *
 * <p>A reboot can clear {@code adb_wifi_enabled}, and the port adb needs only
 * exists while that setting is on; the way back is the Developer options
 * toggle, which asks for somebody to pick up the phone. The setting is a
 * secure setting, so an ordinary app cannot write it — but
 * {@code WRITE_SECURE_SETTINGS} is a development permission, which
 * {@code adb shell pm grant} hands out once, and Android's own wireless
 * debugging switch is exactly this write. With the grant in place,
 * {@link Uplink}'s "allowed" transition is the trigger: it fires at boot and
 * every time the phone joins the configured SSID.
 *
 * <p>Nothing is guessed: without the permission this is one log line and a
 * no-op, so an APK installed by other means keeps working and says why.
 */
final class AdbWireless {

    private static final String TAG = "phone-link-proxy";

    /** The switch behind Developer options → Wireless debugging. */
    private static final String SETTING = "adb_wifi_enabled";

    private AdbWireless() {
    }

    static boolean granted(Context context) {
        return context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS)
                == PackageManager.PERMISSION_GRANTED;
    }

    /** Whether wireless debugging is currently on. */
    static boolean on(Context context) {
        return Settings.Global.getInt(context.getContentResolver(), SETTING, 0) == 1;
    }

    /**
     * Enable wireless debugging if it is off.
     *
     * @return whether wireless debugging is on afterwards
     */
    static boolean enable(Context context) {
        if (!granted(context)) {
            Log.w(TAG, "wireless debugging is not managed by this app: grant "
                    + "WRITE_SECURE_SETTINGS to let it re-enable itself");
            return false;
        }
        if (on(context)) {
            return true;
        }
        try {
            Settings.Global.putInt(context.getContentResolver(), SETTING, 1);
        } catch (SecurityException | IllegalArgumentException e) {
            Log.w(TAG, "the system refused adb_wifi_enabled", e);
            return false;
        }
        Log.i(TAG, "wireless debugging enabled (it was off)");
        return true;
    }
}
