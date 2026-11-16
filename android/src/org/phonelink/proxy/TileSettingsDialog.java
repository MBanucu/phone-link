package org.phonelink.proxy;

import android.app.Activity;
import android.app.AlertDialog;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.RadioGroup;
import android.widget.TextView;

import java.util.List;

/**
 * The Quick Settings tile's own page: what a click starts, what it stops, and
 * which proxies are on it.
 *
 * <p>A page of the app, not of the shade: Android's long press on a tile is
 * "App info", which is where a user looks for the app anyway, and the app's
 * menu is where the rest of its settings already live. Every control stores as
 * it is touched, so the next click on the tile follows without a Save — a
 * settings page with a Save button would only make the tile's answer depend on
 * whether somebody remembered to press it.
 */
final class TileSettingsDialog {

    private TileSettingsDialog() {
    }

    /**
     * Show the page, and tell the caller when it closes: the panel's line about
     * the tile names the proxies bound here.
     */
    static void show(Activity activity, Runnable changed) {
        View view = LayoutInflater.from(activity).inflate(R.layout.dialog_tile, null);
        RadioGroup start = view.findViewById(R.id.start_scope);
        RadioGroup stop = view.findViewById(R.id.stop_scope);
        LinearLayout profiles = view.findViewById(R.id.tile_profiles);

        List<TileScope> cycle = ConfigStore.tileCycle(activity);
        CheckBox cycleTile = view.findViewById(R.id.cycle_tile);
        CheckBox cycleInUse = view.findViewById(R.id.cycle_in_use);
        CheckBox cycleAll = view.findViewById(R.id.cycle_all);
        cycleTile.setChecked(TileCycle.has(cycle, TileScope.TILE));
        cycleInUse.setChecked(TileCycle.has(cycle, TileScope.IN_USE));
        cycleAll.setChecked(TileCycle.has(cycle, TileScope.ALL));
        cycleTile.setOnCheckedChangeListener((button, checked) ->
                ConfigStore.setTileCycle(activity,
                        TileCycle.with(ConfigStore.tileCycle(activity), TileScope.TILE, checked)));
        cycleInUse.setOnCheckedChangeListener((button, checked) ->
                ConfigStore.setTileCycle(activity, TileCycle.with(
                        ConfigStore.tileCycle(activity), TileScope.IN_USE, checked)));
        cycleAll.setOnCheckedChangeListener((button, checked) ->
                ConfigStore.setTileCycle(activity,
                        TileCycle.with(ConfigStore.tileCycle(activity), TileScope.ALL, checked)));

        start.check(startRadio(ConfigStore.tileStart(activity)));
        stop.check(stopRadio(ConfigStore.tileStop(activity)));
        start.setOnCheckedChangeListener((group, checked) ->
                ConfigStore.setTileStart(activity, startScope(checked)));
        stop.setOnCheckedChangeListener((group, checked) ->
                ConfigStore.setTileStop(activity, stopScope(checked)));

        for (String name : ConfigStore.profileNames(activity)) {
            CheckBox box = new CheckBox(activity);
            box.setText(name);
            box.setChecked(ConfigStore.profileTile(activity, name));
            box.setOnCheckedChangeListener((button, checked) ->
                    ConfigStore.setProfileTile(activity, name, checked));
            profiles.addView(box);
        }
        if (profiles.getChildCount() == 0) {
            TextView empty = new TextView(activity);
            empty.setText(R.string.tile_profiles_empty);
            profiles.addView(empty);
        }

        new AlertDialog.Builder(activity)
                .setTitle(R.string.tile_settings_title)
                .setView(view)
                .setPositiveButton(android.R.string.ok, null)
                .setOnDismissListener(dialog -> changed.run())
                .show();
    }

    private static int startRadio(TileScope scope) {
        switch (scope) {
            case IN_USE:
                return R.id.start_in_use;
            case ALL:
                return R.id.start_all;
            default:
                return R.id.start_tile;
        }
    }

    private static TileScope startScope(int radio) {
        if (radio == R.id.start_in_use) {
            return TileScope.IN_USE;
        }
        if (radio == R.id.start_all) {
            return TileScope.ALL;
        }
        return TileScope.TILE;
    }

    private static int stopRadio(TileScope scope) {
        switch (scope) {
            case IN_USE:
                return R.id.stop_in_use;
            case ALL:
                return R.id.stop_all;
            default:
                return R.id.stop_tile;
        }
    }

    private static TileScope stopScope(int radio) {
        if (radio == R.id.stop_in_use) {
            return TileScope.IN_USE;
        }
        if (radio == R.id.stop_all) {
            return TileScope.ALL;
        }
        return TileScope.TILE;
    }
}
