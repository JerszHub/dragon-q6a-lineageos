/*
 * SPDX-FileCopyrightText: 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.wwan;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;

import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Locale;

/**
 * Shows the modem's state, serving cell and data rate in an ongoing, silent notification, so
 * that the signal can be watched while the antennas are moved around. q6a_wwan.sh publishes
 *   q6a.wwan.state  no_modem, starting, fcc_failed, no_sim, sim_pin, sim_locked, searching,
 *                   connecting, no_apn or connected
 *   q6a.wwan.cell   operator|technology|band|RSRP dBm|RSRQ dB|SINR dB, empty when unknown
 *   persist.q6a.wwan.iface  the modem's network interface, whose byte counters give the rate
 * Runs for as long as the system does, as an app_process tool posting for the system.
 */
public class WwanStatus {
    private static final String CHANNEL = "q6a_wwan";
    private static final String TAG = "q6a_wwan";
    private static final int ID = 1;

    public static void main(String[] args) throws Exception {
        dropToSystem();
        Context context = systemContext();
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        int icon = context.getResources().getIdentifier("ic_signal_cellular", "drawable",
                "android");
        String shown = null;
        boolean channel = false;
        long[] last = null;
        while (true) {
            String state = prop("q6a.wwan.state");
            String cell = prop("q6a.wwan.cell");
            // The language picked in Settings, or the build's default until one is picked.
            String lang = prop("persist.sys.locale");
            if (lang.isEmpty()) lang = prop("ro.product.locale");
            boolean pl = lang.startsWith("pl");
            Locale locale = pl ? Locale.forLanguageTag("pl") : Locale.US;
            long[] now = state.equals("connected") ? counters(prop("persist.q6a.wwan.iface"))
                    : null;
            String rate = "";
            if (now != null && last != null && now[2] > last[2]) {
                long ms = now[2] - last[2];
                rate = "↓ " + rate(locale, (now[0] - last[0]) * 8000 / ms) + "  ↑ "
                        + rate(locale, (now[1] - last[1]) * 8000 / ms);
            }
            last = now;
            String key = state + "\n" + cell + "\n" + rate + "\n" + pl;
            if (!key.equals(shown)) {
                shown = key;
                if (state.isEmpty() || state.equals("no_modem")) {
                    nm.cancel(TAG, ID);
                } else {
                    if (!channel) {
                        NotificationChannel ch = new NotificationChannel(CHANNEL,
                                pl ? "Modem komórkowy" : "Cellular modem",
                                NotificationManager.IMPORTANCE_LOW);
                        ch.setShowBadge(false);
                        nm.createNotificationChannel(ch);
                        channel = true;
                    }
                    nm.notify(TAG, ID, build(context, icon, state, cell, rate, pl, locale));
                }
            }
            Thread.sleep(2000);
        }
    }

    private static Notification build(Context context, int icon, String state, String cell,
            String rate, boolean pl, Locale locale) {
        String[] f = (cell + "|||||").split("\\|", -1);
        String operator = f[0], tech = f[1], band = f[2], rsrp = f[3], rsrq = f[4], sinr = f[5];

        String title;
        if (state.equals("connected")) {
            title = operator.isEmpty() ? (pl ? "Połączono" : "Connected") : operator;
            if (!tech.isEmpty()) title += " · " + tech + (band.isEmpty() ? "" : " B" + band);
        } else {
            title = describe(state, pl);
        }

        StringBuilder text = new StringBuilder();
        if (!rsrp.isEmpty()) text.append("RSRP ").append(rsrp).append(" dBm");
        if (!sinr.isEmpty()) text.append(" · SINR ").append(sinr).append(" dB");
        if (!rsrq.isEmpty()) {
            try {
                rsrq = String.format(locale, "%.1f", Float.parseFloat(rsrq));
            } catch (NumberFormatException e) {
                // Shown as published.
            }
            text.append(" · RSRQ ").append(rsrq).append(" dB");
        }
        if (text.length() == 0) text.append(pl ? "Brak pomiaru sygnału" : "No signal reading");

        return new Notification.Builder(context, CHANNEL)
                .setSmallIcon(icon, bars(rsrp))
                .setContentTitle(title)
                .setContentText(text)
                .setSubText(rate.isEmpty() ? null : rate)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setLocalOnly(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .build();
    }

    // Received and sent bytes of the interface, and when they were read.
    private static long[] counters(String iface) {
        if (iface.isEmpty() || iface.contains("/")) return null;
        String dir = "/sys/class/net/" + iface + "/statistics/";
        try {
            return new long[] {
                Long.parseLong(Files.readString(Paths.get(dir + "rx_bytes")).trim()),
                Long.parseLong(Files.readString(Paths.get(dir + "tx_bytes")).trim()),
                SystemClock.elapsedRealtime()
            };
        } catch (IOException | NumberFormatException e) {
            return null;
        }
    }

    private static String rate(Locale locale, long bitsPerSecond) {
        if (bitsPerSecond >= 1_000_000) {
            return String.format(locale, "%.1f Mb/s", bitsPerSecond / 1e6);
        }
        return String.format(locale, "%d kb/s", (bitsPerSecond + 500) / 1000);
    }

    // The bars Android draws for LTE, from the default RSRP thresholds
    // (config_lte_rsrp_thresholds: -115, -105, -95, -85 dBm).
    private static int bars(String rsrp) {
        int dbm;
        try {
            dbm = Math.round(Float.parseFloat(rsrp));
        } catch (NumberFormatException e) {
            return 0;
        }
        return dbm >= -85 ? 4 : dbm >= -95 ? 3 : dbm >= -105 ? 2 : dbm >= -115 ? 1 : 0;
    }

    private static String describe(String state, boolean pl) {
        switch (state) {
            case "starting": return pl ? "Modem się uruchamia" : "Modem starting";
            case "fcc_failed": return pl ? "Radio modemu zablokowane" : "Modem radio locked";
            case "no_sim": return pl ? "Brak karty SIM" : "No SIM card";
            case "sim_pin": return pl ? "Karta SIM wymaga PIN-u" : "SIM card needs a PIN";
            case "sim_locked": return pl ? "Karta SIM zablokowana" : "SIM card locked";
            case "searching": return pl ? "Szukanie sieci" : "Searching for a network";
            case "connecting": return pl ? "Łączenie" : "Connecting";
            case "no_apn": return pl ? "Nie udało się połączyć" : "Could not connect";
            default: return state;
        }
    }

    private static String prop(String name) throws Exception {
        Method get = Class.forName("android.os.SystemProperties").getMethod("get", String.class);
        return (String) get.invoke(null, name);
    }

    // NotificationManagerService keeps the channels of "android" under the system uid, so a
    // channel created as root would not be found. init starts the service as the system user
    // already; this covers a start from a root shell.
    private static void dropToSystem() throws Exception {
        if (Process.myUid() != 0) return;
        Process.class.getMethod("setGid", int.class).invoke(null, Process.SYSTEM_UID);
        Process.class.getMethod("setUid", int.class).invoke(null, Process.SYSTEM_UID);
    }

    // An app_process tool has no Context. Build the system one the way ActivityThread does for
    // system_server, without attaching to the activity manager.
    private static Context systemContext() throws Exception {
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Constructor<?> ctor = at.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object thread = ctor.newInstance();
        Field current = at.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        Field system = at.getDeclaredField("mSystemThread");
        system.setAccessible(true);
        system.setBoolean(thread, true);
        Method getSystemContext = at.getDeclaredMethod("getSystemContext");
        return (Context) getSystemContext.invoke(thread);
    }
}
