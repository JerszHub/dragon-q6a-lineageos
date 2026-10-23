/*
 * SPDX-FileCopyrightText: 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.wwan;

import android.net.EthernetManager;
import android.net.EthernetNetworkManagementException;
import android.net.EthernetNetworkUpdateRequest;
import android.net.IpConfiguration;
import android.net.LinkAddress;
import android.net.StaticIpConfiguration;
import android.os.IBinder;
import android.os.OutcomeReceiver;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;

/**
 * Hands the IPv4 configuration of a WWAN modem's Ethernet-like interface to Android's
 * EthernetService. The modem has no DHCP server: the address comes from its PDP context.
 *
 * Usage: WwanConfig <iface> <ip/prefix> <gateway> <dns> [dns...]
 *        WwanConfig <iface> --dhcp
 */
public class WwanConfig {
    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[1].equals("--dhcp")) {
            update(args[0], new IpConfiguration.Builder().build());
        }
        if (args.length < 4) {
            System.err.println("usage: <iface> <ip/prefix> <gateway> <dns> [dns...]");
            System.err.println("       <iface> --dhcp");
            System.exit(2);
        }
        List<InetAddress> dns = new ArrayList<>();
        for (int i = 3; i < args.length; i++) {
            dns.add(InetAddress.getByName(args[i]));
        }
        StaticIpConfiguration sic = new StaticIpConfiguration.Builder()
                .setIpAddress(new LinkAddress(args[1]))
                .setGateway(InetAddress.getByName(args[2]))
                .setDnsServers(dns)
                .build();
        update(args[0], new IpConfiguration.Builder().setStaticIpConfiguration(sic).build());
    }

    private static void update(String iface, IpConfiguration ipc) throws Exception {
        EthernetNetworkUpdateRequest request =
                new EthernetNetworkUpdateRequest.Builder().setIpConfiguration(ipc).build();
        CountDownLatch done = new CountDownLatch(1);
        int[] rc = {1};
        ethernetManager().updateConfiguration(iface, request, new Executor() {
                    @Override
                    public void execute(Runnable r) {
                        r.run();
                    }
                },
                new OutcomeReceiver<String, EthernetNetworkManagementException>() {
                    @Override
                    public void onResult(String result) {
                        System.out.println("ok " + result);
                        rc[0] = 0;
                        done.countDown();
                    }

                    @Override
                    public void onError(EthernetNetworkManagementException e) {
                        System.out.println("error " + e);
                        done.countDown();
                    }
                });
        if (!done.await(10, TimeUnit.SECONDS)) System.out.println("timeout");
        System.exit(rc[0]);
    }

    // No Context in an app_process tool: bind the service directly. EthernetManager only keeps the
    // context for APIs this tool does not use.
    private static EthernetManager ethernetManager() throws Exception {
        Method getService = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class);
        IBinder binder = (IBinder) getService.invoke(null, "ethernet");
        Class<?> iface = Class.forName("android.net.IEthernetManager");
        Object service = Class.forName("android.net.IEthernetManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        Constructor<EthernetManager> c = EthernetManager.class.getDeclaredConstructor(
                android.content.Context.class, iface);
        c.setAccessible(true);
        return c.newInstance(null, service);
    }
}
