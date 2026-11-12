package org.phonelink.proxy;

/**
 * What the listener is doing right now, as one string plus its parts.
 *
 * <p>Plain Java, so the activity, the notification and the tests read the same
 * text and the wording is covered by the JVM suite.
 */
final class ProxyState {

    final boolean listening;
    final int port;
    final int clients;
    final String reason;

    private ProxyState(boolean listening, int port, int clients, String reason) {
        this.listening = listening;
        this.port = port;
        this.clients = clients;
        this.reason = reason;
    }

    static ProxyState stopped() {
        return new ProxyState(false, 0, 0, "stopped");
    }

    static ProxyState waiting() {
        return new ProxyState(false, 0, 0, "waiting for an allowed network");
    }

    static ProxyState listening(int port, int clients) {
        return new ProxyState(true, port, clients, "");
    }

    static ProxyState paused(String reason) {
        return new ProxyState(false, 0, 0, reason);
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
