package org.phonelink.proxy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * The sets a click on the Quick Settings tile brings up on its way from the
 * start side to the stop side.
 *
 * <p>A {@link TileScope} says how far a click reaches; a list of them says how
 * many clicks there are. With the cycle "the tile's proxies, then every saved
 * proxy" and a stop side of everything, the tile is a three-press switch: the
 * first press starts what it always did, the second adds the saved proxies the
 * tile does not name, the third stops them all. Empty — the default — the tile
 * has exactly the two states it had before the cycle existed, so nothing needs
 * configuring to keep working.
 *
 * <p>The sets are stored by name, in one spelling and one order (TILE, IN_USE,
 * ALL): a preference someone edited by hand, or a build that once wrote
 * something else, must not turn into a different number of presses. Unknown
 * names are dropped rather than guessed at — the same rule as {@link
 * TileScope#named}, for the same reason: a broken value cannot widen a click.
 *
 * <p>Plain Java, so the JVM suite covers the rules without a phone.
 */
final class TileCycle {

    private TileCycle() {
    }

    /** The sets this cycle lists, in the canonical order, without duplicates. */
    static List<TileScope> parse(String stored) {
        List<TileScope> cycle = new ArrayList<>();
        if (stored == null) {
            return cycle;
        }
        // Both separators, so a value someone wrote as "TILE ALL" still reads;
        // the canonical spelling is commas, which is what format writes.
        for (String name : stored.split("[,;\\s]+")) {
            TileScope scope = null;
            try {
                scope = TileScope.valueOf(name.trim());
            } catch (IllegalArgumentException e) {
                // Not a set: dropped, not guessed at.
            }
            if (scope != null && !cycle.contains(scope)) {
                cycle.add(scope);
            }
        }
        return order(cycle);
    }

    /** The stored spelling: canonical order, commas, empty for an empty cycle. */
    static String format(List<TileScope> cycle) {
        List<TileScope> ordered = order(cycle);
        StringBuilder text = new StringBuilder();
        for (TileScope scope : ordered) {
            if (text.length() > 0) {
                text.append(',');
            }
            text.append(scope.name());
        }
        return text.toString();
    }

    /** How the adb dump says it: the names as the settings page shows them. */
    static String shown(List<TileScope> cycle) {
        List<TileScope> ordered = order(cycle);
        if (ordered.isEmpty()) {
            return "none";
        }
        StringBuilder text = new StringBuilder();
        for (TileScope scope : ordered) {
            if (text.length() > 0) {
                text.append(',');
            }
            text.append(scope.name().toLowerCase(java.util.Locale.ROOT));
        }
        return text.toString();
    }

    static boolean has(List<TileScope> cycle, TileScope scope) {
        return cycle != null && cycle.contains(scope);
    }

    /** The cycle with one set turned on or off; the order does not depend on it. */
    static List<TileScope> with(List<TileScope> cycle, TileScope scope, boolean on) {
        List<TileScope> next = new ArrayList<>();
        if (cycle != null) {
            next.addAll(cycle);
        }
        next.remove(scope);
        if (on) {
            next.add(scope);
        }
        return order(next);
    }

    /** TILE, IN_USE, ALL — the order the settings page lists them in. */
    private static List<TileScope> order(List<TileScope> cycle) {
        List<TileScope> ordered = new ArrayList<>();
        if (cycle == null) {
            return ordered;
        }
        for (TileScope scope : TileScope.values()) {
            if (cycle.contains(scope)) {
                ordered.add(scope);
            }
        }
        return Collections.unmodifiableList(ordered);
    }
}
