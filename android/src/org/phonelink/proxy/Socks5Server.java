package org.phonelink.proxy;

import java.io.Closeable;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.ByteArrayOutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * A SOCKS5 server (RFC 1928) with username/password authentication (RFC 1929).
 *
 * <p>Only {@code CONNECT} is implemented; {@code BIND} and {@code UDP ASSOCIATE}
 * are refused with {@code command not supported}, which is what the tunnel needs
 * and what keeps the surface small.
 *
 * <p>It listens on the wildcard address, so the port is the same on the hotspot
 * ({@code ap0}), USB tether ({@code rndis0}) and the AP link ({@code wlan0}),
 * whatever addresses those interfaces get and whenever they appear.
 *
 * <p>Deliberately free of Android types: the logger and the upstream are seams,
 * so this class and its tests run on a plain JDK.
 */
final class Socks5Server implements Closeable {

    static final int REPLY_SUCCEEDED = 0x00;
    static final int REPLY_GENERAL_FAILURE = 0x01;
    static final int REPLY_NETWORK_UNREACHABLE = 0x03;
    static final int REPLY_HOST_UNREACHABLE = 0x04;
    static final int REPLY_CONNECTION_REFUSED = 0x05;
    static final int REPLY_COMMAND_NOT_SUPPORTED = 0x07;
    static final int REPLY_ADDRESS_TYPE_NOT_SUPPORTED = 0x08;

    private static final int VERSION = 0x05;
    private static final int METHOD_NO_AUTH = 0x00;
    private static final int METHOD_USER_PASSWORD = 0x02;
    private static final int METHOD_NONE_ACCEPTABLE = 0xFF;
    private static final int COMMAND_CONNECT = 0x01;
    private static final int ADDRESS_IPV4 = 0x01;
    private static final int ADDRESS_DOMAIN = 0x03;
    private static final int ADDRESS_IPV6 = 0x04;

    private static final int HANDSHAKE_TIMEOUT_MS = 30_000;
    private static final int CONNECT_TIMEOUT_MS = 15_000;

    /** Called from connection threads. */
    interface Listener {
        void onClientsChanged(int clients);
    }

    /** Where diagnostics go on the phone; the tests pass a no-op. */
    interface Logger {
        void log(String message);
    }

    private static final class Request {
        final int command;
        final String host;
        final int port;

        Request(int command, String host, int port) {
            this.command = command;
            this.host = host;
            this.port = port;
        }
    }

    private final int port;
    private final String user;
    private final String password;
    private final Upstream upstream;
    private final Listener listener;
    private final Logger logger;
    private final AtomicInteger clients = new AtomicInteger();

    private final ExecutorService handlers = Executors.newCachedThreadPool();
    private volatile ServerSocket server;
    private volatile boolean running;

    /** the bound port, or 0 when the server is not listening */
    int port() {
        ServerSocket socket = server;
        return socket == null ? 0 : socket.getLocalPort();
    }

    Socks5Server(
            int port,
            String user,
            String password,
            Upstream upstream,
            Listener listener,
            Logger logger) {
        this.port = port;
        this.user = user;
        this.password = password;
        this.upstream = upstream;
        this.listener = listener;
        this.logger = logger;
    }

    private void log(String message) {
        if (logger != null) {
            logger.log(message);
        }
    }

    /** Bind and start accepting. Throws if the port is taken. */
    void start() throws IOException {
        ServerSocket socket = new ServerSocket();
        socket.setReuseAddress(true);
        socket.bind(new InetSocketAddress(port), 50);
        server = socket;
        running = true;
        Thread acceptor = new Thread(this::acceptLoop, "socks5-accept");
        acceptor.setDaemon(true);
        acceptor.start();
    }

    private void acceptLoop() {
        while (running) {
            Socket client;
            try {
                client = server.accept();
            } catch (IOException e) {
                if (running) {
                    log("accept failed: " + e.getMessage());
                    continue;
                }
                return;
            }
            handlers.execute(() -> handle(client));
        }
    }

    private void handle(Socket client) {
        int count = clients.incrementAndGet();
        listener.onClientsChanged(count);
        Socket connected = null;
        try {
            client.setSoTimeout(HANDSHAKE_TIMEOUT_MS);
            client.setTcpNoDelay(true);
            DataInputStream in = new DataInputStream(client.getInputStream());
            OutputStream out = client.getOutputStream();

            if (!negotiate(in, out)) {
                return;
            }
            Request request = readRequest(in, out);
            if (request == null) {
                return;
            }
            if (request.command != COMMAND_CONNECT) {
                writeReply(out, REPLY_COMMAND_NOT_SUPPORTED, null);
                return;
            }
            try {
                connected = upstream.connect(request.host, request.port, CONNECT_TIMEOUT_MS);
            } catch (Upstream.Failure failure) {
                log(failure.getMessage());
                writeReply(out, failure.reply, null);
                return;
            }
            writeReply(out, REPLY_SUCCEEDED, connected);
            client.setSoTimeout(0);
            relay(client, connected);
        } catch (IOException e) {
            log("connection ended: " + e.getMessage());
        } finally {
            Closeables.closeQuietly(connected);
            Closeables.closeQuietly(client);
            listener.onClientsChanged(clients.decrementAndGet());
        }
    }

