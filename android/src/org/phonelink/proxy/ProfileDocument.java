package org.phonelink.proxy;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The file an export writes and an import reads: every saved proxy, the
 * configuration in use, and the two names that mark it.
 *
 * <p>Plain JSON, written and read here rather than through {@code org.json}, so
 * the format is testable on a JVM without Android and does not change when the
 * platform's library does. Unknown fields are ignored, so a file from a later
 * app still imports what it shares, and a missing field keeps its default,
 * which is what a file written by hand needs.
 *
 * <p>The file holds passwords: it is written where the user pointed the system
 * picker and nowhere else, and the panel says so before it writes one.
 */
final class ProfileDocument {

    static final String APP = "phone-link-proxy";
    static final int VERSION = 1;

    /** One saved proxy: the listener's settings and the switches beside it. */
    static final class Entry {
        String name = "";
        ProxyConfig config = ProxyConfig.defaults();
        boolean autoStart;
        boolean adbWireless = true;
        boolean tile;
    }

    /** Every saved proxy, in the order it was exported. */
    final List<Entry> saved = new ArrayList<>();
    /** The configuration in use when the file was written, if there was one. */
    Entry active;
    /** The saved proxy the app was running, and the one the picker had selected. */
    String inUse = "";
    String selected = "";

    /** The document as JSON, a field per line so a copy can be read by eye. */
    String write() {
        StringBuilder out = new StringBuilder();
        out.append("{\n");
        out.append("  \"app\": ").append(quote(APP)).append(",\n");
        out.append("  \"version\": ").append(VERSION).append(",\n");
        out.append("  \"active\": ")
                .append(active == null ? "null" : writeEntry(active))
                .append(",\n");
        out.append("  \"in_use\": ").append(quote(inUse)).append(",\n");
        out.append("  \"selected\": ").append(quote(selected)).append(",\n");
        out.append("  \"saved\": [");
        for (int index = 0; index < saved.size(); index++) {
            out.append(index == 0 ? "\n" : ",\n");
            out.append("    ").append(writeEntry(saved.get(index)));
        }
        out.append(saved.isEmpty() ? "]\n" : "\n  ]\n");
        out.append("}\n");
        return out.toString();
    }

    /**
     * Read a document.
     *
     * @throws IllegalArgumentException with a message fit for the panel when the
     *     text is not one of ours, or comes from a newer app than this one
     */
    static ProfileDocument parse(String text) {
        Object root = new Reader(text == null ? "" : text).readValue();
        Map<String, Object> object = asObject(root, "the file");
        long version = number(object.get("version"), VERSION);
        if (version > VERSION) {
            throw new IllegalArgumentException(
                    "the file is from a newer version of the app (" + version
                            + "); this app reads up to " + VERSION);
        }
        ProfileDocument document = new ProfileDocument();
        Object active = object.get("active");
        if (active != null) {
            document.active = entry(asObject(active, "active"));
        }
        document.inUse = string(object.get("in_use"), "");
        document.selected = string(object.get("selected"), "");
        Object saved = object.get("saved");
        if (saved != null) {
            for (Object one : asArray(saved, "saved")) {
                ProfileDocument.Entry entry = entry(asObject(one, "a saved proxy"));
                if (!entry.name.isEmpty()) {
                    document.saved.add(entry);
                }
            }
        }
        return document;
    }

    /** What an import writes: the incoming proxies, by name, last one winning. */
    List<Entry> byName() {
        Map<String, Entry> named = new LinkedHashMap<>();
        for (Entry entry : saved) {
            named.put(entry.name, entry);
        }
        return new ArrayList<>(named.values());
    }

    // -- writing -------------------------------------------------------

    private static String writeEntry(Entry entry) {
        return "{\"name\": " + quote(entry.name)
                + ", \"port\": " + entry.config.port
                + ", \"user\": " + quote(entry.config.user)
                + ", \"password\": " + quote(entry.config.password)
                + ", \"ssid\": " + quote(entry.config.ssid)
                + ", \"anonymous\": " + entry.config.anonymous
                + ", \"any_network\": " + entry.config.anyNetwork
                + ", \"auto_start\": " + entry.autoStart
                + ", \"adb_wifi\": " + entry.adbWireless
                + ", \"tile\": " + entry.tile + "}";
    }

    private static String quote(String text) {
        StringBuilder out = new StringBuilder("\"");
        for (int index = 0; index < text.length(); index++) {
            char c = text.charAt(index);
            switch (c) {
                case '"':
                    out.append("\\\"");
                    break;
                case '\\':
                    out.append("\\\\");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                default:
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
            }
        }
        return out.append('"').toString();
    }

    // -- reading -------------------------------------------------------

