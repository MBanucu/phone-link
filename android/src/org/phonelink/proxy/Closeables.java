package org.phonelink.proxy;

import java.io.Closeable;
import java.io.IOException;

/** Closing that never throws; shared so the protocol code stays Android-free. */
final class Closeables {

    private Closeables() {
    }

    static void closeQuietly(Closeable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (IOException ignored) {
            // Closing is best effort; the caller already has the failure it cares about.
        }
    }
}
