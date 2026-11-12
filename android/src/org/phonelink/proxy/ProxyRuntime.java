package org.phonelink.proxy;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The service's current state, shared with the activity.
 *
 * <p>Both live in the same process, so a static holder is enough and no binder
 * is needed. Pure Java: the activity is responsible for hopping to the UI
 * thread, because updates can come from connection threads.
 */
final class ProxyRuntime {

    interface Listener {
        void onStateChanged(ProxyState state);
    }

    private static final Object LOCK = new Object();
    private static final CopyOnWriteArrayList<Listener> listeners = new CopyOnWriteArrayList<>();
    private static ProxyState state = ProxyState.stopped();

    private ProxyRuntime() {
    }

    static ProxyState state() {
        synchronized (LOCK) {
            return state;
        }
    }

    static void publish(ProxyState next) {
        List<Listener> snapshot;
        synchronized (LOCK) {
            state = next;
            snapshot = new ArrayList<>(listeners);
        }
        for (Listener listener : snapshot) {
            listener.onStateChanged(next);
        }
    }

    static void addListener(Listener listener) {
        listeners.addIfAbsent(listener);
    }

    static void removeListener(Listener listener) {
        listeners.remove(listener);
    }
}
