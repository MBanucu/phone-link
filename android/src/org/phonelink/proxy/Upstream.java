package org.phonelink.proxy;

import java.net.Socket;

/**
 * Where a CONNECT goes.
 *
 * <p>Implemented by {@link Egress} on the phone and by the hermetic tests on the
 * JVM, which is why this interface carries no Android types: the protocol code
 * can then be compiled and exercised with a plain JDK.
 */
interface Upstream {

    Socket connect(String host, int port, int timeoutMs) throws Failure;

    /** A CONNECT that could not be honoured, carrying the SOCKS5 reply code. */
    final class Failure extends Exception {
        private static final long serialVersionUID = 1L;

        final int reply;

        Failure(int reply, String message) {
            super(message);
            this.reply = reply;
        }
    }
}
