package com.cubs.cam;
import android.net.wifi.IWifiManager;
import android.os.IBinder;
import android.os.ServiceManager;

/** Experimental one-shot helper. Invoked only by a privileged local receiver. */
public final class PrivilegedWifiPower {
    public static void main(String[] args) {
        String outcome="outcome-unknown";
        try {
            if (args.length!=1 || !(args[0].equals("on") || args[0].equals("off"))) {
                outcome="request-invalid";
            } else {
                boolean on=args[0].equals("on");
                IBinder b=ServiceManager.checkService("wifi");
                if (b==null) outcome="service-unavailable";
                else {
                    IWifiManager wifi=IWifiManager.Stub.asInterface(b);
                    if (!wifi.setWifiEnabled("com.android.shell",on)) outcome="request-rejected";
                    else {
                        int expected=on ? 3 : 1;
                        for (int i=0;i<100;i++) {
                            if (wifi.getWifiEnabledState()==expected) { outcome="state-observed"; break; }
                            Thread.sleep(100);
                        }
                    }
                }
            }
        } catch (Throwable ignored) { /* Do not print platform exception messages. */ }
        System.out.println(outcome);
        System.out.flush();
        // The process owns no reusable state; do not leave Binder threads behind.
        System.exit(0);
    }
}
