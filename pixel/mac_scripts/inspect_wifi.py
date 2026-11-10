import re, subprocess
s=subprocess.check_output(['/opt/homebrew/bin/adb','shell','cmd','wifi','status'],text=True)
s=re.sub(r'(?i)(ssid|bssid|mac address|networkid|ip address):[^,\n]+',r'\1:<redacted>',s)
s=re.sub(r'(?im)^.*connected to .*$', 'Connection: <redacted>', s)
s=re.sub(r'(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}', '<mac>', s)
s=re.sub(r'(?:\d{1,3}\.){3}\d{1,3}', '<ip>', s)
print(s[:2000])
