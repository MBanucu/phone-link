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
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Keeps the SOCKS5 listeners alive while the uplink makes sense, and reports
 * them in the notification shade.
 *
 * <p>More than one proxy can listen at a time: every saved proxy carries its
 * own port, credentials, SSID and switches, so the list is a list of listeners
 * and this service holds one of each. They are kept by port, because a port is
 * what a listener is: a start on a port makes room by stopping whatever held
 * it, and the other ports are left alone.
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
public final class ProxyService extends Service {

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

    /**
     * One running listener: the configuration it came from, the network it
     * waits for, the port it bound and the bytes it moved.
     */
    private static final class Running {
        /** Not final: a rename moves the listener to its new name in place. */
        String name;
        final ProxyConfig config;
        final Traffic traffic = new Traffic();
        Uplink uplink;
        Socks5Server server;
        /** Waiting, paused or listening; the clients count is kept current. */
        ProxyState state;
        int clients;

        Running(String name, ProxyConfig config) {
            this.name = name;
            this.config = config;
            this.state = ProxyState.waiting(name);
        }
    }

    private final Object lock = new Object();
    /** By port, in the order they were started. */
    private final Map<Integer, Running> running = new LinkedHashMap<>();

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
        List<Running> all = new ArrayList<>(running.values());
        synchronized (lock) {
            running.clear();
        }
        for (Running each : all) {
            close(each);
        }
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
        List<Running> all = new ArrayList<>(running.values());
        writer.println("  state       " + ProxyState.summary(states(all)));
        // The saved configuration asked for by the last start, which is what the
        // list marks and what an agent means by "the proxy in use".
        String inUse = ConfigStore.inUse(this);
        writer.println("  profile     " + (inUse == null ? "none" : "\"" + inUse + "\""));
        long up = 0;
        long down = 0;
        for (Running each : all) {
            long[] totals = each.traffic.totals();
            up += totals[0];
            down += totals[1];
            writer.println("  running     " + label(each)
                    // An unnamed one is already known by its port.
                    + (each.name == null ? "" : " \u00b7 port " + each.config.port)
                    + " \u00b7 \u2193 " + Traffic.human(totals[1])
                    + " · \u2191 " + Traffic.human(totals[0])
                    + " · " + each.clients + (each.clients == 1 ? " client" : " clients"));
        }
        writer.println("  traffic     \u2193 " + Traffic.human(down)
                + " \u00b7 \u2191 " + Traffic.human(up) + " in this run");
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

    private static String label(Running each) {
        return each.name == null ? "port " + each.config.port : "\"" + each.name + "\"";
    }

    // -- starting and stopping -------------------------------------------

    /**
     * Start the configuration as the proxy called {@code name}. A start on a
     * port that is already taken is a restart of that port; every other port
     * keeps listening, which is the whole point of the list.
     */
    private void start(String name, ProxyConfig config) {
        Running existing = running.get(config.port);
        if (existing != null) {
            synchronized (lock) {
                running.remove(config.port);
            }
            close(existing);
            EventLog.addTo(existing.name,
                    "replaced on port " + config.port + " by a new start");
        }
        Running listener = new Running(name, config);
        synchronized (lock) {
            running.put(config.port, listener);
        }
        if (name != null) {
            // An ad-hoc start under a name no profile holds is not "the proxy in
            // use": it would erase the mark the list draws on a card.
            ConfigStore.setInUse(this, name);
        }
        EventLog.setActiveTag(name);
        Log.i(TAG, "starting " + label(listener) + " on port " + config.port);
        EventLog.addTo(name, "starting on port " + config.port);
        publishAll();
        listener.uplink = new Uplink(this, config.ssid, config.anyNetwork,
                (allowed, why) -> onUplink(listener, allowed, why));
        listener.uplink.start();
    }

    /** {@code STOP}: everything, or the one the intent names. */
    private void stopRequested(Intent intent) {
        String name = intent == null ? null : intent.getStringExtra(ConfigStore.EXTRA_PROFILE);
        name = name == null ? null : name.trim();
        boolean byPort = intent != null && intent.hasExtra(ConfigStore.EXTRA_PORT);
        int port = intent == null ? 0 : intent.getIntExtra(ConfigStore.EXTRA_PORT, 0);
        List<Running> going = new ArrayList<>();
        synchronized (lock) {
            if (name != null && !name.isEmpty()) {
                for (Running each : running.values()) {
                    if (name.equals(each.name)) {
                        going.add(each);
                    }
                }
            } else if (byPort) {
                Running each = running.get(port);
                if (each != null) {
                    going.add(each);
                }
            } else {
                going.addAll(running.values());
            }
            for (Running each : going) {
                running.remove(each.config.port);
            }
        }
        for (Running each : going) {
            close(each);
            Log.i(TAG, "stopped " + label(each) + " on port " + each.config.port);
            EventLog.addTo(each.name, "stopped listening on port " + each.config.port);
        }
        if (running.isEmpty()) {
            closeEgress();
            stopSelf();
        } else {
            publishAll();
        }
    }

    /**
     * Called on the main thread by a listener's {@link Uplink}.
     */
    private void onUplink(Running listener, boolean allowed, String why) {
        Log.i(TAG, label(listener) + " uplink " + (allowed ? "allowed" : "paused") + ": " + why);
        if (allowed) {
            // The port adb uses lives only while wireless debugging is on, and
            // a reboot can switch it off; this is the one moment that matters
            // for the host, because the SSID just matched.
            if (!adbTouched && ConfigStore.adbWireless(this)) {
                adbTouched = true;
                boolean wasOff = !AdbWireless.on(this);
                AdbWireless.enable(this);
                if (wasOff && AdbWireless.on(this)) {
                    EventLog.addTo(listener.name, "wireless debugging turned back on");
                }
            } else if (!ConfigStore.adbWireless(this)) {
                Log.i(TAG, "wireless debugging left alone: the panel switch is off");
            }
            if (!startListening(listener)) {
                // startListening() failed and took this listener away.
                return;
            }
        } else {
            stopListening(listener);
            listener.state = ProxyState.paused(listener.name, why);
            publishAll();
        }
    }

