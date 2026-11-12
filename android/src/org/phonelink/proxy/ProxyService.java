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

import java.io.IOException;
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
        beginForeground();

        try {
            config = ConfigStore.resolve(this, intent);
        } catch (IllegalArgumentException e) {
            fail(e.getMessage());
            return START_NOT_STICKY;
        }
        startWatching();
        return START_STICKY;
    }

    /**
     * The location type keeps the SSID readable while the app is not in front,
     * which is the whole point when the tile starts us from the shade. Android
     * refuses that type for a background start unless the app may hold location
     * in the background, so drop it and say so rather than crash: without it the
     * uplink cannot tell which Wi-Fi this is and the listener simply stays shut.
     */
    private void beginForeground() {
        Notification notification = buildNotification("starting");
        boolean specialUse = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE;
        int type = ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION;
        if (specialUse) {
            type |= ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE;
        }
        try {
            startForeground(NOTIFICATION_ID, notification, type);
        } catch (SecurityException e) {
            Log.w(TAG, "no location in the background: the listener will stay shut", e);
            startForeground(NOTIFICATION_ID, notification,
                    specialUse ? ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE : 0);
        }
    }

    @Override
    public void onDestroy() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        stopListening();
        ProxyRuntime.publish(ProxyState.stopped());
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

    private void startWatching() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        stopListening();
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

    /** Share a state with the panel and the shade. */
    private void publish(ProxyState next) {
        state = next;
        ProxyRuntime.publish(next);
        notifications.notify(NOTIFICATION_ID, buildNotification(next.describe()));
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
