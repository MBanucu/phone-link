package org.phonelink.proxy;

import java.util.List;

/**
 * What one listener is doing right now, as one string plus its parts.
 *
 * <p>Plain Java, so the activity, the tile, the notification and the tests read
 * the same text and the wording is covered by the JVM suite.
 *
 * <p>{@link #running} is the service being alive at all; a paused proxy is
 * running but not {@link #listening}, which is what the list needs to tell
 * "off" from "not listening on this network". {@link #name} is the saved
 * configuration it came from, or null when adb started values no name holds.
 */
final class ProxyState {

    final String name;
    final boolean running;
    final boolean listening;
    final int port;
    final int clients;
    final String reason;

    private ProxyState(String name,
            boolean running, boolean listening, int port, int clients, String reason) {
        this.name = name;
        this.running = running;
        this.listening = listening;
        this.port = port;
        this.clients = clients;
        this.reason = reason;
    }

    static ProxyState stopped() {
        return new ProxyState(null, false, false, 0, 0, "stopped");
    }

    static ProxyState stopped(String name) {
        return new ProxyState(name, false, false, 0, 0, "stopped");
    }

    static ProxyState waiting() {
        return waiting(null);
    }

    static ProxyState waiting(String name) {
        return new ProxyState(name, true, false, 0, 0, "waiting for an allowed network");
    }

    static ProxyState listening(int port, int clients) {
        return listening(null, port, clients);
    }

    static ProxyState listening(String name, int port, int clients) {
        return new ProxyState(name, true, true, port, clients, "");
    }

    static ProxyState paused(String reason) {
        return paused(null, reason);
    }

    static ProxyState paused(String name, String reason) {
        return new ProxyState(name, true, false, 0, 0, reason);
    }

    /** The line shown at the top of the panel and under an open proxy. */
    String describe() {
        if (listening) {
            return "listening on 0.0.0.0:" + port + " · " + clients
                    + (clients == 1 ? " client" : " clients");
        }
        return reason.isEmpty() ? "not listening" : "not listening: " + reason;
    }

    /** The short form for a notification with several listeners in it. */
    String label() {
        boolean unnamed = name == null || name.isEmpty();
        String who = unnamed
                ? (port > 0 ? "port " + port : "the listener")
                : "\"" + name + "\"";
        if (listening) {
            // An unnamed listener is known by its port, so it does not say it
            // twice; a named one says which port it took.
            return unnamed ? who : who + " on " + port;
        }
        if (running) {
            return reason.startsWith("waiting") ? who + " waiting" : who + " paused";
        }
        return who + " stopped";
    }

    /**
     * One line for all of them, for the notification: a single listener says
     * everything about itself, several are counted and named.
     */
    static String summary(List<ProxyState> states) {
        if (states.isEmpty()) {
            return "not listening";
        }
        if (states.size() == 1) {
            ProxyState only = states.get(0);
            return only.name == null || only.name.isEmpty()
                    ? only.describe()
                    : "\"" + only.name + "\" " + only.describe();
        }
        StringBuilder line = new StringBuilder();
        line.append(states.size()).append(" proxies: ");
        for (int i = 0; i < states.size(); i++) {
            if (i > 0) {
                line.append(", ");
            }
            line.append(states.get(i).label());
        }
        return line.toString();
    }

    /**
     * All of them as one state, for the tile: on if anything is listening, and
     * the clients of everything put together.
     */
    static ProxyState all(List<ProxyState> states) {
        if (states.isEmpty()) {
            return stopped();
        }
        if (states.size() == 1) {
            return states.get(0);
        }
        boolean listening = false;
        int port = 0;
        int clients = 0;
        String reason = "";
        for (ProxyState state : states) {
            listening |= state.listening;
            clients += state.clients;
            if (state.listening && port == 0) {
                port = state.port;
            }
            if (!state.listening && reason.isEmpty()) {
                reason = state.reason;
            }
        }
        ProxyState combined = new ProxyState(null, true, listening, port, clients,
                listening ? "" : reason);
        return combined;
    }
}