    private boolean startListening(Running listener) {
        if (listener.server != null) {
            return true;
        }
        if (egress == null) {
            egress = new Egress(this);
            egress.start();
        }
        Socks5Server candidate = new Socks5Server(
                listener.config.port, listener.config.user, listener.config.password, egress,
                listener.traffic, count -> onClients(listener, count),
                message -> Log.i(TAG, message));
        try {
            candidate.start();
        } catch (IOException e) {
            failOne(listener, "cannot listen on 0.0.0.0:" + listener.config.port + ": "
                    + e.getMessage());
            return false;
        }
        listener.server = candidate;
        listener.state = ProxyState.listening(listener.name, listener.config.port,
                listener.clients);
        Log.i(TAG, label(listener) + " listening on 0.0.0.0:" + listener.config.port
                + (listener.config.user.isEmpty()
                        ? " without authentication" : " with authentication"));
        publishAll();
        return true;
    }

    private void stopListening(Running listener) {
        if (listener.server != null) {
            listener.server.close();
            listener.server = null;
        }
        listener.clients = 0;
        holdWakeLock(totalClients() > 0);
    }

    /** Everything a listener owns, gone: its port, its network gate, its wake. */
    private void close(Running listener) {
        if (listener.uplink != null) {
            listener.uplink.close();
            listener.uplink = null;
        }
        if (listener.server != null) {
            listener.server.close();
            listener.server = null;
        }
        listener.clients = 0;
        if (running.isEmpty()) {
            closeEgress();
            holdWakeLock(false);
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

    /** Called from connection threads, once per listener. */
    private void onClients(Running listener, int connected) {
        listener.clients = connected;
        if (connected > 0) {
            listener.state = ProxyState.listening(listener.name, listener.config.port, connected);
        }
        holdWakeLock(totalClients() > 0);
        publishAll();
    }

    private int totalClients() {
        int total = 0;
        for (Running each : new ArrayList<>(running.values())) {
            total += each.clients;
        }
        return total;
    }

    private void holdWakeLock(boolean held) {
        synchronized (lock) {
            if (held && !wakeLock.isHeld()) {
                // Only while somebody is actually using a tunnel: a lock held
                // for the lifetime of the service is the battery cost this app
                // exists to avoid.
                wakeLock.acquire();
            } else if (!held && wakeLock.isHeld()) {
                wakeLock.release();
            }
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
        if (first && running.isEmpty()) {
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
        // A listener running under that name keeps its port but loses the name
        // it is listed under, or the panel would show a card that is not there.
        Running named = null;
        synchronized (lock) {
            for (Running each : running.values()) {
                if (name.equals(each.name)) {
                    named = each;
                }
            }
        }
        if (named != null) {
            EventLog.addTo(name, "deleted \"" + name + "\" while it was running");
            publishAll();
        }
        EventLog.addTo(name, "deleted \"" + name + "\"");
        Log.i(TAG, "deleted configuration \"" + name + "\"");
        if (first && running.isEmpty()) {
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
        synchronized (lock) {
            for (Running each : running.values()) {
                if (name.equals(each.name)) {
                    each.name = to;
                    each.state = each.state.listening
                            ? ProxyState.listening(to, each.config.port, each.clients)
                            : ProxyState.paused(to, each.state.reason);
                }
            }
        }
        if (to.equals(ConfigStore.inUse(this))) {
            EventLog.setActiveTag(to);
        }
        Log.i(TAG, "renamed configuration \"" + name + "\" to \"" + to + "\"");
        if (first && running.isEmpty()) {
            stopSelf();
        } else {
            publishAll();
        }
    }

    // -- the notifications ------------------------------------------------

    private List<ProxyState> states(List<Running> all) {
        List<ProxyState> states = new ArrayList<>();
        for (Running each : all) {
            states.add(each.server == null
                    ? each.state
                    : ProxyState.listening(each.name, each.config.port, each.clients));
        }
        return states;
    }

    /** Share every listener's state with the panel, the shade and the Log page. */
    private void publishAll() {
        List<Running> all;
        synchronized (lock) {
            all = new ArrayList<>(running.values());
        }
        List<ProxyRuntime.Proxy> view = new ArrayList<>();
        for (Running each : all) {
            ProxyState state = each.server == null
                    ? each.state
                    : ProxyState.listening(each.name, each.config.port, each.clients);
            each.state = state;
            view.add(new ProxyRuntime.Proxy(state, each.traffic));
        }
        ProxyRuntime.publish(view);
        if (startedBefore) {
            notifications.notify(NOTIFICATION_ID,
                    buildNotification(ProxyState.summary(states(all))));
        }
    }

    private void fail(String message) {
        Log.e(TAG, message);
        EventLog.add("failed: " + message);
        notifyError(message);
        stopSelf();
    }

    /**
     * One listener could not do its job. The others are not its business, so
     * this takes that listener out of the list and leaves the rest listening.
     */
    private void failOne(Running listener, String message) {
        Log.e(TAG, message);
        EventLog.addTo(listener.name, "failed: " + message);
        notifyError(message);
        synchronized (lock) {
            running.remove(listener.config.port);
        }
        close(listener);
        if (running.isEmpty()) {
            stopSelf();
        } else {
            publishAll();
        }
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
