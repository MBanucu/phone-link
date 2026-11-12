package org.phonelink.proxy;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.util.AttributeSet;
import android.view.View;

/**
 * The sparkline on the Log page: one line per direction, scaled to the busiest
 * sample in the window, so a quiet minute is flat and a burst is visible.
 *
 * <p>No dependencies and no animation: the panel re-samples once a second while
 * it is in front, which is also the resolution of the integer counters.
 */
public final class TrafficView extends View {

    private final Paint up = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint down = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint base = new Paint();
    private final Path path = new Path();

    public TrafficView(Context context, AttributeSet attrs) {
        super(context, attrs);
        up.setStyle(Paint.Style.STROKE);
        up.setStrokeWidth(3f);
        up.setColor(context.getColor(R.color.traffic_up));
        down.setStyle(Paint.Style.STROKE);
        down.setStrokeWidth(3f);
        down.setColor(context.getColor(R.color.traffic_down));
        base.setColor(context.getColor(R.color.traffic_base));
        base.setStrokeWidth(1f);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float width = getWidth();
        float height = getHeight();
        canvas.drawLine(0, height - 1, width, height - 1, base);

        long[][] history = Traffic.history();
        long[] upRates = history[0];
        long[] downRates = history[1];
        long peak = 0;
        for (long rate : upRates) {
            peak = Math.max(peak, rate);
        }
        for (long rate : downRates) {
            peak = Math.max(peak, rate);
        }
        if (upRates.length < 2 || peak <= 0) {
            return;
        }
        draw(canvas, upRates, peak, width, height, up);
        draw(canvas, downRates, peak, width, height, down);
    }

    private void draw(
            Canvas canvas,
            long[] rates,
            long peak,
            float width,
            float height,
            Paint paint) {
        path.reset();
        float step = width / (rates.length - 1);
        for (int i = 0; i < rates.length; i++) {
            float x = i * step;
            float y = height - 2 - (height - 6) * ((float) rates[i] / peak);
            if (i == 0) {
                path.moveTo(x, y);
            } else {
                path.lineTo(x, y);
            }
        }
        canvas.drawPath(path, paint);
    }
}
