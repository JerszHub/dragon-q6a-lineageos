/*
 * SPDX-FileCopyrightText: 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.wwan;

import android.util.Xml;

import org.xmlpull.v1.XmlPullParser;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Looks up the data APNs of a SIM card in the APN database (apns-conf.xml), the way
 * Telephony matches a SIM to its carrier: by MCC and MNC from the IMSI, with MVNO entries
 * picked by IMSI pattern, GID1 or service provider name.
 *
 * Reads one line from stdin, so the identifiers never show up in the process list:
 *   <imsi> <gid1 as hex, or -> <EF_SPN contents as hex, or ->
 * Prints one "apn|auth|user|password" line per candidate, MVNO matches first, then entries
 * whose carrier name starts with the SIM's service provider name. auth is the AT+CGAUTH
 * protocol: 0 none, 1 PAP, 2 CHAP.
 */
public class ApnLookup {
    private static final String APNS_CONF = "/product/etc/apns-conf.xml";
    // Lets a copy of the database be tested without rebuilding the product image.
    private static final String APNS_CONF_ENV = "Q6A_APNS_CONF";

    public static void main(String[] args) throws Exception {
        String line = new BufferedReader(new InputStreamReader(System.in)).readLine();
        String[] f = line == null ? new String[0] : line.trim().split("\\s+");
        if (f.length < 1 || !f[0].matches("[0-9]{6,15}")) {
            System.err.println("stdin: <imsi> [gid1 hex|-] [EF_SPN hex|-]");
            System.exit(2);
        }
        String imsi = f[0];
        String gid1 = f.length > 1 && !f[1].equals("-") ? f[1].toLowerCase(Locale.ROOT) : "";
        String spn = f.length > 2 && !f[2].equals("-") ? decodeSpn(f[2]) : "";

        List<String> mvno = new ArrayList<>();
        List<String> named = new ArrayList<>();
        List<String> plain = new ArrayList<>();
        int mncLength = 0;
        XmlPullParser p = Xml.newPullParser();
        String path = System.getenv(APNS_CONF_ENV);
        File conf = new File(path != null ? path : APNS_CONF);
        // Without the database there are no candidates; the caller still has its fallbacks.
        if (!conf.isFile()) return;
        try (FileReader in = new FileReader(conf)) {
            p.setInput(in);
            for (int e = p.getEventType(); e != XmlPullParser.END_DOCUMENT; e = p.next()) {
                if (e != XmlPullParser.START_TAG || !p.getName().equals("apn")) continue;
                String mnc = attr(p, "mnc");
                if (!imsi.startsWith(attr(p, "mcc") + mnc) || mnc.isEmpty()) continue;
                // Where 2- and 3-digit MNCs share a prefix (310 26 and 310 260), the longer
                // match is the SIM's network.
                if (mnc.length() < mncLength) continue;
                if (mnc.length() > mncLength) {
                    mncLength = mnc.length();
                    mvno.clear();
                    named.clear();
                    plain.clear();
                }
                if (!isData(attr(p, "type")) || attr(p, "carrier_enabled").equals("false")) {
                    continue;
                }
                if (attr(p, "apn").isEmpty()) continue;
                String entry = attr(p, "apn") + "|" + auth(p) + "|" + attr(p, "user") + "|"
                        + attr(p, "password");
                String type = attr(p, "mvno_type");
                if (type.isEmpty()) {
                    // Some MVNOs are listed without match data, next to their host network
                    // (Heyah and tuBiedronka on T-Mobile.pl); the SIM's own name orders them.
                    boolean ours = !spn.isEmpty() && attr(p, "carrier").toLowerCase(Locale.ROOT)
                            .startsWith(spn.toLowerCase(Locale.ROOT));
                    (ours ? named : plain).add(entry);
                } else if (mvnoMatches(type, attr(p, "mvno_match_data"), imsi, gid1, spn)) {
                    mvno.add(entry);
                }
            }
        }
        // An MVNO's own entries win; without one, its host network's entries apply.
        Set<String> out = new LinkedHashSet<>(mvno);
        if (mvno.isEmpty()) {
            out.addAll(named);
            out.addAll(plain);
        }
        for (String s : out) System.out.println(s);
    }

    private static String attr(XmlPullParser p, String name) {
        String v = p.getAttributeValue(null, name);
        return v == null ? "" : v;
    }

    private static boolean isData(String type) {
        if (type.isEmpty()) return true;
        for (String t : type.split(",")) {
            t = t.trim();
            if (t.equals("default") || t.equals("*")) return true;
        }
        return false;
    }

    // apns-conf authtype: 0 none, 1 PAP, 2 CHAP, 3 PAP or CHAP; unset means none without a
    // user name and PAP or CHAP with one. AT+CGAUTH knows only PAP and CHAP, and a network
    // that offers both accepts CHAP. Without a user name there is nothing to authenticate.
    private static int auth(XmlPullParser p) {
        if (attr(p, "user").isEmpty()) return 0;
        int type;
        try {
            type = Integer.parseInt(attr(p, "authtype"));
        } catch (NumberFormatException e) {
            type = 3;
        }
        return type == 3 ? 2 : Math.max(0, Math.min(type, 2));
    }

    private static boolean mvnoMatches(String type, String data, String imsi, String gid1,
            String spn) {
        if (data.isEmpty()) return false;
        switch (type) {
            case "imsi":
                if (imsi.length() < data.length()) return false;
                for (int i = 0; i < data.length(); i++) {
                    char c = data.charAt(i);
                    if (c != 'x' && c != 'X' && c != imsi.charAt(i)) return false;
                }
                return true;
            case "gid":
                return !gid1.isEmpty() && gid1.startsWith(data.toLowerCase(Locale.ROOT));
            case "spn":
                return !spn.isEmpty() && spn.equalsIgnoreCase(data);
            default:
                return false;
        }
    }

    // EF_SPN (3GPP TS 31.102 4.2.12): a display condition byte, then the name in the GSM
    // default alphabet padded with 0xFF, or UCS2 after a 0x80 byte. Letters, digits and the
    // space are the same in the GSM alphabet and in ASCII, which covers carrier names.
    private static String decodeSpn(String hex) {
        int n = hex.length() / 2;
        if (n < 2) return "";
        byte[] b = new byte[n - 1];
        for (int i = 1; i < n; i++) {
            b[i - 1] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        }
        if ((b[0] & 0xff) == 0x80) {
            int end = b.length;
            while (end > 1 && (b[end - 1] & 0xff) == 0xff) end--;
            int len = (end - 1) & ~1;
            return new String(b, 1, len, StandardCharsets.UTF_16BE).trim();
        }
        StringBuilder s = new StringBuilder();
        for (byte c : b) {
            if ((c & 0xff) == 0xff) break;
            s.append((char) (c & 0x7f));
        }
        return s.toString().trim();
    }
}
