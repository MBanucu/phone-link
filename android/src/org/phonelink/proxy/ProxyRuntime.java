package org.phonelink.proxy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The service's current state, shared with the activity and the tile.
 *
 * <p>Both live in the same process, so a static holder is enough and no binder
 * is needed. Pure Java: the activity is responsible for hopping to the UI
 * thread, because updates can come from connection threads.
 *
 * <p>Several proxies can listen at once, so this holds a list: every entry is
 * one running listener with its own counters. The list is replaced whole on
 * every change, which is what makes a reader's snapshot consistent.
 */
final class ProxyRuntime {

    interface Listener {
        void onStatesChanged(List<ProxyState> states);
    }

    /** One running listener, as the panel and the tile see it. */
    static final class Proxy {
        final ProxyState state;
        final Traffic traffic;

        Proxy(ProxyState state, Traffic traffic) {
            this.state = state;
            this.traffic = traffic;
        }
    }

    private static final Object LOCK = new Object();
    private static final CopyOnWriteArrayList<Listener> listeners = new CopyOnWriteArrayList<>();
    private static List<Proxy> running = Collections.emptyList();

    private ProxyRuntime() {
    }

    /** Every running proxy, in the order they were started. */
    static List<Proxy> running() {
        synchronized (LOCK) {
            return running;
        }
    }

    /** The running proxy with that name, or null when it is not running. */
    static Proxy forName(String name) {
        if (name == null) {
            return null;
        }
        for (Proxy proxy : running()) {
            if (name.equals(proxy.state.name)) {
                return proxy;
            }
        }
        return null;
    }

    /** The states alone, for the things that only draw them. */
    static List<ProxyState> states() {
        List<ProxyState> states = new ArrayList<>();
        for (Proxy proxy : running()) {
            states.add(proxy.state);
        }
        return states;
    }

    /**
     * All of them as one state: what the tile reports and what a caller with no
     * opinion about which proxy means.
     */
    static ProxyState state() {
        return ProxyState.all(states());
    }

    static void publish(List<Proxy> next) {
        List<Listener> snapshot;
        List<ProxyState> states = new ArrayList<>();
        for (Proxy proxy : next) {
            states.add(proxy.state);
        }
        synchronized (LOCK) {
            running = Collections.unmodifiableList(new ArrayList<>(next));
            snapshot = new ArrayList<>(listeners);
        }
        List<ProxyState> view = Collections.unmodifiableList(states);
        for (Listener listener : snapshot) {
            listener.onStatesChanged(view);
        }
    }

    static void addListener(Listener listener) {
        listeners.addIfAbsent(listener);
    }

    static void removeListener(Listener listener) {
        listeners.remove(listener);
    }
}
