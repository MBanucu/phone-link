package org.phonelink.proxy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * What a click on the Quick Settings tile means, from how the tile is
 * configured and what is running right now.
 *
 * <p>The shade has one tile and the phone may have several proxies, so the tile
 * has its own settings — the panel a long press opens: which proxies are bound
 * to it, what a click starts, and what a click stops. Both directions are a
 * {@link TileScope}: the proxies on the tile (the narrow default), the proxy in
 * use, or every saved proxy. The start side is what "the tile is on" means, so
 * the icon follows it; a click while anything of it is up takes the stop side.
 *
 * <p>A tile whose start side names nothing keeps the behaviour it always had —
 * {@link #fallback}, where the caller starts the configuration the last start
 * stored and stops everything — so a phone with one proxy needs no
 * configuration at all. The stop side alone cannot make a tile that never turns
 * on: a tile configured to stop everything while nothing is bound would
 * otherwise be a switch that does nothing at all.
 *
 * <p>Plain Java: the tile does what this says and nothing else, and the JVM
 * suite covers the rules without a phone.
 */
final class TilePlan {

    /** Whether the tile has nothing configured and behaves as it always did. */
    final boolean fallback;
    /** Whether anything the tile's start side names is up, listening or waiting. */
    final boolean up;
    /** Whether anything the tile's start side names is listening right now. */
    final boolean listening;
    /** The proxies to start, by name; empty unless the click starts. */
    final List<String> start;
    /** The proxies to stop, by name; empty unless the click stops. */
    final List<String> stop;
    /** Whether the click stops everything, which is a stop with no name. */
    final boolean stopAll;

    private TilePlan(boolean fallback, boolean up, boolean listening,
            List<String> start, List<String> stop, boolean stopAll) {
        this.fallback = fallback;
        this.up = up;
        this.listening = listening;
        this.start = start;
        this.stop = stop;
        this.stopAll = stopAll;
    }

    /**
     * The click that this configuration and these live states ask for.
     *
     * @param bound the proxies whose tile switch is on
     * @param inUse the proxy the panel marks in use, or null
     * @param saved every saved proxy, by name
     * @param states every running proxy; one whose name is not in a scope is
     *     somebody else's and is ignored
     */
    static TilePlan of(List<String> bound, String inUse, List<String> saved,
            TileScope startScope, TileScope stopScope, List<ProxyState> states) {
        List<String> start = names(startScope, bound, inUse, saved);
        boolean stopAll = stopScope == TileScope.ALL;
        // Everything is one stop with no name, so it needs no list of names.
        List<String> stop = stopAll
                ? Collections.<String>emptyList()
                : names(stopScope, bound, inUse, saved);
        boolean fallback = start.isEmpty();

        boolean up = false;
        boolean listening = false;
        for (ProxyState state : states) {
            // The fallback has no names to compare with, so it speaks for all
            // of them: that is what "the tile is on" meant before settings.
            if (fallback || start.contains(state.name)) {
                up = true;
                if (state.listening) {
                    listening = true;
                }
            }
        }
        if (fallback) {
            return new TilePlan(true, up, listening,
                    Collections.emptyList(), Collections.emptyList(), false);
        }
        // A click does one thing, so only the direction it takes is filled:
        // the start side while nothing of it is up, the stop side while it is.
        return up
                ? new TilePlan(false, true, listening,
                        Collections.emptyList(), Collections.unmodifiableList(stop), stopAll)
                : new TilePlan(false, false, false,
                        Collections.unmodifiableList(start), Collections.emptyList(), false);
    }

    /** The proxies a scope reaches, in a stable order; TILE's order is the store's. */
    private static List<String> names(
            TileScope scope, List<String> bound, String inUse, List<String> saved) {
        List<String> names = new ArrayList<>();
        switch (scope) {
            case TILE:
                names.addAll(bound);
                break;
            case IN_USE:
                // "In use" is a mark on a saved proxy; a name that no longer
                // exists reaches nothing rather than the wrong one.
                if (inUse != null && saved.contains(inUse)) {
                    names.add(inUse);
                }
                break;
            default:
                names.addAll(saved);
                break;
        }
        return names;
    }
}
