package org.phonelink.proxy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
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
import java.util.ArrayList;
import java.util.List;

/**
 * Keeps the SOCKS5 listeners alive while the uplink makes sense, and reports
 * them in the notification shade.
 *
 * <p>More than one proxy can listen at a time: every saved proxy carries its
 * own port, credentials, SSID and switches, so the list is a list of listeners
 * and this service holds one of each. The listeners themselves are
 * {@link Port}s in {@link Ports}, kept by port because a port is what a
 * listener is: a start on a port makes room by stopping whatever held it, and
 * the other ports are left alone. What is left here is what a listener cannot
 * answer for itself — the foreground notification, the shared cellular egress,
 * the wake lock that follows the clients, the boot and the tile, and the store's
 * front door for the actions adb sends.
 *
 * <p>Two ways in, one implementation: adb drives it with
 * {@code am start-foreground-service} through a {@code DUMP}-guarded service,
 * and {@link MainActivity} calls the same actions from the panel. Both write
 * through {@link ConfigStore}, so neither can configure a listener differently
 * from the other.
 *
 * <p>A listener is only open while its {@link Uplink} says the phone is on the
 * Wi-Fi it was configured for; otherwise it stays up, reports why, and binds
 * nothing.
 */
public final class ProxyService extends Service implements Port.Host {

    static final String TAG = "phone-link-proxy";

    static final String ACTION_START = "org.phonelink.proxy.action.START";
    /** Stop everything, or with --es profile/--ei port just that one. */
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

    private Ports ports;

    private PowerManager.WakeLock wakeLock;
    private NotificationManager notifications;
    private Egress egress;
    private ProxyConfig config;
    /** Whether this instance has already been asked to do something. */
    private boolean startedBefore;
    /** Wireless debugging is a switch of the whole app, and one start is enough. */
    private boolean adbTouched;

