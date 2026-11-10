#!/usr/bin/env python3
# usbmux_list.py (run on the Mac): asks the Mac's own usbmuxd (the service behind Finder, Xcode, iTunes) which devices it sees, over its unix socket
# /var/run/usbmuxd (the plist protocol: 16-byte header length/version/request/tag, request 8 = plist). Nothing to install.
#   usbmux_list.py            list the devices
#   usbmux_list.py lockdown   also connect to the first device's lockdownd (port 62078) and ask QueryType / the device name
import plistlib, socket, struct, sys

def request(sock, payload, tag):
    body = plistlib.dumps(payload)
    sock.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)

def reply(sock):
    head = b''
    while len(head) < 16:
        d = sock.recv(16 - len(head))
        if not d:
            raise SystemExit('usbmuxd closed the connection')
        head += d
    length, _, _, _ = struct.unpack('<IIII', head)
    body = b''
    while len(body) < length - 16:
        body += sock.recv(length - 16 - len(body))
    return plistlib.loads(body)

def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect('/var/run/usbmuxd')
    return s

s = connect()
request(s, {'MessageType': 'ListDevices', 'ClientVersionString': 'usbmux_list', 'ProgName': 'usbmux_list', 'kLibUSBMuxVersion': 3}, 1)
devs = reply(s).get('DeviceList', [])
print('%d device(s)' % len(devs))
for d in devs:
    print(' ', d.get('DeviceID'), {k: v for k, v in d.get('Properties', {}).items()})
if len(sys.argv) > 1 and sys.argv[1] == 'lockdown' and devs:
    dev = devs[0]['DeviceID']
    s2 = connect()
    request(s2, {'MessageType': 'Connect', 'ClientVersionString': 'usbmux_list', 'ProgName': 'usbmux_list', 'DeviceID': dev,
                 'PortNumber': socket.htons(62078)}, 2)
    r = reply(s2)
    print('connect to lockdownd:', r.get('Number'), '(0 = ok)')
    if r.get('Number') == 0:
        def lock(msg):
            b = plistlib.dumps(msg)
            s2.sendall(struct.pack('>I', len(b)) + b)
            n = struct.unpack('>I', s2.recv(4))[0]
            data = b''
            while len(data) < n:
                data += s2.recv(n - len(data))
            return plistlib.loads(data)
        print('QueryType:', lock({'Request': 'QueryType', 'Label': 'usbmux_list'}))
        print('GetValue DeviceName:', lock({'Request': 'GetValue', 'Key': 'DeviceName', 'Label': 'usbmux_list'}))
