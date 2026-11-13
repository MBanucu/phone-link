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
 * <p>Several proxies can be listening at once, and the shade has one tile, so
 * the tile speaks for all of them: it is on while anything listens, a click
 * stops everything, and a click while nothing runs starts the configuration
 * that was last in use. Which one that is, is the panel's business — it is the
 * proxy at the top of the list.
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
        update(ProxyRuntime.state());
    }

    @Override
    public void onStopListening() {
        ProxyRuntime.removeListener(this);
        super.onStopListening();
    }

    @Override
    public void onClick() {
        super.onClick();
        if (ProxyRuntime.state().running) {
            startService(new Intent(this, ProxyService.class).setAction(ProxyService.ACTION_STOP));
            return;
        }
        try {
            startForegroundService(
                    new Intent(this, ProxyService.class).setAction(ProxyService.ACTION_START));
        } catch (IllegalStateException e) {
            Log.w(ProxyService.TAG, "the tile cannot start the service", e);
            Toast.makeText(this, R.string.tile_open_app, Toast.LENGTH_LONG).show();
        }
    }

    @Override
    public void onStatesChanged(List<ProxyState> states) {
        main.post(() -> update(ProxyRuntime.state()));
    }

    private void update(ProxyState state) {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        tile.setLabel(getString(R.string.tile_label));
        tile.setIcon(Icon.createWithResource(this, R.drawable.ic_stat_proxy));
        tile.setState(state.listening ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setSubtitle(subtitle(state));
        tile.updateTile();
    }

    private String subtitle(ProxyState state) {
        if (state.listening) {
            return getString(R.string.tile_listening);
        }
        if (state.running) {
            return getString(R.string.tile_paused);
        }
        return getString(R.string.tile_off);
    }
}
