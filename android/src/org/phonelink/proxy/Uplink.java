package org.phonelink.proxy;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.io.Closeable;

/**
 * Decides whether the listener may run.
 *
 * <p>Allowed only while the phone is a client of the configured SSID. Everywhere
 * else the port stays closed, because a wildcard listener on an arbitrary Wi-Fi
 * LAN is an open relay behind one password. Tethering deliberately does not
 * count: the hotspot and USB paths are not wanted here.
 *
 * <p>SSID reads are redacted to {@code <unknown ssid>} without location
 * permission and location enabled, and a redacted SSID is treated as "not the
 * configured one" rather than as a match.
 */
final class Uplink implements Closeable {

    private static final String TAG = "phone-link-proxy";

    interface Listener {
        void onUplinkChanged(boolean allowed, String detail);
    }

    private static final class Verdict {
        final boolean allowed;
        final String detail;

        Verdict(boolean allowed, String detail) {
            this.allowed = allowed;
            this.detail = detail;
        }
    }

    private final ConnectivityManager manager;
    private final WifiManager wifiManager;
    private final String ssid;
    private final boolean anyNetwork;
    private final Listener listener;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private final ConnectivityManager.NetworkCallback callback =
            new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    evaluate();
                }

                @Override
                public void onLost(Network network) {
                    evaluate();
                }

                @Override
                public void onCapabilitiesChanged(
                        Network network, NetworkCapabilities capabilities) {
                    evaluate();
                }

                @Override
                public void onLinkPropertiesChanged(
                        Network network, LinkProperties properties) {
                    evaluate();
                }
            };

    private boolean running;
    private boolean allowed;
    private String detail = "";

    Uplink(Context context, String ssid, boolean anyNetwork, Listener listener) {
        this.manager = context.getSystemService(ConnectivityManager.class);
        this.wifiManager = context.getSystemService(WifiManager.class);
        this.ssid = ssid;
        this.anyNetwork = anyNetwork;
        this.listener = listener;
    }

    void start() {
        running = true;
        manager.registerDefaultNetworkCallback(callback, handler);
        evaluate();
    }

    private void evaluate() {
        if (!running) {
            return;
        }
        Verdict verdict = verdict();
        if (verdict.allowed == allowed && verdict.detail.equals(detail)) {
            return;
        }
        allowed = verdict.allowed;
        detail = verdict.detail;
        listener.onUplinkChanged(allowed, detail);
    }

    private Verdict verdict() {
        if (anyNetwork) {
            return new Verdict(true, "any network is allowed");
        }
        Network active = manager.getActiveNetwork();
        NetworkCapabilities capabilities =
                active == null ? null : manager.getNetworkCapabilities(active);
        if (capabilities == null) {
            return new Verdict(false, "no default network");
        }
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            return new Verdict(false, "the default network is not Wi-Fi");
        }

        String connected = ssid(capabilities);
        if (connected == null) {
            return new Verdict(false,
                    "cannot read the Wi-Fi SSID; needs location permission and location on");
        }
        if (connected.equals(ssid)) {
            return new Verdict(true, "on \"" + connected + "\"");
        }
        return new Verdict(false, "on \"" + connected + "\", not \"" + ssid + "\"");
    }

    @SuppressWarnings("deprecation") // getConnectionInfo() is the only SSID source that works here
    private String ssid(NetworkCapabilities capabilities) {
        // Reading the SSID is reading location data, which is why the service
        // declares the location foreground type; without it this arrives as
        // <unknown ssid>.
        Object transport = capabilities.getTransportInfo();
        if (transport instanceof WifiInfo) {
            String reported = ((WifiInfo) transport).getSSID();
            if (reported != null && !reported.isEmpty() && !reported.startsWith("<")) {
                return stripQuotes(reported);
            }
        }
        // The transport copy stays redacted on this build; the Wi-Fi service
        // answers the same question with ACCESS_WIFI_STATE held.
        WifiInfo connection = wifiManager == null ? null : wifiManager.getConnectionInfo();
        String reported = connection == null ? null : connection.getSSID();
        if (reported == null || reported.isEmpty() || reported.startsWith("<")) {
            Log.i(TAG, "SSID redacted: " + reported);
            return null;
        }
        return stripQuotes(reported);
    }

    private static String stripQuotes(String reported) {
        if (reported.length() >= 2 && reported.startsWith("\"") && reported.endsWith("\"")) {
            return reported.substring(1, reported.length() - 1);
        }
        return reported;
    }

    @Override
    public void close() {
        running = false;
        try {
            manager.unregisterNetworkCallback(callback);
        } catch (IllegalArgumentException e) {
            // Never registered, or already gone.
        }
    }
}
