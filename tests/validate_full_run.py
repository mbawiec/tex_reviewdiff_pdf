#!/usr/bin/env python3
from pathlib import Path
import hashlib,re,shutil,subprocess,sys,tempfile,zipfile
ROOT=Path(__file__).resolve().parents[1]; STEM='main-diff-19bdc83-93dbca0'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def emit(n,v,d=''): print(f'{n}={"PASS" if v else "FAIL"}'+(f' {d}' if d else '')); return bool(v)
def main():
 audit=ROOT/f'{STEM}.audit.txt'; pkg=ROOT/'reviewdiff-auto-diagnostic.zip.txt'; pdf=ROOT/f'{STEM}.pdf'; tex=ROOT/f'{STEM}.tex'
 ok=all(emit(n+'_PRESENT',p.is_file() and p.stat().st_size>0,str(p)) for n,p in [('AUDIT',audit),('PDF',pdf),('TEX',tex),('PACKAGE',pkg)])
 if not ok:return 1
 a=audit.read_text(errors='replace')
 req=['REVISION_DIFF_AUDIT=PASS','OLD_COMMIT=19bdc838918c9e89a4d4451784dd078e0a0671e1','NEW_COMMIT=93dbca00a6d4e6a494f1eb923223c0bd90ddf765','ACTIVE_BLANK_BOUNDARY_REPAIRS=1','ACTIVE_BLANK_BOUNDARY_IDEMPOTENCE=PASS','VISIBLE_NORMALIZATION_IDEMPOTENCE=PASS','ACCEPT_NONWHITESPACE_EQUALS_NEW=PASS','DECLINE_NONWHITESPACE_EQUALS_OLD=PASS','WHOLE_ADDED_STRUCTURAL_HEADING_IDEMPOTENCE=PASS','WHOLE_DELETED_STRUCTURAL_HEADING_IDEMPOTENCE=PASS','COMMON_HEADING_COLOR_IDEMPOTENCE=PASS','BIB_CROSS_KEY_PAIRINGS=0','NESTED_MBOX_DIFDELMATH=0','UNSTRUCK_DELETED_DISPLAY_MATH=0']
 ok &= emit('AUDIT_GATES',all(x in a for x in req))
 with tempfile.TemporaryDirectory(prefix='reviewdiff-validate-') as d:
  d=Path(d)
  with zipfile.ZipFile(pkg) as z:z.extractall(d)
  ok &= emit('ACCEPT_EXACT_NEW',sha(d/'tmp/accept.tex')==sha(d/'tmp/new-flat.tex'))
  ok &= emit('DECLINE_EXACT_OLD',sha(d/'tmp/decline.tex')==sha(d/'tmp/old-flat.tex'))
  diff=d/'git/old-new.binary.diff'; work=d/'apply'; shutil.copytree(d/'tmp/old',work)
  c=subprocess.run(['git','apply','--check','--binary',str(diff)],cwd=work,capture_output=True,text=True); ok &= emit('GIT_APPLY_CHECK',c.returncode==0)
  c=subprocess.run(['git','apply','--binary',str(diff)],cwd=work,capture_output=True,text=True); ok &= emit('GIT_APPLY',c.returncode==0)
  paths=re.findall(r'^diff --git a/(.*?) b/(.*?)$',diff.read_text(errors='replace'),re.M); matched=sum((work/b).is_file() and (d/'tmp/new'/b).is_file() and sha(work/b)==sha(d/'tmp/new'/b) for _,b in paths)
  ok &= emit('GIT_CHANGED_PATHS',len(paths)>0 and matched==len(paths),f'matched={matched} total={len(paths)}')
 print(f'FULL_RUN_VALIDATION={"PASS" if ok else "FAIL"}'); return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
