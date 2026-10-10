#!/usr/bin/env python3
import os,pty,fcntl,termios,struct,select,subprocess,time,signal,json,base64,pathlib,sys
root=pathlib.Path(__file__).resolve().parent
key='ssh-ed25519 '+base64.b64encode(bytes([0,0,0,11])+b'ssh-ed25519'+bytes([0,0,0,32])+bytes([7])*32).decode()
fixture=root/'shell-fixture.sh'
fixture.write_text("export HOME=/home/echotest\nexport PS1='echotest@fixture:~$ '\nunset HISTFILE\nid() { printf '%s\\n' echotest; }\nuname() { printf '%s\\n' aarch64; }\ncat() { if [ \"$1\" = /etc/ssh/ssh_host_ed25519_key.pub ]; then printf '%s\\n' '"+key+" fixture'; else command cat \"$@\"; fi; }\nip() { printf '%s\\n' '2: eth0 inet 192.168.64.7/24 brd 192.168.64.255 scope global eth0'; }\n")

def run(binary,shell,columns):
 pid,gm=pty.fork()
 if pid==0:
  os.environ.update(TERM='xterm-256color',HOME='/home/echotest',PATH='/usr/bin:/bin',HISTFILE='/dev/null',LC_ALL='C',INPUTRC='/dev/null',ECHOGUIDE_REVIEW_FIXTURE=str(fixture))
  os.execv(shell,[shell,'--noprofile','--norc','-i'] if shell.endswith('bash') else [shell,'-d','-f','-i'])
 fcntl.ioctl(gm,termios.TIOCSWINSZ,struct.pack('HHHH',24,columns,0,0))
 hm,hs=pty.openpty();out=None;capture=bytearray()
 try:
  deadline=time.monotonic()+3;start=b''
  while time.monotonic()<deadline:
   r,_,_=select.select([gm],[],[],.1)
   if r:
    start+=os.read(gm,65536)
    if any(mark in start for mark in [b'$ ',b'% ',b'# ']):break
  os.write(gm,('. '+str(fixture)+'\n').encode())
  prompt=b'';deadline=time.monotonic()+3
  while time.monotonic()<deadline:
   r,_,_=select.select([gm],[],[],.1)
   if r:
    prompt+=os.read(gm,65536)
    if b'echotest@fixture:~$ ' in prompt:break
  if b'echotest@fixture:~$ ' not in prompt:raise RuntimeError('fixture shell prompt missing: '+shell+' '+repr(prompt)+' initial '+repr(start))
  out=subprocess.Popen([str(binary),'exchange',os.ttyname(hs)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  if out.stderr.readline()!=b'HARNESS-READY\n':raise RuntimeError('harness did not open PTY')
  os.write(hm,prompt)
  deadline=time.monotonic()+15
  while out.poll() is None and time.monotonic()<deadline:
   ready,_,_=select.select([gm,hm],[],[],.02)
   for fd in ready:
    data=os.read(fd,65536)
    if fd==gm:capture.extend(data)
    os.write(hm if fd==gm else gm,data)
  if out.poll() is None:out.kill()
  stdout,stderr=out.communicate(timeout=3)
  transcripts=[base64.b64decode(line.split(' ',1)[1]) for line in stdout.decode().splitlines() if line.startswith('TRANSCRIPT64 ')]
  report={'shell':pathlib.Path(shell).name,'columns':columns,'exit':out.returncode,'parsed':stdout.decode().count('PARSED'),'error':stderr.decode().strip()}
  if os.environ.get('ECHOGUIDE_HARNESS_CAPTURE')=='1':
   report.update(transcripts_repr=[repr(t) for t in transcripts],shell_output_repr=repr(bytes(capture)))
  return report
 finally:
  if out and out.poll() is None:out.kill();out.wait()
  os.close(hm);os.close(hs);os.close(gm)
  try:os.kill(pid,signal.SIGHUP)
  except ProcessLookupError:pass
  try:os.waitpid(pid,0)
  except ChildProcessError:pass

binary=pathlib.Path(sys.argv[1]).resolve()
results=[run(binary,shell,width) for shell in ['/bin/bash','/bin/zsh',str(root/'readline-shell')] for width in [80,132]]
(root/(binary.name+'-results.json')).write_text(json.dumps(results,indent=2)+'\n')
for r in results:print(json.dumps({k:r[k] for k in ['shell','columns','exit','parsed','error']}))
