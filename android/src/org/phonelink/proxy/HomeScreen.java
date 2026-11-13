package org.phonelink.proxy;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.TextView;

import java.util.List;

/**
 * The list page: every saved proxy as a card, the state it is in, and its own
 * Start/Stop — which is what the app is for.
 *
 * <p>Asked for by the activity, which keeps what a press means: this renders the
 * cards from the store and the live state, and says which card was opened or
 * pressed. Every card is rebuilt only when the store changes; a connection only
 * refreshes the parts that move, so a busy proxy does not rebuild the list.
 */
final class HomeScreen {

    /** What a card does when it is touched. */
    interface Actions {
        void open(String name);

        void toggle(String name);
    }

    private final Activity activity;
    private final ViewGroup list;
    private final View empty;
    private final Actions actions;

    HomeScreen(Activity activity, ViewGroup list, View empty, Actions actions) {
        this.activity = activity;
        this.list = list;
        this.empty = empty;
        this.actions = actions;
    }

    /** Every saved proxy, in the store's order, with the button each one needs. */
    void render() {
        List<String> names = ConfigStore.profileNames(activity);
        list.removeAllViews();
        empty.setVisibility(names.isEmpty() ? View.VISIBLE : View.GONE);
        for (String name : names) {
            ProxyConfig config = ConfigStore.profile(activity, name);
            if (config == null) {
                continue;
            }
            View card = activity.getLayoutInflater()
                    .inflate(R.layout.item_profile, list, false);
            card.setTag(name);
            ((TextView) card.findViewById(R.id.card_name)).setText(name);
            ((TextView) card.findViewById(R.id.card_summary)).setText(config.summary());
            ((TextView) card.findViewById(R.id.card_flags)).setText(activity.getString(
                    R.string.card_flags,
                    ConfigStore.profileAutoStart(activity, name) ? "on" : "off",
                    ConfigStore.profileAdbWireless(activity, name) ? "on" : "off"));
            card.setOnClickListener(view -> actions.open(name));
            card.findViewById(R.id.card_toggle).setOnClickListener(
                    view -> actions.toggle(name));
            list.addView(card);
        }
        refresh();
    }

    /**
     * A card's state is that proxy's own state: every saved proxy with a
     * listener behind it follows the service, the rest are stopped — and more
     * than one can be running, which is what the list is for.
     */
    void refresh() {
        for (int index = 0; index < list.getChildCount(); index++) {
            View card = list.getChildAt(index);
            Object tag = card.getTag();
            String name = tag == null ? null : tag.toString();
            ProxyRuntime.Proxy live = ProxyRuntime.forName(name);
            ProxyState state = live == null ? ProxyState.stopped(name) : live.state;
            boolean mine = live != null;
            int label;
            int color;
            if (state.listening) {
                label = R.string.state_running;
                color = R.color.running;
            } else if (mine && state.running) {
                label = R.string.state_waiting;
                color = R.color.waiting;
            } else {
                label = R.string.state_stopped;
                color = R.color.traffic_base;
            }
            TextView badge = card.findViewById(R.id.card_state);
            badge.setText(label);
            badge.setTextColor(activity.getColor(color));
            card.findViewById(R.id.card_dot).setBackgroundTintList(
                    ColorStateList.valueOf(activity.getColor(color)));
            ProxyConfig config = name == null ? null : ConfigStore.profile(activity, name);
            if (config != null) {
                ((TextView) card.findViewById(R.id.card_summary)).setText(mine && state.running
                        ? activity.getString(R.string.card_in_use, config.summary())
                        : config.summary());
            }
            Button startStop = card.findViewById(R.id.card_toggle);
            boolean running = mine && state.running;
            startStop.setText(running ? R.string.action_stop : R.string.action_start);
            startStop.setBackgroundTintList(ColorStateList.valueOf(
                    running ? activity.getColor(R.color.traffic_base) : Accent.of(activity)));
            startStop.setTextColor(activity.getColor(android.R.color.white));
        }
    }
}
