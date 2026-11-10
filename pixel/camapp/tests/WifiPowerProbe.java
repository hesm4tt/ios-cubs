package com.cubs.probe;
import android.net.wifi.IWifiManager;
import android.os.IBinder;
import android.os.ServiceManager;

/** Test-only Android Wi-Fi disable/re-enable, with a separate shell watchdog. */
public final class WifiPowerProbe {
    private static boolean waitFor(IWifiManager wifi,int state) throws Exception {
        for (int i=0;i<100;i++) {
            if (wifi.getWifiEnabledState()==state) return true;
            Thread.sleep(100);
        }
        return false;
    }
    public static void main(String[] args) {
        IWifiManager wifi=null;
        boolean restore=false;
        try {
            IBinder binder=ServiceManager.checkService("wifi");
            if (binder==null) { System.out.println("wifi-service-unavailable"); return; }
            wifi=IWifiManager.Stub.asInterface(binder);
            if (wifi.getWifiEnabledState()!=3) { System.out.println("initial-state-not-enabled"); return; }
            restore=true;
            boolean accepted=wifi.setWifiEnabled("com.android.shell",false);
            System.out.println("disable-request="+accepted);
            System.out.println("disabled-observed="+waitFor(wifi,1));
        } catch (Throwable ignored) { System.out.println("disable-outcome-unknown"); }
        finally {
            if (wifi!=null && restore) try {
                boolean accepted=wifi.setWifiEnabled("com.android.shell",true);
                System.out.println("enable-request="+accepted);
                System.out.println("enabled-observed="+waitFor(wifi,3));
            } catch (Throwable ignored) { System.out.println("restore-outcome-unknown"); }
        }
    }
}
