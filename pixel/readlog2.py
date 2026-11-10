import subprocess,sys,re
# read the tail of the XNU log, 4 chars per run, with extra pcrun flags: python readlog2.py FIRST LAST PAYLOAD [extra pcrun args...]
a=int(sys.argv[1]); b=int(sys.argv[2]); pl=sys.argv[3]; extra=sys.argv[4:]
for k in range(a,b+1):
    out=subprocess.run([sys.executable,'pcrun.py','full','--payload',pl,'--qk',str(k),'--cmd','K','--wait','400']+extra,capture_output=True,text=True).stdout
    r=re.findall(r'Reboot reason: (0x[0-9a-f]+)',out); v=None
    for x in r[-3:]:
        n=int(x,16)
        if (n>>28)==0xc and (n&0x0fffffff)!=0: v=n&0x0fffffff
    txt=''.join((chr((v>>s)&0x7f) if 32<=((v>>s)&0x7f)<127 or ((v>>s)&0x7f)==10 else '.') for s in (21,14,7,0)) if v is not None else '????'
    print(k,hex(v) if v else None,repr(txt),flush=True)
