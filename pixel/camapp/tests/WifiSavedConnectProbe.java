package com.cubs.probe;
import android.net.wifi.IActionListener;
import android.net.wifi.IWifiManager;
import android.net.wifi.WifiInfo;
import android.os.IBinder;
import android.os.ServiceManager;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Re-select only the current saved network; never reads credentials or prints identifiers. */
public final class WifiSavedConnectProbe {
    public static void main(String[] args) {
        try {
            IBinder binder=ServiceManager.checkService("wifi");
            if (binder==null) { System.out.println("wifi-service-unavailable"); return; }
            IWifiManager wifi=IWifiManager.Stub.asInterface(binder);
            WifiInfo before=wifi.getConnectionInfo("com.android.shell",null);
            if (before==null || before.getNetworkId()<0) { System.out.println("saved-network-unavailable"); return; }
            final int current=before.getNetworkId();
            CountDownLatch done=new CountDownLatch(1);
            final int[] result={-1};
            IActionListener listener=new IActionListener.Stub() {
                @Override public void onSuccess() { result[0]=1; done.countDown(); }
                @Override public void onFailure(int reason) { result[0]=0; done.countDown(); }
            };
            wifi.connect(null,current,listener,"com.android.shell",null);
            if (!done.await(10,TimeUnit.SECONDS)) { System.out.println("request-outcome-unknown"); return; }
            System.out.println(result[0]==1 ? "request-accepted" : "request-rejected");
            WifiInfo after=wifi.getConnectionInfo("com.android.shell",null);
            System.out.println("same-network="+(after!=null && after.getNetworkId()==current));
        } catch (Throwable ignored) { System.out.println("request-outcome-unknown"); }
    }
}
