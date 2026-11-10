import re, subprocess
r = subprocess.run(['/opt/homebrew/bin/adb','shell','dumpsys','isub'], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
s = r.stdout
for label, pattern in [('embedded-true', r'(?i)(?:isEmbedded|embedded)\s*[=:]\s*(?:true|1)\b'), ('embedded-false', r'(?i)(?:isEmbedded|embedded)\s*[=:]\s*(?:false|0)\b')]:
    print(label, len(re.findall(pattern, s)))
print('subscription-dump-available', r.returncode == 0 and bool(s))