    private static Entry entry(Map<String, Object> object) {
        Entry entry = new Entry();
        entry.name = string(object.get("name"), "").trim();
        entry.config = ProxyConfig.raw(
                (int) number(object.get("port"), ProxyConfig.DEFAULT_PORT),
                string(object.get("user"), ""),
                string(object.get("password"), ""),
                string(object.get("ssid"), ProxyConfig.DEFAULT_SSID),
                flag(object.get("any_network")),
                flag(object.get("anonymous")));
        entry.autoStart = flag(object.get("auto_start"));
        entry.adbWireless = object.containsKey("adb_wifi")
                ? flag(object.get("adb_wifi"))
                : true;
        entry.tile = flag(object.get("tile"));
        return entry;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asObject(Object value, String what) {
        if (!(value instanceof Map)) {
            throw new IllegalArgumentException(what + " is not an object");
        }
        return (Map<String, Object>) value;
    }

    @SuppressWarnings("unchecked")
    private static List<Object> asArray(Object value, String what) {
        if (!(value instanceof List)) {
            throw new IllegalArgumentException(what + " is not a list");
        }
        return (List<Object>) value;
    }

    private static String string(Object value, String fallback) {
        return value instanceof String ? (String) value : fallback;
    }

    private static long number(Object value, long fallback) {
        return value instanceof Number ? ((Number) value).longValue() : fallback;
    }

    private static boolean flag(Object value) {
        return value instanceof Boolean && (Boolean) value;
    }

    /** Just enough JSON for this format: objects, arrays, strings, numbers, flags. */
    private static final class Reader {

        private final String text;
        private int at;

        Reader(String text) {
            this.text = text;
        }

        Object readValue() {
            skipSpace();
            if (at >= text.length()) {
                throw new IllegalArgumentException("the file is empty");
            }
            char c = text.charAt(at);
            if (c == '{') {
                return readObject();
            }
            if (c == '[') {
                return readArray();
            }
            if (c == '"') {
                return readString();
            }
            if (text.startsWith("true", at)) {
                at += 4;
                return Boolean.TRUE;
            }
            if (text.startsWith("false", at)) {
                at += 5;
                return Boolean.FALSE;
            }
            if (text.startsWith("null", at)) {
                at += 4;
                return null;
            }
            return readNumber();
        }

        private Map<String, Object> readObject() {
            Map<String, Object> object = new LinkedHashMap<>();
            expect('{');
            skipSpace();
            if (peek() == '}') {
                at++;
                return object;
            }
            while (true) {
                skipSpace();
                String key = readString();
                skipSpace();
                expect(':');
                object.put(key, readValue());
                skipSpace();
                char c = next();
                if (c == '}') {
                    return object;
                }
                if (c != ',') {
                    throw new IllegalArgumentException("expected , or } at " + (at - 1));
                }
            }
        }

        private List<Object> readArray() {
            List<Object> list = new ArrayList<>();
            expect('[');
            skipSpace();
            if (peek() == ']') {
                at++;
                return list;
            }
            while (true) {
                list.add(readValue());
                skipSpace();
                char c = next();
                if (c == ']') {
                    return list;
                }
                if (c != ',') {
                    throw new IllegalArgumentException("expected , or ] at " + (at - 1));
                }
            }
        }

        private String readString() {
            expect('"');
            StringBuilder out = new StringBuilder();
            while (true) {
                char c = next();
                if (c == '"') {
                    return out.toString();
                }
                if (c != '\\') {
                    out.append(c);
                    continue;
                }
                char escape = next();
                switch (escape) {
                    case 'n':
                        out.append('\n');
                        break;
                    case 'r':
                        out.append('\r');
                        break;
                    case 't':
                        out.append('\t');
                        break;
                    case 'u':
                        if (at + 4 > text.length()) {
                            throw new IllegalArgumentException("truncated escape");
                        }
                        out.append((char) Integer.parseInt(text.substring(at, at + 4), 16));
                        at += 4;
                        break;
                    default:
                        out.append(escape);
                }
            }
        }

        private Number readNumber() {
            int start = at;
            while (at < text.length() && "+-.0123456789eE".indexOf(text.charAt(at)) >= 0) {
                at++;
            }
            String number = text.substring(start, at);
            if (number.isEmpty()) {
                throw new IllegalArgumentException("expected a value at " + start);
            }
            try {
                return number.contains(".") || number.contains("e") || number.contains("E")
                        ? Double.parseDouble(number)
                        : Long.parseLong(number);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("bad number " + number);
            }
        }

        private void skipSpace() {
            while (at < text.length() && Character.isWhitespace(text.charAt(at))) {
                at++;
            }
        }

        private char peek() {
            return at < text.length() ? text.charAt(at) : '\0';
        }

        private char next() {
            if (at >= text.length()) {
                throw new IllegalArgumentException("the file ends in the middle");
            }
            return text.charAt(at++);
        }

        private void expect(char wanted) {
            if (next() != wanted) {
                throw new IllegalArgumentException("expected " + wanted + " at " + (at - 1));
            }
        }
    }
}
