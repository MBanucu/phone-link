package org.phonelink.proxy;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The listeners a service holds, by port and in the order they were started.
 *
 * <p>A port is what a listener is, so the map is keyed by it: a start on a port
 * that is taken replaces that one and leaves every other port alone, a stop is
 * about one name, one port or all of them, and the order is the order they were
 * started in — which is the order the notification and the dump show.
 *
 * <p>Nothing here talks to Android: the ports answer their own network, and the
 * service behind {@link Port.Host} owns the egress, the wake lock and the
 * notification, so a start or a stop is a change to this map plus what the
 * caller does about the answer.
 */
final class Ports {

    private final Object lock = new Object();
    private final Map<Integer, Port> byPort = new LinkedHashMap<>();
    private final Port.Host host;

    Ports(Port.Host host) {
        this.host = host;
    }

    /** Every port, oldest start first. */
    List<Port> all() {
        synchronized (lock) {
            return new ArrayList<>(byPort.values());
        }
    }

    boolean isEmpty() {
        return all().isEmpty();
    }

    int totalClients() {
        int total = 0;
        for (Port each : all()) {
            total += each.clients();
        }
        return total;
    }

    /** The port filed under a name, or null. */
    Port byName(String name) {
        if (name == null) {
            return null;
        }
        for (Port each : all()) {
            if (name.equals(each.name())) {
                return each;
            }
        }
        return null;
    }

    /**
     * Add a port under a name. A start on a port that is already held is a
     * restart of that port, and the listener that held it goes — every other
     * port keeps listening, which is the whole point of the list.
     */
    Port start(String name, ProxyConfig config) {
        Port existing = take(config.port);
        if (existing != null) {
            existing.close();
            EventLog.addTo(existing.name(),
                    "replaced on port " + config.port + " by a new start");
        }
        Port port = new Port(host, name, config);
        synchronized (lock) {
            byPort.put(config.port, port);
        }
        return port;
    }

    /** Take the ports a stop is about out of the list: one name, one number, all. */
    List<Port> stop(String name, boolean byNumber, int port) {
        List<Port> going = new ArrayList<>();
        synchronized (lock) {
            if (name != null && !name.isEmpty()) {
                for (Port each : byPort.values()) {
                    if (name.equals(each.name())) {
                        going.add(each);
                    }
                }
            } else if (byNumber) {
                Port each = byPort.get(port);
                if (each != null) {
                    going.add(each);
                }
            } else {
                going.addAll(byPort.values());
            }
            for (Port each : going) {
                byPort.remove(each.config().port);
            }
        }
        for (Port each : going) {
            each.close();
        }
        return going;
    }

    /** Forget a port that could not do its job; the caller closes it. */
    void remove(Port port) {
        synchronized (lock) {
            byPort.remove(port.config().port);
        }
    }

    /** Another name for the port that was filed under the old one. */
    Port rename(String from, String to) {
        Port moved = byName(from);
        if (moved != null) {
            moved.rename(to);
        }
        return moved;
    }

    /** What every port is doing, in the order they were started. */
    List<ProxyState> states() {
        List<ProxyState> states = new ArrayList<>();
        for (Port each : all()) {
            states.add(each.state());
        }
        return states;
    }

    private Port take(int port) {
        synchronized (lock) {
            return byPort.remove(port);
        }
    }
}
