#!/usr/bin/env python3
from pathlib import Path
import re, sys
ROOT=Path(__file__).resolve().parents[1]; SCRIPT=ROOT/'reviewdiff.sh'
def repair(source):
 rx=re.compile(r'(?P<prefix>%DIFDELCMD <[ \t]*\n)'r'\n'r'\\begin\{sloppypar\}\n'r'(?P<tail>%DIFDELCMD < %%%\n'r'\\DIFdelend\s+\\DIFaddbegin\s+'r'\\DIFadd\{[.!?][ \t]+\}\\DIFaddend)',re.M)
 repairs=[]
 for m in rx.finditer(source):
  close=source.find(r'\end{sloppypar}',m.end())
  if close<0: continue
  if source.find(r'\begin{sloppypar}',m.end(),close)>=0: continue
  repairs.append((m.start(),m.end(),close,close+len(r'\end{sloppypar}'),m.group('prefix')+'%\n'+m.group('tail')))
 for a,b,c,d,r in reversed(repairs): source=source[:a]+r+source[b:c]+source[d:]
 return source,len(repairs)
def fixture(p='.'):
 return '%DIFDELCMD <\n\n\\begin{sloppypar}\n%DIFDELCMD < %%%\n\\DIFdelend \\DIFaddbegin \\DIFadd{'+p+' }\\DIFaddend\nCOMMON\n\\end{sloppypar}'
def ck(n,v): print(f'{n}={"PASS" if v else "FAIL"}'); return bool(v)
def main():
 text=SCRIPT.read_text(errors='replace') if SCRIPT.is_file() else ''
 section=text[text.find('# ACTIVE_BLANK_BOUNDARY_AFTER_DELETED_PARAGRAPH_VERSION=1'):text.find('# MARKED_ALGORITHMIC_FIT_VERSION=1')]
 ok=ck('RULE_PRESENT',all(x in section for x in ['def repair_active_blank_boundaries(source):','[.!?]','active_blank_boundary_idempotence']))
 ok &= ck('NO_LITERAL_DOT_WE','. We' not in section)
 for p,n in [('.','PERIOD'),('!','EXCLAMATION'),('?','QUESTION')]:
  one,c1=repair(fixture(p)); two,c2=repair(one)
  ok &= ck('POSITIVE_'+n,c1==1); ok &= ck('IDEMPOTENCE_'+n,c2==0 and two==one)
 neg=[fixture().replace('<\n\n\\begin','<\n\\begin'),fixture().replace(r'\DIFadd{. }',r'\DIFadd{word }'),fixture()[:-len(r'\end{sloppypar}')],fixture().replace('COMMON',r'\begin{sloppypar}X\end{sloppypar}')]
 ok &= ck('NEGATIVE_SCOPE',all(repair(x)==(x,0) for x in neg))
 x=fixture('.')+'\nSEP\n'+fixture('?'); one,c1=repair(x); two,c2=repair(one)
 ok &= ck('MULTI_MATCH',c1==2 and c2==0 and two==one)
 print(f'ACTIVE_BLANK_BOUNDARY_TESTS={"PASS" if ok else "FAIL"}'); return 0 if ok else 1
if __name__=='__main__': sys.exit(main())
