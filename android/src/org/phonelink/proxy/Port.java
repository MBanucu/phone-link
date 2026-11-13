package org.phonelink.proxy;

import android.content.Context;
import android.util.Log;

import java.io.IOException;

/**
 * One listening proxy: the port it binds, the network it waits for, the bytes it
 * moved, and the state the panel, the tile and the notification read.
 *
 * <p>Asked for by {@link Ports}, which decides how many there are and what a
 * start or a stop does to the others. A port answers the phone's network itself
 * — it binds while the Wi-Fi is the one the proxy was configured for and waits
 * while it is not — and closes everything it owns. What it does not know is
 * where the cellular egress comes from, how many clients there are in total, or
 * that a notification exists: those are the service's, through {@link Host}.
 */
final class Port {

    /** What a port needs from the service it lives in. */
    interface Host {
        /** The context a network callback is registered against. */
        Context context();

        /** The cellular egress the ports share, started on demand. */
        Upstream upstream();

        /** This port's network just became usable: the service's own business. */
        void uplinkUp(Port port);

        /** The total number of clients changed, so the wake lock may have to. */
        void clientsChanged();

        /** This port's state changed: the panel, the tile and the shade. */
        void changed();

        /** This port could not do its job, and does not exist any more. */
        void failed(Port port, String why);
    }

    /** Not final: a rename moves the port to its new name in place. */
    private String name;
    private final ProxyConfig config;
    private final Traffic traffic = new Traffic();
    private final Host host;
    private Uplink uplink;
    private Socks5Server server;
    /** Waiting, paused or listening; the clients count is kept current. */
    private ProxyState state;
    private int clients;

    Port(Host host, String name, ProxyConfig config) {
        this.host = host;
        this.name = name;
        this.config = config;
        this.state = ProxyState.waiting(name);
    }

    String name() {
        return name;
    }

    ProxyConfig config() {
        return config;
    }

    Traffic traffic() {
        return traffic;
    }

    int clients() {
        return clients;
    }

    /** The live state, not a copy of the last one: the port is the authority. */
    ProxyState state() {
        return server == null ? state : ProxyState.listening(name, config.port, clients);
    }

    /** How a log line and the dump name it; an unnamed one is known by its port. */
    String label() {
        return name == null ? "port " + config.port : "\"" + name + "\"";
    }

    /**
     * Follow the phone's network: bind while it is the configured Wi-Fi, wait
     * while it is not, and follow it back when it returns.
     */
    void watch() {
        uplink = new Uplink(host.context(), config.ssid, config.anyNetwork,
                this::onUplinkChanged);
        uplink.start();
    }

    private void onUplinkChanged(boolean allowed, String why) {
        Log.i(ProxyService.TAG, label() + " uplink " + (allowed ? "allowed" : "paused")
                + ": " + why);
        if (!allowed) {
            pause(why);
            host.changed();
            return;
        }
        host.uplinkUp(this);
        bind();
    }

    /** Bind the port, or say why not; a failure takes the port out of the list. */
    private boolean bind() {
        if (server != null) {
            return true;
        }
        Socks5Server candidate = new Socks5Server(
                config.port, config.user, config.password, host.upstream(), traffic,
                this::setClients, message -> Log.i(ProxyService.TAG, message));
        try {
            candidate.start();
        } catch (IOException e) {
            host.failed(this, "cannot listen on 0.0.0.0:" + config.port + ": "
                    + e.getMessage());
            return false;
        }
        server = candidate;
        state = ProxyState.listening(name, config.port, clients);
        Log.i(ProxyService.TAG, label() + " listening on 0.0.0.0:" + config.port
                + (config.user.isEmpty() ? " without authentication" : " with authentication"));
        host.changed();
        return true;
    }

    /** Close the port and keep the counters: the network can come back. */
    private void unbind() {
        if (server != null) {
            server.close();
            server = null;
        }
        clients = 0;
    }

    private void pause(String why) {
        unbind();
        state = ProxyState.paused(name, why);
        // Nobody is connected to a port that is not bound, so the wake lock the
        // service holds for its clients may go with them.
        host.clientsChanged();
    }

    /** Everything this port owns: its socket, its network callback, its clients. */
    void close() {
        if (uplink != null) {
            uplink.close();
            uplink = null;
        }
        unbind();
    }

    /** Another name for the same port; what it is listening on does not move. */
    void rename(String to) {
        name = to;
        state = state.listening
                ? ProxyState.listening(to, config.port, clients)
                : ProxyState.paused(to, state.reason);
    }

    /** Called from connection threads, once per change. */
    private void setClients(int connected) {
        clients = connected;
        if (connected > 0) {
            state = ProxyState.listening(name, config.port, connected);
        }
        host.clientsChanged();
        host.changed();
    }
}
