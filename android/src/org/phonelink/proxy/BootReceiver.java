package org.phonelink.proxy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Restarts the listener after a reboot.
 *
 * <p>Only once the app has been configured, which happens on the first explicit
 * start: a package that was installed but never used does not open a port.
 */
public final class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        if (!ConfigStore.isConfigured(context)) {
            return;
        }
        try {
            context.startForegroundService(
                    new Intent(context, ProxyService.class).setAction(ProxyService.ACTION_START));
        } catch (IllegalStateException e) {
            // Background-start restrictions: the listener simply stays off until
            // the next explicit start.
            Log.w(ProxyService.TAG, "cannot start after boot", e);
        }
    }
}
