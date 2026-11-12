package org.phonelink.proxy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.FileDescriptor;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Keeps a SOCKS5 listener alive while the uplink makes sense, and reports it in
 * the notification shade.
 *
 * <p>Two ways in, one implementation: adb drives it with
 * {@code am start-foreground-service} through a {@code DUMP}-guarded service,
 * and {@link MainActivity} calls the same actions from the panel. Both write
 * through {@link ConfigStore}, so neither can configure the listener
 * differently from the other.
 *
 * <p>The listener is only open while {@link Uplink} says the phone is on the
 * configured Wi-Fi; otherwise the service stays up, reports why, and binds
 * nothing.
 */
public final class ProxyService extends Service
        implements Socks5Server.Listener, Uplink.Listener {

    static final String TAG = "phone-link-proxy";

    static final String ACTION_START = "org.phonelink.proxy.action.START";
    static final String ACTION_STOP = "org.phonelink.proxy.action.STOP";
    /** Keep the configuration the service has under a name, and stop. */
    static final String ACTION_SAVE_PROFILE = "org.phonelink.proxy.action.SAVE_PROFILE";
    /** Remove a saved configuration by name. */
    static final String ACTION_DELETE_PROFILE = "org.phonelink.proxy.action.DELETE_PROFILE";
    /** Give a saved configuration another name: --es profile OLD --es to NEW. */
    static final String ACTION_RENAME_PROFILE = "org.phonelink.proxy.action.RENAME_PROFILE";

    private static final int NOTIFICATION_ID = 1;
    private static final int ERROR_NOTIFICATION_ID = 2;
    private static final String CHANNEL = "proxy";

    private final Object lock = new Object();
    private final AtomicInteger clients = new AtomicInteger();

    private PowerManager.WakeLock wakeLock;
    private NotificationManager notifications;
    private Egress egress;
    private Socks5Server server;
    private Uplink uplink;
    private ProxyConfig config;
    private ProxyState state = ProxyState.stopped();
    /** Whether this instance has already been asked to do something. */
    private boolean startedBefore;

    @Override
    public void onCreate() {
        super.onCreate();
        notifications = getSystemService(NotificationManager.class);
        PowerManager power = getSystemService(PowerManager.class);
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "phone-link-proxy:egress");
        // A reference-counted lock would need exactly as many releases as
        // acquires; this one is held while at least one client is connected.
        wakeLock.setReferenceCounted(false);

        NotificationChannel channel =
                new NotificationChannel(CHANNEL, getString(R.string.channel_name),
                        NotificationManager.IMPORTANCE_LOW);
        channel.setShowBadge(false);
        notifications.createNotificationChannel(channel);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        boolean stopping = ACTION_STOP.equals(action);
        boolean saving = ACTION_SAVE_PROFILE.equals(action);
        boolean deleting = ACTION_DELETE_PROFILE.equals(action);
        boolean renaming = ACTION_RENAME_PROFILE.equals(action);
        // A service that was already doing something is not restarted by a
        // save or a delete, and a start that only came for one has to go away
        // again.
        boolean first = !startedBefore;
        startedBefore = true;

        // Must happen within five seconds of startForegroundService(), which is
        // how the scripts deliver a stop as well: a stop that skipped this was
        // reported as a foreground service that never reached the foreground.
        boolean foreground = beginForeground(stopping
                ? "stopping"
                : saving ? "saving"
                : deleting ? "deleting"
                : renaming ? "renaming" : "starting");
        if (stopping) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (saving) {
            saveCurrent(intent, first);
            return START_NOT_STICKY;
        }
        if (deleting) {
            deleteSaved(intent, first);
            return START_NOT_STICKY;
        }
        if (renaming) {
            renameSaved(intent, first);
            return START_NOT_STICKY;
        }
        if (!foreground) {
            // Starting from the shade or at boot needs location "all the time";
            // from the panel it works without it.
            fail(getString(R.string.error_background_start));
            return START_NOT_STICKY;
        }

        try {
            config = ConfigStore.resolve(this, intent);
        } catch (IllegalArgumentException e) {
            fail(e.getMessage());
            return START_NOT_STICKY;
        }
        // Which saved proxy this is, so the list can mark its card and the log
        // can keep a proxy's events apart: the one the start named, or the one
        // whose settings these are.
        String profile = intent == null
                ? null
                : intent.getStringExtra(ConfigStore.EXTRA_PROFILE);
        profile = profile == null || profile.trim().isEmpty()
                ? ConfigStore.profileMatching(this, config)
                : profile.trim();
        ConfigStore.setInUse(this, profile);
        EventLog.setActiveTag(profile);
        startWatching();
        return START_STICKY;
    }

    /**
     * Promote the service to the foreground with the location type, which is
     * what keeps the SSID readable while the app is not in front — the point
     * when the tile or the boot receiver starts us.
     *
     * <p>Android refuses that type for a start from the background without
     * background location, and there is no honest fallback: a service with no
     * type is prohibited for this target, and without the SSID the uplink could
     * not tell which Wi-Fi this is anyway. So report instead of guessing.
     *
     * @return whether the service is now in the foreground; a start that cannot
     *     get there has to give up, or the system kills it without ceremony
     */
    private boolean beginForeground(String text) {
        try {
            startForeground(NOTIFICATION_ID, buildNotification(text),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
            return true;
        } catch (SecurityException | IllegalStateException e) {
            Log.w(TAG, "the system refused the foreground service", e);
            return false;
        }
    }

    @Override
    public void onDestroy() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        stopListening();
        // Nothing that happens after this is about the proxy that just went.
        EventLog.setActiveTag(null);
        ProxyRuntime.publish(ProxyState.stopped());
        stopForeground(STOP_FOREGROUND_REMOVE);
        notifications.cancel(NOTIFICATION_ID);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /**
     * The app's own {@code --help}: this is what
     * {@code adb shell dumpsys activity service org.phonelink.proxy/.ProxyService}
     * prints. The same words as the panel's Info dialog, followed by what the
     * service is doing right now, so an agent reads the contract and the facts
     * together.
     */
    @Override
    protected void dump(FileDescriptor fd, PrintWriter writer, String[] args) {
        writer.println(Help.text());
        writer.println();
        writer.println("Right now");
        writer.println("  state       " + state.describe());
        String inUse = ConfigStore.inUse(this);
        writer.println("  profile     " + (inUse == null ? "none" : "\"" + inUse + "\""));
        long[] traffic = Traffic.totals();
        writer.println("  traffic     \u2193 " + Traffic.human(traffic[1])
                + " \u00b7 \u2191 " + Traffic.human(traffic[0]) + " in this run");
        if (config != null) {
            writer.println("  using       " + config.summary());
        }
        writer.println("  auto-start  " + ConfigStore.autoStart(this));
        writer.println("  adb_wifi    " + ConfigStore.adbWireless(this)
                + " (Android's switch is " + (AdbWireless.on(this) ? "on" : "off") + ")");
        List<String> saved = ConfigStore.profileNames(this);
        if (saved.isEmpty()) {
            writer.println("  saved       none");
        }
        for (String name : saved) {
            ProxyConfig profile = ConfigStore.profile(this, name);
            writer.println("  saved       \"" + name + "\" — "
                    + (profile == null ? "?" : profile.summary())
                    + " · auto-start "
                    + (ConfigStore.profileAutoStart(this, name) ? "on" : "off")
                    + " · wireless debugging "
                    + (ConfigStore.profileAdbWireless(this, name) ? "on" : "off"));
        }
        writer.flush();
    }

    /** Called from connection threads. */
    @Override
    public void onClientsChanged(int connected) {
        synchronized (lock) {
            if (connected > 0) {
                if (!wakeLock.isHeld()) {
                    // Only while somebody is actually using the tunnel: a lock
                    // held for the lifetime of the service is the battery cost
                    // this app exists to avoid.
                    wakeLock.acquire();
                }
            } else if (wakeLock.isHeld()) {
                wakeLock.release();
            }
        }
        if (server != null) {
            publish(ProxyState.listening(server.port(), connected));
        }
    }

    /** Called on the main thread by {@link Uplink}. */
    @Override
    public void onUplinkChanged(boolean allowed, String why) {
        Log.i(TAG, "uplink " + (allowed ? "allowed" : "paused") + ": " + why);
        if (allowed) {
            // The port adb uses lives only while wireless debugging is on, and
            // a reboot can switch it off; this is the one moment that matters
            // for the host, because the SSID just matched.
            if (ConfigStore.adbWireless(this)) {
                boolean wasOff = !AdbWireless.on(this);
                AdbWireless.enable(this);
                if (wasOff && AdbWireless.on(this)) {
                    EventLog.add("wireless debugging turned back on");
                }
            } else {
                Log.i(TAG, "wireless debugging left alone: the panel switch is off");
            }
            startListening();
            if (server == null) {
                // startListening() failed and already stopped the service.
                return;
            }
            publish(ProxyState.listening(server.port(), clients.get()));
        } else {
            stopListening();
            publish(ProxyState.paused(why));
        }
    }

    /**
     * {@code SAVE_PROFILE} keeps the configuration the service has under a name,
     * so an agent can configure the listener once and then start it by name.
     * The same store as the panel's {@code Save as…}, so either sees the other.
     */
    private void saveCurrent(Intent intent, boolean first) {
        String name = intent == null
                ? ""
                : intent.getStringExtra(ConfigStore.EXTRA_PROFILE);
        name = name == null ? "" : name.trim();
        if (name.isEmpty()) {
            fail(getString(R.string.error_profile_name));
            return;
        }
        ConfigStore.saveProfile(this, name, ConfigStore.load(this),
                ConfigStore.autoStart(this), ConfigStore.adbWireless(this));
        EventLog.addTo(name, "saved configuration \"" + name + "\"");
        Log.i(TAG, "saved configuration \"" + name + "\"");
        if (first) {
            stopSelf();
        } else {
            // Saving a name is not a restart: a running proxy keeps running and
            // just gets its notification text back.
            publish(state);
        }
    }

    /** {@code DELETE_PROFILE}: the panel's Delete, without the screen. */
    private void deleteSaved(Intent intent, boolean first) {
        String name = intent == null
                ? ""
                : intent.getStringExtra(ConfigStore.EXTRA_PROFILE);
        name = name == null ? "" : name.trim();
        if (name.isEmpty()) {
            fail(getString(R.string.error_profile_name));
            return;
        }
        if (ConfigStore.profile(this, name) == null) {
            fail(getString(R.string.error_profile_missing, name));
            return;
        }
        ConfigStore.deleteProfile(this, name);
        if (name.equals(ConfigStore.inUse(this))) {
            // The list must not keep pointing at a proxy that no longer exists.
            ConfigStore.setInUse(this, null);
        }
        EventLog.addTo(name, "deleted \"" + name + "\"");
        Log.i(TAG, "deleted configuration \"" + name + "\"");
        if (first) {
            stopSelf();
        } else {
            publish(state);
        }
    }

    /** {@code RENAME_PROFILE}: the panel's Rename, without the screen. */
    private void renameSaved(Intent intent, boolean first) {
        String name = intent == null
                ? ""
                : intent.getStringExtra(ConfigStore.EXTRA_PROFILE);
        String to = intent == null ? "" : intent.getStringExtra(ConfigStore.EXTRA_TO);
        name = name == null ? "" : name.trim();
        to = to == null ? "" : to.trim();
        if (name.isEmpty() || to.isEmpty()) {
            fail(getString(R.string.error_profile_name));
            return;
        }
        if (ConfigStore.profile(this, name) == null) {
            fail(getString(R.string.error_profile_missing, name));
            return;
        }
        if (!ConfigStore.renameProfile(this, name, to)) {
            fail(getString(R.string.error_profile_exists, to));
            return;
        }
        EventLog.addTo(to, "renamed \"" + name + "\" to \"" + to + "\"");
        // A proxy that is running under the old name keeps logging under the
        // new one instead of a name that no longer exists.
        if (state.running && to.equals(ConfigStore.inUse(this))) {
            EventLog.setActiveTag(to);
        }
        Log.i(TAG, "renamed configuration \"" + name + "\" to \"" + to + "\"");
        if (first) {
            stopSelf();
        } else {
            publish(state);
        }
    }

    private void startWatching() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        stopListening();
        // The counters answer "what has this run moved", so a new start begins
        // at zero.
        Traffic.reset();
        publish(ProxyState.waiting());
        uplink = new Uplink(this, config.ssid, config.anyNetwork, this::onUplinkChanged);
        uplink.start();
    }

    private void startListening() {
        if (server != null) {
            return;
        }
        if (egress == null) {
            egress = new Egress(this);
            egress.start();
        }
        Socks5Server candidate = new Socks5Server(
                config.port, config.user, config.password, egress, this,
                message -> Log.i(TAG, message));
        try {
            candidate.start();
        } catch (IOException e) {
            fail("cannot listen on 0.0.0.0:" + config.port + ": " + e.getMessage());
            return;
        }
        server = candidate;
        Log.i(TAG, "listening on 0.0.0.0:" + config.port
                + (config.user.isEmpty() ? " without authentication" : " with authentication"));
    }

    private void stopListening() {
        if (server != null) {
            server.close();
            server = null;
        }
        if (egress != null) {
            // No client can arrive while nothing is bound, so the cellular
            // request would only keep the radio busy.
            egress.close();
            egress = null;
        }
        clients.set(0);
        synchronized (lock) {
            if (wakeLock.isHeld()) {
                wakeLock.release();
            }
        }
    }

    /** Share a state with the panel, the shade and the panel's Log page. */
    private void publish(ProxyState next) {
        if (!next.describe().equals(state.describe())) {
            EventLog.add(next.describe());
        }
        state = next;
        ProxyRuntime.publish(next);
        notifications.notify(NOTIFICATION_ID, buildNotification(next.describe()));
    }

    private void fail(String message) {
        Log.e(TAG, message);
        EventLog.add("failed: " + message);
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_proxy)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(message)
                .setStyle(new Notification.BigTextStyle().bigText(message))
                .build();
        notifications.notify(ERROR_NOTIFICATION_ID, notification);
        stopSelf();
    }

    private Notification buildNotification(String text) {
        PendingIntent open = PendingIntent.getActivity(
                this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        Intent stop = new Intent(this, ProxyService.class).setAction(ACTION_STOP);
        PendingIntent stopIntent =
                PendingIntent.getService(this, 0, stop, PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_proxy)
                .setContentTitle(getString(R.string.notification_title))
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .addAction(new Notification.Action.Builder(
                        Icon.createWithResource(this, R.drawable.ic_stat_proxy),
                        getString(R.string.action_stop), stopIntent).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        }
        return builder.build();
    }
}
