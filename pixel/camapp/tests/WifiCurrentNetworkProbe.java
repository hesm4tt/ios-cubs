package com.cubs.probe;
import android.net.wifi.IWifiManager;
import android.net.wifi.WifiInfo;
import android.os.IBinder;
import android.os.ServiceManager;

/** Reports only whether a connected saved network ID and security type are available. */
public final class WifiCurrentNetworkProbe {
    public static void main(String[] args) {
        try {
            IBinder binder=ServiceManager.checkService("wifi");
            WifiInfo info=binder==null ? null : IWifiManager.Stub.asInterface(binder).getConnectionInfo("com.android.shell",null);
            if (info==null) { System.out.println("connection-info-unavailable"); return; }
            System.out.println("saved-id="+(info.getNetworkId()>=0)+" security-type="+info.getCurrentSecurityType());
        } catch (Throwable ignored) { System.out.println("connection-info-unavailable"); }
    }
}
