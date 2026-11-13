package org.phonelink.proxy;

import android.app.Activity;
import android.util.TypedValue;

/** The theme's accent, for the one button on a screen that does something. */
final class Accent {

    private Accent() {
    }

    static int of(Activity activity) {
        TypedValue value = new TypedValue();
        activity.getTheme().resolveAttribute(android.R.attr.colorAccent, value, true);
        return value.data;
    }
}