    /** Method negotiation; returns false when the client cannot be served. */
    private boolean negotiate(DataInputStream in, OutputStream out) throws IOException {
        if (in.readUnsignedByte() != VERSION) {
            return false;
        }
        int offered = in.readUnsignedByte();
        byte[] methods = new byte[offered];
        in.readFully(methods);

        boolean authenticate = !user.isEmpty() && !password.isEmpty();
        int chosen = -1;
        for (byte method : methods) {
            int value = method & 0xFF;
            if (authenticate ? value == METHOD_USER_PASSWORD : value == METHOD_NO_AUTH) {
                chosen = value;
                break;
            }
        }
        if (chosen < 0) {
            out.write(new byte[] {VERSION, (byte) METHOD_NONE_ACCEPTABLE});
            out.flush();
            return false;
        }
        out.write(new byte[] {VERSION, (byte) chosen});
        out.flush();
        return chosen != METHOD_USER_PASSWORD || authenticate(in, out);
    }

    private boolean authenticate(DataInputStream in, OutputStream out) throws IOException {
        if (in.readUnsignedByte() != 0x01) {
            return false;
        }
        byte[] givenUser = new byte[in.readUnsignedByte()];
        in.readFully(givenUser);
        byte[] givenPassword = new byte[in.readUnsignedByte()];
        in.readFully(givenPassword);

        boolean userMatches =
                MessageDigest.isEqual(givenUser, user.getBytes(StandardCharsets.UTF_8));
        boolean passwordMatches =
                MessageDigest.isEqual(givenPassword, password.getBytes(StandardCharsets.UTF_8));
        // Both comparisons always run, so a wrong user does not answer faster
        // than a wrong password.
        boolean granted = userMatches & passwordMatches;

        out.write(new byte[] {0x01, (byte) (granted ? 0x00 : 0x01)});
        out.flush();
        if (!granted) {
            log("rejected a client with bad credentials");
        }
        return granted;
    }

    private Request readRequest(DataInputStream in, OutputStream out) throws IOException {
        if (in.readUnsignedByte() != VERSION) {
            return null;
        }
        int command = in.readUnsignedByte();
        in.readUnsignedByte(); // reserved
        int addressType = in.readUnsignedByte();

        String host;
        switch (addressType) {
            case ADDRESS_IPV4:
            case ADDRESS_IPV6:
                byte[] address = new byte[addressType == ADDRESS_IPV4 ? 4 : 16];
                in.readFully(address);
                host = InetAddress.getByAddress(address).getHostAddress();
                break;
            case ADDRESS_DOMAIN:
                byte[] name = new byte[in.readUnsignedByte()];
                in.readFully(name);
                host = new String(name, StandardCharsets.UTF_8);
                if (host.isEmpty()) {
                    writeReply(out, REPLY_GENERAL_FAILURE, null);
                    return null;
                }
                break;
            default:
                writeReply(out, REPLY_ADDRESS_TYPE_NOT_SUPPORTED, null);
                return null;
        }
        int port = in.readUnsignedShort();
        return new Request(command, host, port);
    }

    private static void writeReply(OutputStream out, int reply, Socket bound) throws IOException {
        byte[] address = new byte[4];
        int port = 0;
        if (bound != null) {
            InetAddress local = bound.getLocalAddress();
            if (local != null) {
                address = local.getAddress();
            }
            port = bound.getLocalPort();
        }
        ByteArrayOutputStream replyBytes = new ByteArrayOutputStream(22);
        replyBytes.write(VERSION);
        replyBytes.write(reply);
        replyBytes.write(0x00);
        replyBytes.write(address.length == 16 ? ADDRESS_IPV6 : ADDRESS_IPV4);
        replyBytes.write(address, 0, address.length);
        replyBytes.write((port >> 8) & 0xFF);
        replyBytes.write(port & 0xFF);
        out.write(replyBytes.toByteArray());
        out.flush();
    }

    /** Shovel bytes both ways until both directions are done, then close. */
    private static void relay(Socket client, Socket upstream) {
        CountDownLatch done = new CountDownLatch(2);
        pump(client, upstream, done);
        pump(upstream, client, done);
        try {
            done.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        Closeables.closeQuietly(client);
        Closeables.closeQuietly(upstream);
    }

    private static void pump(Socket from, Socket to, CountDownLatch done) {
        Thread thread = new Thread(() -> {
            byte[] buffer = new byte[32 * 1024];
            try {
                InputStream in = from.getInputStream();
                OutputStream out = to.getOutputStream();
                int read;
                while ((read = in.read(buffer)) != -1) {
                    out.write(buffer, 0, read);
                }
                // Half close: the other direction may still have data to deliver.
                to.shutdownOutput();
            } catch (IOException e) {
                // One side is gone; closing both unblocks the other pump.
                Closeables.closeQuietly(from);
                Closeables.closeQuietly(to);
            } finally {
                done.countDown();
            }
        }, "socks5-relay");
        thread.setDaemon(true);
        thread.start();
    }

    @Override
    public void close() {
        running = false;
        Closeables.closeQuietly(server);
        server = null;
        handlers.shutdownNow();
    }
}
