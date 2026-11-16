package org.phonelink.proxy;

import android.content.Intent;
import android.graphics.drawable.Icon;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;
import android.widget.Toast;

import java.util.List;

/**
 * Start and stop from the Quick Settings shade.
 *
 * <p>Same actions as the panel and adb; the subtitle distinguishes "off" from
 * "paused", which is the state the SSID predicate leaves the service in.
 *
 * <p>Several proxies can be listening at once and the shade has one tile, so
 * the tile has settings of its own — the burger menu's "The tile" — saying
 * which proxies are on it and how far a click reaches in each direction: the
 * ones on the tile, the one in use, or all of them. A click while something it
 * starts is up takes the stop side; a proxy it does not name is left as it is.
 * With a {@link TileCycle} the presses in between bring up the sets it lists —
 * the tile's proxies, then every saved proxy, then off — and the subtitle names
 * the set that is up.
 * With nothing configured the tile is what it always was: a click starts the
 * proxy in use and stops everything. What that means is {@link TilePlan}'s
 * decision, in plain Java, so the rules are covered without a phone.
 *
 * <p>A tile click is user interaction, which is what makes starting the
 * location-typed foreground service from here allowed. If a build disagrees,
 * the catch says so instead of crashing the shade.
 */
public final class ProxyTile extends TileService implements ProxyRuntime.Listener {

    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onStartListening() {
        super.onStartListening();
        ProxyRuntime.addListener(this);
        update();
    }

    @Override
    public void onStopListening() {
        ProxyRuntime.removeListener(this);
        super.onStopListening();
    }

    @Override
    public void onClick() {
        super.onClick();
        TilePlan plan = plan();
        if (plan.fallback) {
            // Nothing configured: the tile is the switch for the proxy in use.
            if (ProxyRuntime.state().running) {
                stop(null);
                return;
            }
            start(null);
            return;
        }
        // Everything the click starts: the start side while nothing of it is
        // up, and the set of the cycle that the last press left missing.
        if (!plan.start.isEmpty()) {
            for (String name : plan.start) {
                start(name);
            }
            return;
        }
        if (plan.stopAll) {
            stop(null);
            return;
        }
        for (String name : plan.stop) {
            stop(name);
        }
    }

    /** A start by name, or with null the configuration the last start stored. */
    private void start(String name) {
        Intent intent = new Intent(this, ProxyService.class).setAction(ProxyService.ACTION_START);
        if (name != null) {
            intent.putExtra(ConfigStore.EXTRA_PROFILE, name);
        }
        try {
            startForegroundService(intent);
        } catch (IllegalStateException e) {
            // A build that will not allow the location-typed start from here
            // says so instead of crashing the shade.
            Log.w(ProxyService.TAG, "the tile cannot start the service", e);
            Toast.makeText(this, R.string.tile_open_app, Toast.LENGTH_LONG).show();
        }
    }

    /** The tile as the store and the runtime have it. */
    private TilePlan plan() {
        return TilePlan.of(
                ConfigStore.tileProfiles(this),
                ConfigStore.inUse(this),
                ConfigStore.profileNames(this),
                ConfigStore.tileStart(this),
                ConfigStore.tileCycle(this),
                ConfigStore.tileStop(this),
                ProxyRuntime.states());
    }

    /** A stop by name, or with null all of them. */
    private void stop(String name) {
        Intent intent = new Intent(this, ProxyService.class).setAction(ProxyService.ACTION_STOP);
        if (name != null) {
            intent.putExtra(ConfigStore.EXTRA_PROFILE, name);
        }
        startService(intent);
    }

    @Override
    public void onStatesChanged(List<ProxyState> states) {
        main.post(this::update);
    }

    private void update() {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        // The tile reports what its own settings name, so a proxy started from
        // a card it does not name cannot make the switch look on.
        TilePlan plan = plan();
        tile.setLabel(getString(R.string.tile_label));
        tile.setIcon(Icon.createWithResource(this, R.drawable.ic_stat_proxy));
        tile.setState(plan.listening ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setSubtitle(subtitle(plan));
        tile.updateTile();
    }

    /**
     * What the shade says under the label. A set the cycle brought up names
     * itself once it is complete — with one tile and three possible meanings,
     * "listening" says which switch is on but not how far it reached.
     */
    private String subtitle(TilePlan plan) {
        if (plan.listening) {
            return switched(plan.cycleUp);
        }
        if (plan.up) {
            return getString(R.string.tile_paused);
        }
        return getString(R.string.tile_off);
    }

    private String switched(TileScope up) {
        if (up == null) {
            return getString(R.string.tile_listening);
        }
        switch (up) {
            case IN_USE:
                return getString(R.string.tile_listening_in_use);
            case ALL:
                return getString(R.string.tile_listening_all);
            default:
                return getString(R.string.tile_listening_tile);
        }
    }
}
