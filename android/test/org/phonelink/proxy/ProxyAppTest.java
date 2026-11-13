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

        test("the summary says what a configuration holds, without the password", () -> {
            ProxyConfig config =
                    ProxyConfig.of(1081, "proxy", "s3cret", "PhoneLink", false, false);
            assertEqual("port 1081 · SSID PhoneLink · user proxy", config.summary(),
                    "summary");
            ProxyConfig open = ProxyConfig.of(1081, "", "", "", true, true);
            assertEqual("port 1081 · any network · no authentication", open.summary(),
                    "anonymous summary");
        });

        test("the help text an agent reads names the whole adb contract", () -> {
            String text = Help.text();
            for (String extra : List.of("--ei port", "--es user", "--es password",
                    "--es ssid", "--ez anonymous", "--ez any_network",
                    "--ez auto_start", "--ez adb_wifi", "--es profile")) {
                assertTrue(text.contains(extra), "help does not mention " + extra);
            }
            assertTrue(text.contains("org.phonelink.proxy.action.START"), "no start action");
            assertTrue(text.contains("org.phonelink.proxy.action.STOP"), "no stop action");
            assertTrue(text.contains("org.phonelink.proxy.action.SAVE_PROFILE"),
                    "no save-profile action");
            assertTrue(text.contains("org.phonelink.proxy.action.DELETE_PROFILE"),
                    "no delete-profile action");
            // The panel and the service print this same text, so the command
            // that reaches it from adb has to be in it.
            assertTrue(text.contains(Help.ADB_DUMP), "help does not say how to print it");
        });

        test("the traffic counters and the window the sparkline draws", () -> {
            Traffic counts = new Traffic();
            counts.add(100, 1000);
            counts.add(50, 500);
            long[] totals = counts.totals();
            assertEqual(150, (int) totals[0], "uploaded");
            assertEqual(1500, (int) totals[1], "downloaded");
            long[] rates = counts.sample();
            assertEqual(150, (int) rates[0], "upload rate");
            assertEqual(1500, (int) rates[1], "download rate");
            // A sample closes the interval that just ended, so the next one is
            // quiet unless more bytes arrived in between.
            counts.add(10, 750);
            counts.sample();
            long[][] history = counts.history();
            assertEqual(2, history[0].length, "two intervals");
            assertEqual(750, (int) history[1][1], "newest download interval");
            assertEqual(10, (int) history[0][1], "newest upload interval");
            assertEqual(1500, (int) history[1][0], "the interval before it");
            counts.reset();
            assertEqual(0, counts.history()[0].length, "reset empties the window");
            assertEqual(0, (int) counts.totals()[1], "reset zeroes the totals");
            // Counters belong to a listener, so a second one starts at zero
            // however busy the first is.
            assertEqual(0, (int) new Traffic().totals()[1], "a new listener starts empty");
            assertEqual("512 B", Traffic.human(512), "bytes");
            assertEqual("1.5 kB", Traffic.human(1500), "kilobytes");
            assertEqual("2.0 MB", Traffic.human(2_000_000), "megabytes");
        });

        test("the event log keeps the newest entries and forgets the rest", () -> {
            EventLog.clear();
            for (int i = 0; i < 205; i++) {
                EventLog.add("event " + i);
            }
            List<String> entries = EventLog.newestFirst();
            assertEqual(200, entries.size(), "ring size");
            assertTrue(entries.get(0).endsWith("event 204"), "newest first");
            assertTrue(entries.get(199).endsWith("event 5"), "oldest kept");
            AtomicInteger seen = new AtomicInteger();
            Runnable listener = seen::incrementAndGet;
            EventLog.addListener(listener);
            EventLog.add("one more");
            EventLog.removeListener(listener);
            EventLog.clear();
            assertEqual(1, seen.get(), "the page is told once");
            assertEqual(0, EventLog.newestFirst().size(), "clear empties it");
        });

        test("the log keeps a proxy's events apart from the app's", () -> {
            EventLog.clear();
            EventLog.setActiveTag("hotel");
            EventLog.add("listening on 0.0.0.0:1080 \u00b7 0 clients");
            EventLog.addTo("home", "saved configuration \"home\"");
            EventLog.setActiveTag(null);
            EventLog.add("wireless debugging managed by the app");

            List<String> hotel = EventLog.forProfile("hotel");
            assertEqual(1, hotel.size(), "the running proxy's own event");
            assertTrue(hotel.get(0).endsWith("listening on 0.0.0.0:1080 \u00b7 0 clients"),
                    "with its line");
            assertEqual(1, EventLog.forProfile("home").size(), "a saved proxy's event");
            assertEqual(0, EventLog.forProfile("nothing").size(), "no events for a stranger");
            assertEqual(3, EventLog.newestFirst().size(), "everything at once");
            // The app's own event is not charged to the proxy that ran before it.
            assertTrue(EventLog.forProfile("hotel").get(0).contains("listening"),
                    "the tag is not sticky");
            EventLog.clear();
            assertEqual(0, EventLog.forProfile(null).size(), "clear empties every view");
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

        test("state text names the proxy it is about", () -> {
            // The line under a proxy is about the proxy on the page, so it does
            // not repeat its name; the notification, which may hold several,
            // names the one it is talking about.
            assertEqual("listening on 0.0.0.0:1081 \u00b7 2 clients",
                    ProxyState.listening("laptop", 1081, 2).describe(), "named listener");
            assertEqual("not listening: on \"FRITZ\"",
                    ProxyState.paused("laptop", "on \"FRITZ\"").describe(), "named pause");
            assertEqual("\"laptop\" on 1081", ProxyState.listening("laptop", 1081, 0).label(),
                    "label of a listener");
            assertEqual("port 1081", ProxyState.listening(1081, 0).label(),
                    "label of an unnamed one");
            assertEqual("\"b\" paused", ProxyState.paused("b", "on another network").label(),
                    "label of a paused one");
            // One proxy in the notification says everything about itself, and
            // several are counted and named.
            assertEqual("\"a\" listening on 0.0.0.0:1080 \u00b7 0 clients",
                    ProxyState.summary(Arrays.asList(
                            ProxyState.listening("a", 1080, 0))), "one proxy");
            assertEqual("2 proxies: \"a\" on 1080, \"b\" paused",
                    ProxyState.summary(Arrays.asList(
                            ProxyState.listening("a", 1080, 0),
                            ProxyState.paused("b", "on another network"))), "two proxies");
            assertEqual("not listening", ProxyState.summary(new ArrayList<>()), "none");
        });

        test("the footer says what a start would do", () -> {
            // Nothing running: the plain stopped line.
            assertEqual("NOTHING", String.valueOf(
                    ProxyState.footer(new ArrayList<>(), 1080)), "nothing running");
            // Another proxy on another port: a start adds this one.
            assertEqual("BESIDE", String.valueOf(ProxyState.footer(Arrays.asList(
                    ProxyState.listening("laptop", 1081, 0)), 1080)), "another port");
            // A listener already holding this port is the one start replaces.
            assertEqual("REPLACES", String.valueOf(ProxyState.footer(Arrays.asList(
                    ProxyState.listening("laptop", 1081, 0),
                    ProxyState.listening("hotel", 1080, 2)), 1080)), "same port");
            // A port the form has not got right says nothing about replacing it.
            assertEqual("BESIDE", String.valueOf(ProxyState.footer(Arrays.asList(
                    ProxyState.listening("laptop", 1081, 0)), 0)), "no port");
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
            ProxyRuntime.publish(new ArrayList<>());
            List<List<ProxyState>> seen = new ArrayList<>();
            ProxyRuntime.Listener listener = seen::add;
            ProxyRuntime.addListener(listener);
            ProxyRuntime.publish(Arrays.asList(
                    new ProxyRuntime.Proxy(ProxyState.listening("one", 1080, 0), new Traffic())));
            assertEqual(1, seen.size(), "updates seen");
            assertTrue(seen.get(0).get(0).listening, "the state is forwarded");
            ProxyRuntime.removeListener(listener);
            ProxyRuntime.publish(new ArrayList<>());
            assertEqual(1, seen.size(), "updates after removal");
            assertTrue(!ProxyRuntime.state().listening, "the runtime keeps the latest state");
        });

        test("the runtime keeps every running proxy, each with its own counters", () -> {
            Traffic first = new Traffic();
            Traffic second = new Traffic();
            first.add(0, 1000);
            second.add(0, 2000);
            ProxyRuntime.publish(Arrays.asList(
                    new ProxyRuntime.Proxy(ProxyState.listening("one", 1080, 1), first),
                    new ProxyRuntime.Proxy(ProxyState.paused("two", "on another network"), second)));
            assertEqual(2, ProxyRuntime.running().size(), "two running");
            assertEqual(2, ProxyRuntime.states().size(), "two states");
            assertTrue(ProxyRuntime.forName("one") != null, "the first is found by name");
            assertTrue(ProxyRuntime.forName("two").state.running, "a paused one is still running");
            assertTrue(ProxyRuntime.forName("three") == null, "a stranger is not running");
            assertEqual(1000, (int) ProxyRuntime.forName("one").traffic.totals()[1],
                    "the first's bytes");
            assertEqual(2000, (int) ProxyRuntime.forName("two").traffic.totals()[1],
                    "the second's bytes");
            // All of them as one state, with the clients of everything put
            // together: what a caller with no opinion about which proxy means
            // gets. The tile has an opinion, so it uses TilePlan below.
            ProxyState all = ProxyRuntime.state();
            assertTrue(all.running, "something runs");
            assertTrue(all.listening, "something listens");
            assertEqual(1080, all.port, "the port that listens");
            assertEqual(1, all.clients, "the clients of both");
            ProxyRuntime.publish(new ArrayList<>());
            assertTrue(ProxyRuntime.running().isEmpty(), "publishing nothing empties it");
        });

        // --- what the Quick Settings tile starts and stops ------------------

        test("a tile with no settings at all keeps the behaviour it had", () -> {
            TilePlan plan = TilePlan.of(new ArrayList<>(), null, new ArrayList<>(),
                    TileScope.TILE, TileScope.TILE,
                    Arrays.asList(ProxyState.listening("anyone", 1081, 1)));
            assertTrue(plan.fallback, "nothing configured");
            assertTrue(plan.up, "the one that runs is the tile's answer");
            assertTrue(plan.listening, "and it listens");
            assertEqual("", String.join(",", plan.start), "nothing to name");
            assertEqual("", String.join(",", plan.stop), "nothing to name");
        });

        test("two proxies on the tile are started together when none is up", () -> {
            TilePlan plan = TilePlan.of(Arrays.asList("a", "b"), null,
                    Arrays.asList("a", "b"), TileScope.TILE, TileScope.TILE,
                    new ArrayList<>());
            assertTrue(!plan.fallback, "configured");
            assertTrue(!plan.up, "nothing is up");
            assertEqual("a,b", String.join(",", plan.start), "both start");
            assertEqual("", String.join(",", plan.stop), "nothing stops");
        });

        test("a click while one of them listens stops them all", () -> {
            TilePlan plan = TilePlan.of(Arrays.asList("a", "b"), null,
                    Arrays.asList("a", "b"), TileScope.TILE, TileScope.TILE,
                    Arrays.asList(ProxyState.listening("a", 1081, 1)));
            assertTrue(plan.up, "one is up");
            assertTrue(plan.listening, "one listens");
            assertEqual("a,b", String.join(",", plan.stop), "both stop");
            assertEqual("", String.join(",", plan.start), "nothing starts");
        });

        test("a paused proxy on the tile is up, so a click turns the set off", () -> {
            TilePlan plan = TilePlan.of(Arrays.asList("a", "b"), null,
                    Arrays.asList("a", "b"), TileScope.TILE, TileScope.TILE,
                    Arrays.asList(ProxyState.paused("a", "on another network")));
            assertTrue(plan.up, "one is up");
            assertTrue(!plan.listening, "none listens");
            assertEqual("a,b", String.join(",", plan.stop), "both stop");
        });

        test("a proxy that is not on the tile is not the tile's business", () -> {
            TilePlan plan = TilePlan.of(Arrays.asList("a"), null, Arrays.asList("a", "other"),
                    TileScope.TILE, TileScope.TILE,
                    Arrays.asList(ProxyState.listening("other", 1090, 2)));
            assertTrue(!plan.up, "somebody else's proxy is not this switch");
            assertTrue(!plan.listening, "so the tile is not on");
            assertEqual("a", String.join(",", plan.start), "the one on the tile starts");
            assertEqual("", String.join(",", plan.stop), "and the other is not stopped");
        });

        test("a stop side alone cannot make a tile that never turns on", () -> {
            // Stop everything, bound to nothing: the tile has nothing to start
            // from its settings, so it starts what it always did.
            TilePlan plan = TilePlan.of(new ArrayList<>(), null, Arrays.asList("a"),
                    TileScope.TILE, TileScope.ALL, new ArrayList<>());
            assertTrue(plan.fallback, "the fallback is what starts something");
            assertTrue(!plan.stopAll, "and the stop side is not an action on its own");
        });

        test("the start side can mean every saved proxy", () -> {
            TilePlan plan = TilePlan.of(new ArrayList<>(), null, Arrays.asList("a", "b"),
                    TileScope.ALL, TileScope.TILE, new ArrayList<>());
            assertTrue(!plan.fallback, "every saved proxy is a setting");
            assertEqual("a,b", String.join(",", plan.start), "all of them start");
        });

        test("the stop side can mean everything, which is a stop with no name", () -> {
            TilePlan plan = TilePlan.of(Arrays.asList("a"), null, Arrays.asList("a", "b"),
                    TileScope.TILE, TileScope.ALL,
                    Arrays.asList(ProxyState.listening("a", 1081, 1)));
            assertTrue(plan.stopAll, "one stop for all of them");
            assertEqual("", String.join(",", plan.stop), "no names needed");
        });

        test("the proxy in use is a scope only while a saved proxy holds that name", () -> {
            TilePlan plan = TilePlan.of(new ArrayList<>(), "gone", Arrays.asList("a"),
                    TileScope.IN_USE, TileScope.TILE, new ArrayList<>());
            assertTrue(plan.fallback, "the mark points at nothing, so the tile falls back");
            TilePlan kept = TilePlan.of(new ArrayList<>(), "a", Arrays.asList("a"),
                    TileScope.IN_USE, TileScope.TILE, new ArrayList<>());
            assertEqual("a", String.join(",", kept.start), "the one in use starts");
        });

        test("a stored scope no build knows is the narrow one", () -> {
            assertEqual("TILE", TileScope.named("nonsense", TileScope.TILE).name(),
                    "unrecognised");
            assertEqual("TILE", TileScope.named(null, TileScope.TILE).name(), "missing");
            assertEqual("ALL", TileScope.named("ALL", TileScope.TILE).name(), "stored");
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
        private final Traffic traffic = new Traffic();
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
                    traffic,
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
