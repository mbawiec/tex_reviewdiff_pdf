#!/usr/bin/env python3
from pathlib import Path
import hashlib, re, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
SCRIPT=ROOT/'reviewdiff.sh'
EXPECTED='a56c8a6112138f0069d43aee894cb3a2b1bddf8cf87ac38ec5ebf44f50674bee'
def emit(n,v,d=''):
 print(f'{n}={"PASS" if v else "FAIL"}'+(f' {d}' if d else '')); return bool(v)
def main():
 ok=emit('REVIEWDIFF_PRESENT',SCRIPT.is_file())
 if not SCRIPT.is_file(): return 1
 data=SCRIPT.read_bytes(); text=data.decode(errors='replace'); actual=hashlib.sha256(data).hexdigest()
 ok &= emit('LOCKED_SHA256',actual==EXPECTED,f'expected={EXPECTED} actual={actual}')
 r=subprocess.run(['bash','-n',str(SCRIPT)],capture_output=True,text=True)
 ok &= emit('BASH_SYNTAX',r.returncode==0,r.stderr.strip())
 markers=['STRUCTURAL_TEXT_IN_MATH_PROTECTION_FIX31=1','WHOLE_DELETED_STRUCTURAL_HEADING_VERSION=2','WHOLE_ADDED_STRUCTURAL_HEADING_VERSION=2','COMMON_RUNIN_HEADING_COLOR_ISOLATION_VERSION=3','ACTIVE_BLANK_BOUNDARY_AFTER_DELETED_PARAGRAPH_VERSION=1','PROJECTION_VISIBLE_ISOLATION_VERSION=1']
 for m in markers: ok &= emit('MARKER_'+re.sub(r'[^A-Za-z0-9]+','_',m),text.count(m)==1,f'count={text.count(m)}')
 ok &= emit('DEFAULT_OLD','DEFAULT_OLD=19bdc838918c9e89a4d4451784dd078e0a0671e1' in text)
 ok &= emit('DEFAULT_NEW','DEFAULT_NEW=93dbca00a6d4e6a494f1eb923223c0bd90ddf765' in text)
 print(f'LOCKED_SCRIPT_CHECK={"PASS" if ok else "FAIL"}'); return 0 if ok else 1
if __name__=='__main__': sys.exit(main())
