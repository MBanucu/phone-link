package org.phonelink.proxy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Keeps a SOCKS5 listener alive while the uplink makes sense, and reports it in
 * the notification shade.
 *
 * <p>Control surface, exported for adb only: the service is guarded by
 * {@code android.permission.DUMP}, which the shell user holds and ordinary apps
 * do not, so {@code am start-foreground-service} can drive it and nothing else
 * can. That is what makes starting the proxy independent of the lock screen.
 *
 * <p>The listener is only open while {@link Uplink} says the phone is on the
 * configured Wi-Fi or tethering; otherwise the service stays up, reports why,
 * and binds nothing.
 */
public final class ProxyService extends Service
        implements Socks5Server.Listener, Uplink.Listener {

    static final String TAG = "phone-link-proxy";

    static final String ACTION_START = "org.phonelink.proxy.action.START";
    static final String ACTION_STOP = "org.phonelink.proxy.action.STOP";

    static final String EXTRA_PORT = "port";
    static final String EXTRA_USER = "user";
    static final String EXTRA_PASSWORD = "password";
    static final String EXTRA_ANONYMOUS = "anonymous";
    static final String EXTRA_SSID = "ssid";
    static final String EXTRA_ANY_NETWORK = "any_network";

    private static final String PREFS = "config";
    private static final String KEY_PORT = "port";
    private static final String KEY_USER = "user";
    private static final String KEY_PASSWORD = "password";
    private static final String KEY_ANONYMOUS = "anonymous";
    private static final String KEY_SSID = "ssid";
    private static final String KEY_ANY_NETWORK = "any_network";

    private static final int DEFAULT_PORT = 1080;
    private static final String DEFAULT_SSID = "PhoneLink";
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
    private Config config;
    private String detail = "starting";

    static boolean isConfigured(Context context) {
        return context.getSharedPreferences(PREFS, MODE_PRIVATE).contains(KEY_PORT);
    }

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
        if (ACTION_STOP.equals(action)) {
            stopSelf();
            return START_NOT_STICKY;
        }

        // Must happen within five seconds of startForegroundService().
        startForeground(NOTIFICATION_ID, buildNotification("starting"));

        try {
            config = readConfig(intent);
        } catch (IllegalArgumentException e) {
            fail(e.getMessage());
            return START_NOT_STICKY;
        }
        startWatching();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        stopListening();
        stopForeground(STOP_FOREGROUND_REMOVE);
        notifications.cancel(NOTIFICATION_ID);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /** Called from connection threads. */
    @Override
    public void onClientsChanged(int connected) {
        String text;
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
            detail = describe(connected);
            text = detail;
        }
        if (server != null) {
            notifications.notify(NOTIFICATION_ID, buildNotification(text));
        }
    }

    /** Called on the main thread by {@link Uplink}. */
    @Override
    public void onUplinkChanged(boolean allowed, String why) {
        Log.i(TAG, "uplink " + (allowed ? "allowed" : "paused") + ": " + why);
        if (allowed) {
            startListening();
            if (server == null) {
                // startListening() failed and already stopped the service.
                return;
            }
            synchronized (lock) {
                detail = describe(clients.get());
            }
        } else {
            stopListening();
            synchronized (lock) {
                detail = "not listening: " + why;
            }
        }
        notifications.notify(NOTIFICATION_ID, buildNotification(detail));
    }

    private void startWatching() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        stopListening();
        synchronized (lock) {
            detail = "waiting for an allowed network";
        }
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

    private void fail(String message) {
        Log.e(TAG, message);
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_proxy)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(message)
                .setStyle(new Notification.BigTextStyle().bigText(message))
                .build();
        notifications.notify(ERROR_NOTIFICATION_ID, notification);
        stopSelf();
    }

    private String describe(int connected) {
        int port = server == null ? 0 : server.port();
        String where = port == 0 ? "not listening" : "listening on 0.0.0.0:" + port;
        return where + " · " + connected + (connected == 1 ? " client" : " clients");
    }

    private Notification buildNotification(String text) {
        Intent stop = new Intent(this, ProxyService.class).setAction(ACTION_STOP);
        PendingIntent stopIntent =
                PendingIntent.getService(this, 0, stop, PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_proxy)
                .setContentTitle(getString(R.string.notification_title))
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(new Notification.Action.Builder(
                        Icon.createWithResource(this, R.drawable.ic_stat_proxy),
                        getString(R.string.action_stop), stopIntent).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        }
        return builder.build();
    }

    private Config readConfig(Intent intent) {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        int port = intent != null && intent.hasExtra(EXTRA_PORT)
                ? intent.getIntExtra(EXTRA_PORT, DEFAULT_PORT)
                : prefs.getInt(KEY_PORT, DEFAULT_PORT);
        boolean anonymous = intent != null && intent.hasExtra(EXTRA_ANONYMOUS)
                ? intent.getBooleanExtra(EXTRA_ANONYMOUS, false)
                : prefs.getBoolean(KEY_ANONYMOUS, false);
        String user = intent != null && intent.hasExtra(EXTRA_USER)
                ? value(intent.getStringExtra(EXTRA_USER))
                : prefs.getString(KEY_USER, "");
        String password = intent != null && intent.hasExtra(EXTRA_PASSWORD)
                ? value(intent.getStringExtra(EXTRA_PASSWORD))
                : prefs.getString(KEY_PASSWORD, "");
        String ssid = intent != null && intent.hasExtra(EXTRA_SSID)
                ? value(intent.getStringExtra(EXTRA_SSID))
                : prefs.getString(KEY_SSID, DEFAULT_SSID);
        boolean anyNetwork = intent != null && intent.hasExtra(EXTRA_ANY_NETWORK)
                ? intent.getBooleanExtra(EXTRA_ANY_NETWORK, false)
                : prefs.getBoolean(KEY_ANY_NETWORK, false);

        if (port < 1024 || port > 65535) {
            throw new IllegalArgumentException("port must be 1024..65535, got " + port);
        }
        if (anonymous) {
            // The listener treats empty credentials as "no authentication", so
            // an explicit anonymous start must not leave stale ones behind.
            user = "";
            password = "";
        } else {
            if (user.isEmpty() || password.isEmpty()) {
                throw new IllegalArgumentException(
                        "no credentials: pass user and password, or anonymous=true");
            }
            if (bytes(user) > 255 || bytes(password) > 255) {
                throw new IllegalArgumentException("user and password must be at most 255 bytes");
            }
        }
        if (!anyNetwork && ssid.isEmpty()) {
            throw new IllegalArgumentException(
                    "no SSID to match: pass ssid, or any_network=true");
        }

        prefs.edit()
                .putInt(KEY_PORT, port)
                .putString(KEY_USER, user)
                .putString(KEY_PASSWORD, password)
                .putBoolean(KEY_ANONYMOUS, anonymous)
                .putString(KEY_SSID, ssid)
                .putBoolean(KEY_ANY_NETWORK, anyNetwork)
                .apply();
        return new Config(port, user, password, ssid, anyNetwork);
    }

    private static String value(String given) {
        return given == null ? "" : given;
    }

    private static int bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8).length;
    }

    private static final class Config {
        final int port;
        final String user;
        final String password;
        final String ssid;
        final boolean anyNetwork;

        Config(int port, String user, String password, String ssid, boolean anyNetwork) {
            this.port = port;
            this.user = user;
            this.password = password;
            this.ssid = ssid;
            this.anyNetwork = anyNetwork;
        }
    }
}
