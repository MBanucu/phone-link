package org.phonelink.proxy;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Hermetic tests for the app's Android-free logic: the SOCKS5 handshake,
 * authentication and relay, the configuration rules and the state text the
 * panel and the notification show.
 *
 * <p>Plain JDK: no phone, no Android SDK, no test framework. The server binds an
 * ephemeral port on loopback and the upstream is a recording fake pointed at a
 * local echo socket, so the suite runs in a sandbox.
 *
 * <p>{@code bash tests/proxy-app.test.sh} compiles and runs it.
 */
public final class ProxyAppTest {

    private static final String USER = "proxy";
    private static final String PASSWORD = "s3cret";
    private static final int TIMEOUT_MS = 3_000;

    private static int passed;
    private static int failed;

    public static void main(String[] args) throws Exception {
        test("a client offering only no-auth is refused when credentials are set", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                greet(socket, 0x00);
                assertEqual(0xFF, readMethod(socket), "selected method");
                assertEqual(-1, socket.getInputStream().read(), "connection closed");
            }
        });

        test("when both methods are offered, user/password wins", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                greet(socket, 0x00, 0x02);
                assertEqual(0x02, readMethod(socket), "selected method");
            }
        });

        test("correct credentials are accepted", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                greet(socket, 0x02);
                assertEqual(0x02, readMethod(socket), "selected method");
                assertTrue(authenticate(socket, USER, PASSWORD), "credentials refused");
            }
        });

        test("a wrong password is rejected and the connection ends", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                greet(socket, 0x02);
                assertEqual(0x02, readMethod(socket), "selected method");
                assertTrue(!authenticate(socket, USER, "wrong"), "wrong password accepted");
                assertEqual(-1, socket.getInputStream().read(), "connection closed");
            }
        });

        test("a wrong user is rejected", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                greet(socket, 0x02);
                assertEqual(0x02, readMethod(socket), "selected method");
                assertTrue(!authenticate(socket, "someone", PASSWORD), "wrong user accepted");
            }
        });

        test("without credentials the server serves CONNECT unauthenticated", () -> {
            try (Fixture fixture = new Fixture("", "", null); Socket socket = fixture.open()) {
                greet(socket, 0x00);
                assertEqual(0x00, readMethod(socket), "selected method");
                requestConnect(socket, 0x01, 0x01, "127.0.0.1", 80);
                assertEqual(0x00, readReply(socket), "reply code");
            }
        });

        test("CONNECT relays bytes in both directions", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                handshake(socket);
                requestConnect(socket, 0x01, 0x01, "127.0.0.1", 80);
                assertEqual(0x00, readReply(socket), "reply code");

                byte[] payload = new byte[32 * 1024];
                for (int i = 0; i < payload.length; i++) {
                    payload[i] = (byte) (i * 31);
                }
                socket.getOutputStream().write(payload);
                socket.getOutputStream().flush();
                byte[] echoed = readFully(socket.getInputStream(), payload.length);
                assertTrue(Arrays.equals(payload, echoed), "echoed bytes differ");
            }
        });

        test("half close is forwarded to the upstream", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                handshake(socket);
                requestConnect(socket, 0x01, 0x01, "127.0.0.1", 80);
                assertEqual(0x00, readReply(socket), "reply code");

                socket.getOutputStream().write("ping".getBytes(StandardCharsets.UTF_8));
                socket.getOutputStream().flush();
                socket.shutdownOutput();
                assertEqual("ping", new String(readFully(socket.getInputStream(), 4),
                        StandardCharsets.UTF_8), "echo after half close");
                assertEqual(-1, socket.getInputStream().read(), "end of stream");
            }
        });

        test("a domain name reaches the upstream unresolved", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                handshake(socket);
                requestConnect(socket, 0x01, 0x03, "example.test", 443);
                assertEqual(0x00, readReply(socket), "reply code");
                assertEqual("example.test", fixture.upstream.host, "host passed upstream");
                assertEqual(443, fixture.upstream.port, "port passed upstream");
            }
        });

        test("BIND is refused with command-not-supported", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                handshake(socket);
                requestConnect(socket, 0x02, 0x01, "127.0.0.1", 80);
                assertEqual(Socks5Server.REPLY_COMMAND_NOT_SUPPORTED, readReply(socket), "reply code");
            }
        });

        test("an unknown address type is refused", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                handshake(socket);
                byte[] request = {0x05, 0x01, 0x00, 0x02, 0x00, 0x50};
                socket.getOutputStream().write(request);
                socket.getOutputStream().flush();
                assertEqual(
                        Socks5Server.REPLY_ADDRESS_TYPE_NOT_SUPPORTED, readReply(socket), "reply code");
            }
        });

        test("an upstream failure reply is forwarded", () -> {
            Upstream failing = (host, port, timeoutMs) -> {
                throw new Upstream.Failure(Socks5Server.REPLY_CONNECTION_REFUSED, "refused");
            };
            try (Fixture fixture = new Fixture(USER, PASSWORD, failing);
                    Socket socket = fixture.open()) {
                handshake(socket);
                requestConnect(socket, 0x01, 0x01, "127.0.0.1", 80);
                assertEqual(Socks5Server.REPLY_CONNECTION_REFUSED, readReply(socket), "reply code");
            }
        });

        test("clients are counted up and down", () -> {
            try (Fixture fixture = new Fixture()) {
                Socket socket = fixture.open();
                handshake(socket);
                requestConnect(socket, 0x01, 0x01, "127.0.0.1", 80);
                assertEqual(0x00, readReply(socket), "reply code");
                assertEqual(1, fixture.clients.get(), "connected clients");
                socket.close();
                long deadline = System.currentTimeMillis() + TIMEOUT_MS;
                while (fixture.clients.get() != 0 && System.currentTimeMillis() < deadline) {
                    Thread.sleep(20);
                }
                assertEqual(0, fixture.clients.get(), "connected clients after close");
            }
        });

        test("a non-SOCKS greeting closes the connection", () -> {
            try (Fixture fixture = new Fixture(); Socket socket = fixture.open()) {
                socket.getOutputStream().write(new byte[] {0x04, 0x01, 0x00});
                socket.getOutputStream().flush();
                assertEqual(-1, socket.getInputStream().read(), "connection closed");
            }
        });

        // --- configuration -------------------------------------------------

        test("defaults are port 1080, no credentials and PhoneLink", () -> {
            ProxyConfig config = ProxyConfig.defaults();
            assertEqual(1080, config.port, "default port");
            assertEqual("PhoneLink", config.ssid, "default SSID");
            assertEqual("", config.user, "default user");
            assertTrue(!config.anyNetwork, "any_network is off by default");
            assertTrue(!config.anonymous, "authentication is on by default");
        });

        test("a port outside 1024..65535 is rejected", () -> {
            expectRejected("port 80", () ->
                    ProxyConfig.of(80, "proxy", "s3cret", "PhoneLink", false, false));
            expectRejected("port 70000", () ->
                    ProxyConfig.of(70000, "proxy", "s3cret", "PhoneLink", false, false));
        });

        test("credentials are required unless anonymous", () -> {
            expectRejected("empty user and password", () ->
                    ProxyConfig.of(1080, "", "", "PhoneLink", false, false));
            expectRejected("a password without a user", () ->
                    ProxyConfig.of(1080, "", "s3cret", "PhoneLink", false, false));
        });

        test("anonymous clears stale credentials", () -> {
            ProxyConfig config = ProxyConfig.of(1080, "proxy", "s3cret", "PhoneLink", false, true);
            assertTrue(config.anonymous, "anonymous is kept");
            assertEqual("", config.user, "user cleared");
            assertEqual("", config.password, "password cleared");
        });

        test("a credential longer than 255 bytes is rejected", () -> {
            char[] tooLong = new char[256];
            Arrays.fill(tooLong, 'x');
            expectRejected("a 256-byte password", () ->
                    ProxyConfig.of(1080, "proxy", new String(tooLong), "PhoneLink", false, false));
        });

        test("an empty SSID is rejected unless any_network is set", () -> {
            expectRejected("an empty SSID", () ->
                    ProxyConfig.of(1080, "proxy", "s3cret", "", false, false));
            ProxyConfig config = ProxyConfig.of(1080, "proxy", "s3cret", "", true, false);
            assertTrue(config.anyNetwork, "any_network is kept");
        });

        test("valid settings pass through unchanged", () -> {
            ProxyConfig config = ProxyConfig.of(1081, "proxy", "s3cret", "PhoneLink", false, false);
            assertEqual(1081, config.port, "port");
            assertEqual("proxy", config.user, "user");
            assertEqual("s3cret", config.password, "password");
            assertEqual("PhoneLink", config.ssid, "SSID");
        });

        // --- state text ----------------------------------------------------

        test("the listening text counts clients", () -> {
            assertEqual("listening on 0.0.0.0:1080 \u00b7 0 clients",
                    ProxyState.listening(1080, 0).describe(), "no clients");
            assertEqual("listening on 0.0.0.0:1080 \u00b7 1 client",
                    ProxyState.listening(1080, 1).describe(), "one client");
            assertEqual("listening on 0.0.0.0:1080 \u00b7 3 clients",
                    ProxyState.listening(1080, 3).describe(), "three clients");
        });

        test("the paused and stopped text explain themselves", () -> {
            assertEqual("not listening: on \"FRITZ\", not \"PhoneLink\"",
                    ProxyState.paused("on \"FRITZ\", not \"PhoneLink\"").describe(), "paused");
            assertEqual("not listening: stopped", ProxyState.stopped().describe(), "stopped");
            assertEqual("not listening: waiting for an allowed network",
                    ProxyState.waiting().describe(), "waiting");
        });

        test("running separates a paused service from a stopped one", () -> {
            assertTrue(!ProxyState.stopped().running, "stopped is not running");
            assertTrue(ProxyState.waiting().running, "waiting is running");
            assertTrue(ProxyState.paused("on another network").running, "paused is running");
            assertTrue(ProxyState.listening(1080, 0).running, "listening is running");
            assertTrue(!ProxyState.stopped().listening, "stopped is not listening");
        });

        // --- runtime -------------------------------------------------------

        test("the runtime forwards state to listeners until they leave", () -> {
            ProxyRuntime.publish(ProxyState.stopped());
            List<ProxyState> seen = new ArrayList<>();
            ProxyRuntime.Listener listener = seen::add;
            ProxyRuntime.addListener(listener);
            ProxyRuntime.publish(ProxyState.listening(1080, 0));
            assertEqual(1, seen.size(), "updates seen");
            assertTrue(seen.get(0).listening, "the state is forwarded");
            ProxyRuntime.removeListener(listener);
            ProxyRuntime.publish(ProxyState.stopped());
            assertEqual(1, seen.size(), "updates after removal");
            assertTrue(!ProxyRuntime.state().listening, "the runtime keeps the latest state");
        });

        System.out.printf("%n%d passed, %d failed%n", passed, failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // --- harness -----------------------------------------------------------

    private interface Case {
        void run() throws Exception;
    }

    private static void test(String name, Case body) {
        try {
            body.run();
            passed++;
            System.out.println("ok   " + name);
        } catch (Throwable e) {
            failed++;
            System.out.println("FAIL " + name + ": " + e);
        }
    }

    private static void assertTrue(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static void assertEqual(int expected, int actual, String what) {
        if (expected != actual) {
            throw new AssertionError(what + ": expected " + expected + " but was " + actual);
        }
    }

    private static void assertEqual(String expected, String actual, String what) {
        if (!expected.equals(actual)) {
            throw new AssertionError(what + ": expected \"" + expected + "\" but was \"" + actual + "\"");
        }
    }

    private static void expectRejected(String what, Runnable action) {
        try {
            action.run();
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError(what + " was accepted");
    }

    // --- protocol client ---------------------------------------------------

    private static void greet(Socket socket, int... methods) throws IOException {
        OutputStream out = socket.getOutputStream();
        out.write(0x05);
        out.write(methods.length);
        for (int method : methods) {
            out.write(method);
        }
        out.flush();
    }

    private static int readMethod(Socket socket) throws IOException {
        DataInputStream in = new DataInputStream(socket.getInputStream());
        assertEqual(0x05, in.readUnsignedByte(), "greeting version");
        return in.readUnsignedByte();
    }

    private static boolean authenticate(Socket socket, String user, String password)
            throws IOException {
        byte[] name = user.getBytes(StandardCharsets.UTF_8);
        byte[] secret = password.getBytes(StandardCharsets.UTF_8);
        ByteArrayOutputStream message = new ByteArrayOutputStream();
        message.write(0x01);
        message.write(name.length);
        message.write(name, 0, name.length);
        message.write(secret.length);
        message.write(secret, 0, secret.length);
        socket.getOutputStream().write(message.toByteArray());
        socket.getOutputStream().flush();

        DataInputStream in = new DataInputStream(socket.getInputStream());
        assertEqual(0x01, in.readUnsignedByte(), "auth version");
        return in.readUnsignedByte() == 0x00;
    }

    private static void handshake(Socket socket) throws IOException {
        greet(socket, 0x02);
        assertEqual(0x02, readMethod(socket), "selected method");
        assertTrue(authenticate(socket, USER, PASSWORD), "credentials refused");
    }

    private static void requestConnect(
            Socket socket, int command, int addressType, String host, int port)
            throws IOException {
        ByteArrayOutputStream request = new ByteArrayOutputStream();
        request.write(0x05);
        request.write(command);
        request.write(0x00);
        request.write(addressType);
        if (addressType == 0x01) {
            for (String part : host.split("\\.")) {
                request.write(Integer.parseInt(part));
            }
        } else if (addressType == 0x03) {
            byte[] name = host.getBytes(StandardCharsets.UTF_8);
            request.write(name.length);
            request.write(name, 0, name.length);
        }
        request.write((port >> 8) & 0xFF);
        request.write(port & 0xFF);
        socket.getOutputStream().write(request.toByteArray());
        socket.getOutputStream().flush();
    }

    private static int readReply(Socket socket) throws IOException {
        DataInputStream in = new DataInputStream(socket.getInputStream());
        assertEqual(0x05, in.readUnsignedByte(), "reply version");
        int code = in.readUnsignedByte();
        in.readUnsignedByte(); // reserved
        int addressType = in.readUnsignedByte();
        switch (addressType) {
            case 0x01:
                in.readFully(new byte[4]);
                break;
            case 0x04:
                in.readFully(new byte[16]);
                break;
            case 0x03:
                in.readFully(new byte[in.readUnsignedByte()]);
                break;
            default:
                throw new AssertionError("unexpected reply address type " + addressType);
        }
        in.readUnsignedShort();
        return code;
    }

    private static byte[] readFully(InputStream in, int length) throws IOException {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length) {
            int read = in.read(buffer, offset, length - offset);
            if (read < 0) {
                throw new AssertionError("stream ended after " + offset + " of " + length + " bytes");
            }
            offset += read;
        }
        return buffer;
    }

    // --- fixtures ----------------------------------------------------------

    private static final class Fixture implements AutoCloseable {
        private final Socks5Server server;
        private final FakeUpstream upstream;
        private final AtomicInteger clients = new AtomicInteger();
        private final int port;

        Fixture() throws IOException {
            this(USER, PASSWORD, null);
        }

        Fixture(String user, String password, Upstream custom) throws IOException {
            upstream = new FakeUpstream();
            server = new Socks5Server(
                    0,
                    user,
                    password,
                    custom == null ? upstream : custom,
                    clients::set,
                    message -> { });
            server.start();
            port = server.port();
        }

        Socket open() throws IOException {
            Socket socket = new Socket("127.0.0.1", port);
            socket.setSoTimeout(TIMEOUT_MS);
            return socket;
        }

        @Override
        public void close() {
            server.close();
            upstream.close();
        }
    }

    /** Records what CONNECT asked for and answers with a local echo socket. */
    private static final class FakeUpstream implements Upstream {
        private final ServerSocket backend;
        private final Thread thread;

        volatile String host;
        volatile int port;
        volatile int timeoutMs;

        FakeUpstream() throws IOException {
            backend = new ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"));
            thread = new Thread(this::serve, "echo-backend");
            thread.setDaemon(true);
            thread.start();
        }

        private void serve() {
            while (!backend.isClosed()) {
                try (Socket socket = backend.accept()) {
                    byte[] buffer = new byte[8 * 1024];
                    InputStream in = socket.getInputStream();
                    OutputStream out = socket.getOutputStream();
                    int read;
                    while ((read = in.read(buffer)) != -1) {
                        out.write(buffer, 0, read);
                    }
                } catch (IOException e) {
                    return;
                }
            }
        }

        @Override
        public Socket connect(String host, int port, int timeoutMs) throws Failure {
            this.host = host;
            this.port = port;
            this.timeoutMs = timeoutMs;
            try {
                Socket socket = new Socket("127.0.0.1", backend.getLocalPort());
                socket.setTcpNoDelay(true);
                return socket;
            } catch (IOException e) {
                throw new Failure(Socks5Server.REPLY_CONNECTION_REFUSED, e.getMessage());
            }
        }

        void close() {
            try {
                backend.close();
            } catch (IOException ignored) {
                // The fixture is done with it.
            }
        }
    }
}
