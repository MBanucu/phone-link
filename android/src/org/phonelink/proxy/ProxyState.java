package org.phonelink.proxy;

/**
 * What the listener is doing right now, as one string plus its parts.
 *
 * <p>Plain Java, so the activity, the tile, the notification and the tests read
 * the same text and the wording is covered by the JVM suite.
 *
 * <p>{@link #running} is the service being alive at all; a paused service is
 * running but not {@link #listening}, which is what the tile needs to tell "off"
 * from "not listening on this network".
 */
final class ProxyState {

    final boolean running;
    final boolean listening;
    final int port;
    final int clients;
    final String reason;

    private ProxyState(
            boolean running, boolean listening, int port, int clients, String reason) {
        this.running = running;
        this.listening = listening;
        this.port = port;
        this.clients = clients;
        this.reason = reason;
    }

    static ProxyState stopped() {
        return new ProxyState(false, false, 0, 0, "stopped");
    }

    static ProxyState waiting() {
        return new ProxyState(true, false, 0, 0, "waiting for an allowed network");
    }

    static ProxyState listening(int port, int clients) {
        return new ProxyState(true, true, port, clients, "");
    }

    static ProxyState paused(String reason) {
        return new ProxyState(true, false, 0, 0, reason);
    }

    /** The line shown in the notification and at the top of the panel. */
    String describe() {
        if (listening) {
            return "listening on 0.0.0.0:" + port + " · " + clients
                    + (clients == 1 ? " client" : " clients");
        }
        return reason.isEmpty() ? "not listening" : "not listening: " + reason;
    }
}
