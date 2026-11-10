from pathlib import Path

s=Path('/tmp/run_cubs_scan_ios_test.sh').read_text()
old='cubs-wifi-binder-probe.dex'
assert s.count(old)==3
s=s.replace(old,'cubs-wifi-saved-probe.dex')
old='com.cubs.probe.WifiBinderProbe'
assert s.count(old)==1
s=s.replace(old,'com.cubs.probe.WifiSavedConnectProbe')
old='/data/local/tmp/cubsscan-launcher.sh; sync'
assert s.count(old)==1
s=s.replace(old,'/data/local/tmp/cubsscan-launcher.sh /data/local/tmp/cubs-wifi-saved-probe.dex; sync')
Path('/tmp/run_wifi_saved_ios.sh').write_text(s)
print('saved-network-ios-runner-generated')
