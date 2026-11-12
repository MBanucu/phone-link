package org.phonelink.proxy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Brings the listener back after a reboot when the user asked for that.
 *
 * <p>Only with {@code auto_start}: a package that was installed but never used,
 * or used with the option off, does not open a port by itself. The port itself
 * stays shut until the phone is on the configured Wi-Fi, so a restart here
 * costs a notification and nothing else.
 */
public final class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        if (!ConfigStore.autoStart(context)) {
            return;
        }
        Intent start = new Intent(context, ProxyService.class).setAction(ProxyService.ACTION_START);
        try {
            context.startForegroundService(start);
        } catch (IllegalStateException e) {
            // Android 15 refuses some foreground starts after BOOT_COMPLETED.
            // A plain start rides the receiver's temporary allowlist instead;
            // the service promotes itself in onStartCommand, and stops itself
            // if that is refused too.
            Log.w(ProxyService.TAG, "no foreground start after boot, trying a plain start", e);
            try {
                context.startService(start);
            } catch (IllegalStateException again) {
                Log.w(ProxyService.TAG, "cannot start after boot", again);
            }
        }
    }
}