    @Override
    public void onCreate() {
        super.onCreate();
        ports = new Ports(this);
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
            stopRequested(intent);
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
        start(profile, config);
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
        // Closing the last port closes the egress with it.
        ports.stop(null, false, 0);
        closeEgress();
        // Nothing that happens after this is about the listeners that just went.
        EventLog.setActiveTag(null);
        publishAll();
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
        List<Port> all = ports.all();
        writer.println("  state       " + ProxyState.summary(ports.states()));
        // The saved configuration asked for by the last start, which is what the
        // list marks and what an agent means by "the proxy in use".
        String inUse = ConfigStore.inUse(this);
        writer.println("  profile     " + (inUse == null ? "none" : "\"" + inUse + "\""));
        long up = 0;
        long down = 0;
        for (Port each : all) {
            long[] totals = each.traffic().totals();
            up += totals[0];
            down += totals[1];
            writer.println("  running     " + each.label()
                    // An unnamed one is already known by its port.
                    + (each.name() == null ? "" : " \u00b7 port " + each.config().port)
                    + " \u00b7 \u2193 " + Traffic.human(totals[1])
                    + " · \u2191 " + Traffic.human(totals[0])
                    + " · " + each.clients() + (each.clients() == 1 ? " client" : " clients"));
        }
        writer.println("  traffic     \u2193 " + Traffic.human(down)
                + " \u00b7 \u2191 " + Traffic.human(up) + " in this run");
        if (config != null) {
            writer.println("  using       " + config.summary());
        }
        writer.println("  auto-start  " + ConfigStore.autoStart(this));
        writer.println("  adb_wifi    " + ConfigStore.adbWireless(this)
                + " (Android's switch is " + (AdbWireless.on(this) ? "on" : "off") + ")");
        // What the Quick Settings tile switches: the saved proxies whose switch
        // is on, and how far a click reaches in each direction.
        List<String> bound = ConfigStore.tileProfiles(this);
        writer.println("  tile        "
                + (bound.isEmpty() ? "nothing bound" : String.join(", ", bound)));
        writer.println("  tile_start  " + ConfigStore.tileStart(this).name().toLowerCase());
        writer.println("  tile_stop   " + ConfigStore.tileStop(this).name().toLowerCase());
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

    // -- what a port asks the service for ---------------------------------

    @Override
    public Context context() {
        return this;
    }

    @Override
    public Upstream upstream() {
        if (egress == null) {
            egress = new Egress(this);
            egress.start();
        }
        return egress;
    }

    /**
     * A port's network just became usable. The port adb uses lives only while
     * wireless debugging is on, and a reboot can switch it off; this is the one
     * moment that matters for the host, because the SSID just matched.
     */
    @Override
    public void uplinkUp(Port port) {
        if (!adbTouched && ConfigStore.adbWireless(this)) {
            adbTouched = true;
            boolean wasOff = !AdbWireless.on(this);
            AdbWireless.enable(this);
            if (wasOff && AdbWireless.on(this)) {
                EventLog.addTo(port.name(), "wireless debugging turned back on");
            }
        } else if (!ConfigStore.adbWireless(this)) {
            Log.i(TAG, "wireless debugging left alone: the panel switch is off");
        }
    }

    @Override
    public void clientsChanged() {
        holdWakeLock(ports.totalClients() > 0);
    }

    @Override
    public void changed() {
        publishAll();
    }

    /**
     * One port could not do its job. The others are not its business, so this
     * takes that port out of the list and leaves the rest listening.
     */
    @Override
    public void failed(Port port, String message) {
        Log.e(TAG, message);
        EventLog.addTo(port.name(), "failed: " + message);
        notifyError(message);
        ports.remove(port);
        port.close();
        holdWakeLock(ports.totalClients() > 0);
        if (ports.isEmpty()) {
            closeEgress();
            stopSelf();
        } else {
            publishAll();
        }
    }

    // -- starting and stopping -------------------------------------------

    /**
     * Start the configuration as the proxy called {@code name}. A start on a
     * port that is already taken is a restart of that port; every other port
     * keeps listening, which is the whole point of the list.
     */
    private void start(String name, ProxyConfig config) {
        Port port = ports.start(name, config);
        if (name != null) {
            // An ad-hoc start under a name no profile holds is not "the proxy in
            // use": it would erase the mark the list draws on a card.
            ConfigStore.setInUse(this, name);
        }
        EventLog.setActiveTag(name);
        Log.i(TAG, "starting " + port.label() + " on port " + config.port);
        EventLog.addTo(name, "starting on port " + config.port);
        publishAll();
        port.watch();
    }

    /** {@code STOP}: everything, or the one the intent names. */
    private void stopRequested(Intent intent) {
        String name = intent == null ? null : intent.getStringExtra(ConfigStore.EXTRA_PROFILE);
        name = name == null ? null : name.trim();
        boolean byPort = intent != null && intent.hasExtra(ConfigStore.EXTRA_PORT);
        int port = intent == null ? 0 : intent.getIntExtra(ConfigStore.EXTRA_PORT, 0);
        stopListeners(name, byPort, port);
    }

    /**
     * Close the listeners a stop is about — one name, one port, or all of them
     * — and let the service go when the last one is gone. Kept apart from
     * {@link #stopRequested} so a delete can stop what its name owned without
     * going through the intent again.
     */
    private void stopListeners(String name, boolean byPort, int port) {
        for (Port each : ports.stop(name, byPort, port)) {
            Log.i(TAG, "stopped " + each.label() + " on port " + each.config().port);
            EventLog.addTo(each.name(), "stopped listening on port " + each.config().port);
        }
        holdWakeLock(ports.totalClients() > 0);
        if (ports.isEmpty()) {
            closeEgress();
            stopSelf();
        } else {
            publishAll();
        }
    }

    private void closeEgress() {
        if (egress != null) {
            // No client can arrive while nothing is bound, so the cellular
            // request would only keep the radio busy.
            egress.close();
            egress = null;
        }
    }

    private void holdWakeLock(boolean held) {
        if (held && !wakeLock.isHeld()) {
            // Only while somebody is actually using a tunnel: a lock held for
            // the lifetime of the service is the battery cost this app exists
            // to avoid.
            wakeLock.acquire();
        } else if (!held && wakeLock.isHeld()) {
            wakeLock.release();
        }
    }

    // -- saved configurations --------------------------------------------

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
        if (first && ports.isEmpty()) {
            stopSelf();
        } else {
            publishAll();
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
        // A listener running under that name has nothing left to be called.
        Port named = ports.byName(name);
        EventLog.addTo(name, "deleted \"" + name + "\"");
        Log.i(TAG, "deleted configuration \"" + name + "\"");
        if (named != null) {
            // The configuration is the listener's name, so it goes with the
            // configuration: a port the list cannot show is a port the panel
            // cannot stop. This is also what the panel's own Delete does, so
            // both ways of deleting one end the same.
            EventLog.addTo(name, "deleted \"" + name + "\" while it was running");
            stopListeners(name, false, 0);
            return;
        }
        if (first && ports.isEmpty()) {
            stopSelf();
        } else {
            publishAll();
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
        if (!ConfigStore.renameProfile(this, name, to)) {
            // The panel renames in the store itself and then tells the service,
            // so the old name is already gone there and only the listener that
            // was running under it is left to move. Anything else is an error.
            if (ConfigStore.profile(this, name) != null || ConfigStore.profile(this, to) == null) {
                fail(getString(R.string.error_profile_exists, to));
                return;
            }
        }
        EventLog.addTo(to, "renamed \"" + name + "\" to \"" + to + "\"");
        // A proxy that is running under the old name keeps logging under the
        // new one instead of a name that no longer exists. The entry is the
        // same one — the listening port, its counters and its clients are not
        // affected — so only the name it is filed under moves.
        ports.rename(name, to);
        if (to.equals(ConfigStore.inUse(this))) {
            EventLog.setActiveTag(to);
        }
        Log.i(TAG, "renamed configuration \"" + name + "\" to \"" + to + "\"");
        if (first && ports.isEmpty()) {
            stopSelf();
        } else {
            publishAll();
        }
    }

    // -- the notifications ------------------------------------------------

    /** Share every listener's state with the panel, the shade and the Log page. */
    private void publishAll() {
        List<ProxyRuntime.Proxy> view = new ArrayList<>();
        for (Port each : ports.all()) {
            view.add(new ProxyRuntime.Proxy(each.state(), each.traffic()));
        }
        ProxyRuntime.publish(view);
        if (startedBefore) {
            notifications.notify(NOTIFICATION_ID,
                    buildNotification(ProxyState.summary(ports.states())));
        }
    }

    private void fail(String message) {
        Log.e(TAG, message);
        EventLog.add("failed: " + message);
        notifyError(message);
        stopSelf();
    }

    private void notifyError(String message) {
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_proxy)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(message)
                .setStyle(new Notification.BigTextStyle().bigText(message))
                .build();
        notifications.notify(ERROR_NOTIFICATION_ID, notification);
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
                .setStyle(new Notification.BigTextStyle().bigText(text))
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
