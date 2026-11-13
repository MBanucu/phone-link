package org.phonelink.capture;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * The adb side of the service, so a harness can ask for a capture, touch the
 * screen and turn the automatic captures on and off:
 *
 * <pre>
 * adb shell am broadcast -a org.phonelink.capture.DUMP
 * adb shell am broadcast -a org.phonelink.capture.WATCH --ez watch true
 * adb shell am broadcast -a org.phonelink.capture.WAIT --es has 'text="OK"'
 * adb shell am broadcast -a org.phonelink.capture.WAIT --es has X --ez gone true
 * adb shell am broadcast -a org.phonelink.capture.WAIT --ez change true
 * adb shell am broadcast -a org.phonelink.capture.WAIT --ei quiet 250
 * adb shell am broadcast -a org.phonelink.capture.TAP --ei x 540 --ei y 1200
 * adb shell am broadcast -a org.phonelink.capture.SWIPE \
 *     --ei x1 540 --ei y1 2200 --ei x2 540 --ei y2 1200 --ei ms 200
 * adb shell am broadcast -a org.phonelink.capture.BACK
 * adb shell am broadcast -a org.phonelink.capture.HOME
 * adb shell am broadcast -a org.phonelink.capture.FLASH --ei edges 8 --ei period 200
 * </pre>
 *
 * <p>The work happens inside the broadcast, so the file is already there when
 * {@code am} returns and nothing has to be waited for — except the flash, which
 * takes as long as it takes and is simply left to run. The receiver runs on the
 * app's main thread, which is where the accessibility service writes from too,
 * so the two cannot interleave a half-open file.
 *
 * <p>{@code WAIT} is the exception and the point: it is answered when the
 * screen says what it was asked about, so {@code am broadcast} returns at that
 * moment. That is how a step of the live harness waits for what it caused —
 * {@code result=0} when the screen answered, {@code 1} when time ran out and
 * {@code 2} when nothing was listening. It goes async, because the answer comes
 * from the main thread this receiver runs on.
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
        if (action == null) {
            return;
        }
        switch (action) {
            case "org.phonelink.capture.WATCH": {
                boolean watch = intent.getBooleanExtra("watch", true);
                service.setWatching(watch);
                service.requestCapture(watch ? "watch" : "unwatch");
                break;
            }
            case "org.phonelink.capture.DUMP":
                service.requestCapture("request");
                break;
            case "org.phonelink.capture.TAP":
                service.tap(intent.getIntExtra("x", 0), intent.getIntExtra("y", 0));
                break;
            case "org.phonelink.capture.SWIPE":
                service.swipe(intent.getIntExtra("x1", 0), intent.getIntExtra("y1", 0),
                        intent.getIntExtra("x2", 0), intent.getIntExtra("y2", 0),
                        Math.max(1, intent.getIntExtra("ms", 200)));
                break;
            case "org.phonelink.capture.WAIT": {
                PendingResult pending = goAsync();
                service.await(intent.getStringExtra("has"),
                        intent.getBooleanExtra("gone", false),
                        intent.getBooleanExtra("change", false),
                        Math.max(0, intent.getIntExtra("quiet", 0)),
                        intent.getIntExtra("timeout", 3000), pending);
                break;
            }
            case "org.phonelink.capture.BACK":
                service.back();
                break;
            case "org.phonelink.capture.HOME":
                service.home();
                break;
            case "org.phonelink.capture.FLASH":
                service.flash(intent.getIntExtra("edges", 8),
                        Math.max(1, intent.getIntExtra("period", 200)));
                break;
            default:
                Log.w(TAG, "nothing happens for " + action);
                break;
        }
    }
}
