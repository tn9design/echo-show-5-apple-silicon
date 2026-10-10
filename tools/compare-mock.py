import socket,struct,subprocess,threading,hashlib,json
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--fastboot',required=True);p.add_argument('--image',required=True);p.add_argument('--sparse-limit');a=p.parse_args()
root=Path(a.image).resolve().parent

def test(name):
 image=root/name
 expected=hashlib.sha256(image.read_bytes()).hexdigest()
 sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen(1);sock.settimeout(10)
 port=sock.getsockname()[1]; logs=[]; result={}
 def server():
  conn,_=sock.accept();conn.settimeout(20)
  def read(n):
   chunks=[]
   while n:
    b=conn.recv(min(n,1048576))
    if not b:raise EOFError()
    chunks.append(b);n-=len(b)
   return b''.join(chunks)
  def recv():return read(struct.unpack('>Q',read(8))[0])
  def send(b):conn.sendall(struct.pack('>Q',len(b))+b)
  assert read(4)==b'FB01';conn.sendall(b'FB01')
  while True:
   cmd=recv();logs.append(cmd.decode(errors='replace'))
   if cmd.startswith(b'getvar:'):
    vals={b'getvar:max-download-size':b'0x00001000',b'getvar:is-userspace':b'no',b'getvar:has-slot:brick':b'no',b'getvar:partition-type:brick':b'raw'}
    if cmd in vals:send(b'OKAY'+vals[cmd])
    else:send(b'FAILunknown variable')
   elif cmd.startswith(b'download:'):
    size=int(cmd.split(b':')[1],16);send(b'DATA'+cmd.split(b':')[1]); total=0;h=hashlib.sha256()
    while total<size:
     b=recv();total+=len(b);h.update(b)
    result.update(bytes=total,sha256=h.hexdigest(),matches=total==image.stat().st_size and h.hexdigest()==expected)
    send(b'OKAY')
   elif cmd==b'flash:brick':
    send(b'FAILisolated mock deliberately rejects flash');break
   else:send(b'FAILunexpected command');break
  conn.close();sock.close()
 thread=threading.Thread(target=server,daemon=True);thread.start()
 command=[a.fastboot,'-s',f'tcp:127.0.0.1:{port}']+(['-S',a.sparse_limit] if a.sparse_limit else [])+['flash','brick',str(image)]
 proc=subprocess.run(command,capture_output=True,text=True,timeout=30)
 thread.join(5)
 result.update(image=name,commands=logs,exit=proc.returncode,output=proc.stdout+proc.stderr)
 return result
print(json.dumps(test(Path(a.image).name),indent=2))
