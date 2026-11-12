package org.phonelink.capture;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * The adb side of the service, so a harness can ask for a capture and turn the
 * automatic ones on and off:
 *
 * <pre>
 * adb shell am broadcast -a org.phonelink.capture.DUMP
 * adb shell am broadcast -a org.phonelink.capture.WATCH --ez watch true
 * </pre>
 *
 * <p>The capture happens inside the broadcast, so the file is already there
 * when {@code am} returns and nothing has to be waited for. The receiver runs
 * on the app's main thread, which is where the accessibility service writes
 * from too, so the two cannot interleave a half-open file.
 */
public final class DumpReceiver extends BroadcastReceiver {

    private static final String TAG = "phone-link-capture";

    @Override
    public void onReceive(Context context, Intent intent) {
        DumpService service = DumpService.running();
        if (service == null) {
            Log.w(TAG, "no service: accessibility is not enabled for " + context.getPackageName());
            return;
        }
        String action = intent.getAction();
        if ("org.phonelink.capture.WATCH".equals(action)) {
            boolean watch = intent.getBooleanExtra("watch", true);
            service.setWatching(watch);
            service.requestCapture(watch ? "watch" : "unwatch");
        } else if ("org.phonelink.capture.DUMP".equals(action)) {
            service.requestCapture("request");
        }
    }
}
