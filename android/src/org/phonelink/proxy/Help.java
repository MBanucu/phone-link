package org.phonelink.proxy;

/**
 * The app explaining itself, in one place: the panel's Info dialog and the
 * service's {@code dumpsys} dump print the same text, so what a person reads on
 * the phone cannot drift from what an agent reads over adb.
 *
 * <p>No Android types on purpose: it is part of the hermetic JVM suite, where a
 * test pins the adb contract this text documents.
 */
final class Help {

    /** The one command that prints this text over adb. */
    static final String ADB_DUMP =
            "adb shell dumpsys activity service org.phonelink.proxy/.ProxyService";

    /** The activity extra that opens the Info dialog, for a phone in one's hand. */
    static final String EXTRA_HELP = "help";

    private Help() {
    }

    static String text() {
        return String.join("\n",
                "Phone link proxy — a SOCKS5 listener that lets the laptop use this",
                "phone's mobile connection.",
                "",
                "Several saved proxies can listen at once, each on its own port,",
                "with its own credentials and its own SSID: the list is a list of",
                "listeners. One port holds one listener, so starting a proxy on a",
                "port that is taken replaces what was there; the other ports keep",
                "listening. The tile speaks for all of them.",
                "",
                "The laptop joins this phone's hotspot and drives it over adb with",
                "wireless debugging: it starts the listener here and sends its own",
                "traffic through it, so the internet sees the phone's mobile address.",
                "The phone is itself a client of the laptop's access point at that",
                "moment, so its normal route leads back to the laptop; the app holds",
                "an explicit cellular network request for its egress instead.",
                "",
                "When the port is open",
                "  Only while the phone is a client of the configured SSID — or of any",
                "  network when \"Ignore the SSID\" is on. Otherwise the service stays",
                "  up with the port closed and the notification says why; it opens on",
                "  the next SSID match.",
                "",
                "The panel — a list of saved proxies, and one of them opened. The",
                "header holds Info, a warning mark while a reboot restart cannot",
                "work, and a menu; the state is one line above Start and Stop, so the",
                "list gets the room.",
                "  Home                   every saved proxy with what it holds and",
                "                         whether it is running; New proxy copies the",
                "                         one in use and takes the next free port, then",
                "                         opens it. With nothing saved the page says so",
                "                         and the same button is the way in.",
                "  One proxy              port, user, password, SSID, the two boxes,",
                "                         auto-start, its battery line and wireless",
                "                         debugging — the whole configuration, applied and",
                "                         stored by Start. Save writes the form, Save as…",
                "                         copies it under another name, Revert drops the",
                "                         edits, Delete removes it.",
                "  Its log                the last 200 things that happened to this",
                "                         proxy — starts, uplink changes, client counts,",
                "                         failures — with the bytes it moved in this run",
                "                         and a sparkline of the last minute. The menu's",
                "                         All events has everything, whatever it was about.",
                "",
                "Over adb, no unlock needed",
                "  adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \\",
                "    -a org.phonelink.proxy.action.START --ei port 1081 --es user proxy \\",
                "    --es password … --es ssid PhoneLink",
                "  adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \\",
                "    -a org.phonelink.proxy.action.STOP",
                "",
                "  A stop with --es profile NAME stops that proxy and leaves the rest;",
                "  --ei port N stops the one on that port; neither stops them all.",
                "",
                "  Every extra is optional; a start that omits one reuses the stored",
                "  value, so changing only the port keeps the credentials.",
                "    --ei port N             listener port (default 1080)",
                "    --es user NAME          SOCKS5 user; empty means no authentication",
                "    --es password PASS      SOCKS5 password",
                "    --es ssid NAME          the Wi-Fi the listener may run on",
                "    --ez anonymous BOOL     listen without authentication",
                "    --ez any_network BOOL   ignore the SSID",
                "    --ez auto_start BOOL    come back after a reboot",
                "    --ez adb_wifi BOOL      switch wireless debugging back on when the",
                "                            SSID matches, so adb can reach the phone",
                "    --es profile NAME       start the saved configuration called NAME,",
                "                            with any other extra applied on top",
                "",
                "  The configuration the service has becomes a saved one with",
                "  adb shell am start-foreground-service -n org.phonelink.proxy/.ProxyService \\",
                "    -a org.phonelink.proxy.action.SAVE_PROFILE --es profile NAME",
                "  the same command with",
                "    -a org.phonelink.proxy.action.RENAME_PROFILE --es profile NAME \\",
                "    --es to NEWERNAME",
                "  renames it, and with",
                "    -a org.phonelink.proxy.action.DELETE_PROFILE --es profile NAME",
                "  removes it.",
                "  `dumpsys` lists what is running — each with its port, its bytes",
                "  and its clients — then what is saved, with what each one holds and",
                "  which one was started last; the panel's list shows the same names.",
                "",
                "  Both paths write one store, so the panel shows what adb started.",
                "",
                "About the battery exemption",
                "  Android only restarts the proxy after a reboot when this app is",
                "  exempt from battery optimization. Without it the tile and adb still",
                "  start the proxy; it just does not come back by itself.",
                "",
                "This text",
                "  " + ADB_DUMP,
                "  or the Info button in the panel. With the app stopped,",
                "  adb shell am start -n org.phonelink.proxy/.MainActivity --ez help true",
                "  opens the panel with this dialog.");
    }
}
