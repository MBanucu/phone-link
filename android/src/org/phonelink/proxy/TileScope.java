package org.phonelink.proxy;

/**
 * How far a click on the Quick Settings tile reaches: which proxies it starts,
 * and which it stops.
 *
 * <p>One set of answers for both directions, because a tile is a switch: the
 * start side says what "on" means, the stop side says what a second click
 * takes away. The two are set separately in the tile's own settings — the panel
 * that opens on a long press — and both default to {@link #TILE}, which is the
 * narrowest and the one that needs no thinking: the proxies whose switch on
 * their Service page is on.
 */
enum TileScope {

    /** The proxies bound to the tile, by their own switch. */
    TILE,
    /** The proxy the panel marks in use — the last one started with a name. */
    IN_USE,
    /** Every saved proxy: the start side starts all of them, the stop side stops them all. */
    ALL;

    /**
     * The scope a stored name stands for. Anything unrecognised — a preference
     * written by an older build, say — is the narrow one, so a broken value
     * cannot turn one click into "start everything".
     */
    static TileScope named(String name, TileScope fallback) {
        if (name == null) {
            return fallback;
        }
        try {
            return valueOf(name);
        } catch (IllegalArgumentException e) {
            return fallback;
        }
    }
}
