package org.phonelink.proxy;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.SystemClock;
import android.util.Log;

import java.io.Closeable;
import java.io.IOException;
import java.net.ConnectException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;

/**
 * Opens upstream sockets on the cellular network.
 *
 * <p>While the phone is a Wi-Fi client of the laptop's access point, its default
 * network is that Wi-Fi link, and the gateway is the laptop. A socket opened on
 * the default route therefore goes straight back to the host that asked for it.
 * The app this replaces (5GProxy) holds an active {@code NetworkRequest} for
 * {@code TRANSPORT_CELLULAR} and binds its egress to the result, which is what
 * makes the tunnel leave the phone at all; this class does the same.
 */
final class Egress implements Upstream, Closeable {

    private static final String TAG = "phone-link-proxy";

    /** Upper bound on waiting for a cellular network to come up, per CONNECT. */
    private static final long AWAIT_MS = 10_000;

    private final ConnectivityManager manager;
    private final Object lock = new Object();

    private Network cellular;
    private boolean requested;

    private final ConnectivityManager.NetworkCallback callback =
            new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    synchronized (lock) {
                        cellular = network;
                        lock.notifyAll();
                    }
                }

                @Override
                public void onLost(Network network) {
                    synchronized (lock) {
                        if (network.equals(cellular)) {
                            cellular = null;
                        }
                    }
                }

                @Override
                public void onUnavailable() {
                    synchronized (lock) {
                        lock.notifyAll();
                    }
                }
            };

    Egress(Context context) {
        manager = context.getSystemService(ConnectivityManager.class);
    }

    /** Ask for a cellular network and keep it while the service runs. */
    void start() {
        NetworkRequest request = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build();
        synchronized (lock) {
            if (requested) {
                return;
            }
            requested = true;
        }
        manager.requestNetwork(request, callback);
    }

    @Override
    public void close() {
        synchronized (lock) {
            if (!requested) {
                return;
            }
            requested = false;
            cellular = null;
        }
        try {
            manager.unregisterNetworkCallback(callback);
        } catch (IllegalArgumentException e) {
            // Already gone; nothing to unbind.
            Log.d(TAG, "network callback was not registered", e);
        }
    }

    /**
     * Connect to {@code host:port} on the cellular network.
     *
     * <p>The name is resolved on that network too ({@code Network.getAllByName}):
     * the system resolver would answer over the Wi-Fi link, whose DNS server is
     * the laptop, which forwards back into this proxy.
     */
    @Override
    public Socket connect(String host, int port, int timeoutMs) throws Failure {
        Network network = awaitCellular();
        if (network == null) {
            throw new Upstream.Failure(Socks5Server.REPLY_NETWORK_UNREACHABLE,
                    "no cellular network with internet for " + host + ":" + port);
        }

        InetAddress[] addresses;
        try {
            addresses = network.getAllByName(host);
        } catch (UnknownHostException e) {
            throw new Upstream.Failure(Socks5Server.REPLY_HOST_UNREACHABLE,
                    "cannot resolve " + host + " on the cellular network");
        }

        IOException last = null;
        for (InetAddress address : addresses) {
            Socket socket = null;
            try {
                socket = network.getSocketFactory().createSocket();
                socket.connect(new InetSocketAddress(address, port), timeoutMs);
                socket.setTcpNoDelay(true);
                return socket;
            } catch (IOException e) {
                last = e;
                Closeables.closeQuietly(socket);
            }
        }
        throw new Upstream.Failure(replyFor(last),
                "cannot reach " + host + ":" + port + " over cellular: " + last);
    }

    private Network awaitCellular() {
        long deadline = SystemClock.elapsedRealtime() + AWAIT_MS;
        synchronized (lock) {
            while (cellular == null) {
                long left = deadline - SystemClock.elapsedRealtime();
                if (left <= 0) {
                    return null;
                }
                try {
                    lock.wait(left);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return null;
                }
            }
            return cellular;
        }
    }

    private static int replyFor(IOException failure) {
        if (failure instanceof SocketTimeoutException) {
            return Socks5Server.REPLY_HOST_UNREACHABLE;
        }
        if (failure instanceof ConnectException) {
            return Socks5Server.REPLY_CONNECTION_REFUSED;
        }
        return Socks5Server.REPLY_GENERAL_FAILURE;
    }

}
