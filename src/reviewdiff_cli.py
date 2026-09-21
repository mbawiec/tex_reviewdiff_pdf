#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

VERSION = '1.0.0'
DEFAULT_OLD = '19bdc838918c9e89a4d4451784dd078e0a0671e1'
DEFAULT_NEW = '93dbca00a6d4e6a494f1eb923223c0bd90ddf765'
DEFAULT_MAIN = 'main.tex'
LOCKED_SHA256 = '36f3018e3c7d333dbb6152f112554d1fb101d8fdd5e594af12c28c6a92ce8685'
TOOLS = ['git','tar','pdflatex','bibtex','latexpand','latexdiff','latexrevise','python3','pdfinfo','pdftotext','shasum','cmp','grep','awk','sed','zip','open','pbcopy']

TOOL_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = TOOL_ROOT / 'reviewdiff.sh'

def emit(name, value, detail=''):
    suffix = f' {detail}' if detail else ''
    print(f'{name}={value}{suffix}')

def run(cmd, cwd=None, env=None, capture=False):
    return subprocess.run(cmd, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)

def git(project, *args):
    return run(['git', *args], cwd=project, capture=True)

def resolve_project(value):
    p = Path(value).expanduser().resolve()
    return p

def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def project_args(parser, commits=True):
    parser.add_argument('--project', required=True, help='Repozytorium projektu LaTeX')
    if commits:
        parser.add_argument('--old', default=DEFAULT_OLD)
        parser.add_argument('--new', default=DEFAULT_NEW)
        parser.add_argument('--main', default=DEFAULT_MAIN)

def doctor_checks(project, old, new, main, require_tools=True):
    checks=[]
    def add(name, ok, detail=''):
        checks.append((name,bool(ok),detail)); emit(name,'PASS' if ok else 'FAIL',detail)
    add('TOOL_REVIEWDIFF_PRESENT', SCRIPT.is_file(), str(SCRIPT))
    if SCRIPT.is_file():
        actual=sha256(SCRIPT)
        add('TOOL_REVIEWDIFF_LOCKED_SHA256', actual==LOCKED_SHA256, f'expected={LOCKED_SHA256} actual={actual}')
        syntax=run(['bash','-n',str(SCRIPT)],capture=True)
        add('TOOL_REVIEWDIFF_BASH_SYNTAX', syntax.returncode==0, (syntax.stderr or '').strip())
    add('PROJECT_DIRECTORY', project.is_dir(), str(project))
    top=git(project,'rev-parse','--show-toplevel') if project.is_dir() else None
    is_repo=bool(top and top.returncode==0)
    add('PROJECT_GIT_REPOSITORY',is_repo,(top.stdout.strip() if is_repo else str(project)))
    if is_repo:
        actual_root=Path(top.stdout.strip()).resolve()
        add('PROJECT_IS_REPOSITORY_ROOT',actual_root==project,f'actual={actual_root}')
        old_r=git(project,'rev-parse','--verify',f'{old}^{{commit}}')
        new_r=git(project,'rev-parse','--verify',f'{new}^{{commit}}')
        old_ok=old_r.returncode==0; new_ok=new_r.returncode==0
        add('OLD_COMMIT_AVAILABLE',old_ok,old)
        add('NEW_COMMIT_AVAILABLE',new_ok,new)
        if old_ok:
            x=git(project,'cat-file','-e',f'{old}:{main}'); add('MAIN_IN_OLD',x.returncode==0,f'{old}:{main}')
        if new_ok:
            x=git(project,'cat-file','-e',f'{new}:{main}'); add('MAIN_IN_NEW',x.returncode==0,f'{new}:{main}')
    if require_tools:
        missing=[t for t in TOOLS if shutil.which(t) is None]
        add('REQUIRED_TOOLS',not missing,('missing='+','.join(missing)) if missing else f'count={len(TOOLS)}')
    passed=all(ok for _,ok,_ in checks)
    emit('DOCTOR','PASS' if passed else 'FAIL')
    if not passed and is_repo:
        missing_commits=[name for name,ok,_ in checks if name in ('OLD_COMMIT_AVAILABLE','NEW_COMMIT_AVAILABLE') and not ok]
        if missing_commits:
            emit('HINT','Use --project pointing to the repository that contains OLD, NEW and main.tex')
    return passed

def cmd_doctor(args):
    return 0 if doctor_checks(resolve_project(args.project),args.old,args.new,args.main,not args.skip_tools) else 1

def cmd_run(args):
    project=resolve_project(args.project)
    if not doctor_checks(project,args.old,args.new,args.main,True): return 1
    env=os.environ.copy()
    if args.keep_tmp: env['KEEP_TMP']='1'
    emit('RUN_PROJECT',str(project)); emit('RUN_OLD',args.old); emit('RUN_NEW',args.new); emit('RUN_MAIN',args.main)
    result=run([str(SCRIPT),args.old,args.new,args.main],cwd=project,env=env)
    emit('RUN_RC',result.returncode)
    return result.returncode

def artifact_paths(project, old, new):
    o=git(project,'rev-parse','--short=7',old); n=git(project,'rev-parse','--short=7',new)
    if o.returncode or n.returncode: return None
    stem=f'main-diff-{o.stdout.strip()}-{n.stdout.strip()}'
    return stem, project/f'{stem}.audit.txt', project/f'{stem}.pdf', project/f'{stem}.tex', project/'reviewdiff-auto-diagnostic.zip.txt'

def verify_artifacts(project, old, new):
    paths=artifact_paths(project,old,new)
    if not paths: emit('VERIFY','FAIL','cannot resolve commits'); return False
    stem,audit,pdf,tex,pkg=paths; ok=True
    for name,p in [('AUDIT',audit),('PDF',pdf),('TEX',tex),('PACKAGE',pkg)]:
        good=p.is_file() and p.stat().st_size>0; emit(name+'_PRESENT','PASS' if good else 'FAIL',str(p)); ok &= good
    if not ok: emit('VERIFY','FAIL'); return False
    text=audit.read_text(errors='replace')
    tokens=['REVISION_DIFF_AUDIT=PASS',f'OLD_COMMIT={old}',f'NEW_COMMIT={new}','ACTIVE_BLANK_BOUNDARY_IDEMPOTENCE=PASS','VISIBLE_NORMALIZATION_IDEMPOTENCE=PASS','ACCEPT_NONWHITESPACE_EQUALS_NEW=PASS','DECLINE_NONWHITESPACE_EQUALS_OLD=PASS','WHOLE_ADDED_STRUCTURAL_HEADING_IDEMPOTENCE=PASS','WHOLE_DELETED_STRUCTURAL_HEADING_IDEMPOTENCE=PASS','COMMON_HEADING_COLOR_IDEMPOTENCE=PASS']
    gates=all(t in text for t in tokens); emit('AUDIT_GATES','PASS' if gates else 'FAIL'); ok &= gates
    try:
        with tempfile.TemporaryDirectory(prefix='reviewdiff-verify-') as td:
            td=Path(td)
            with zipfile.ZipFile(pkg) as z:z.extractall(td)
            exact_a=sha256(td/'tmp/accept.tex')==sha256(td/'tmp/new-flat.tex')
            exact_d=sha256(td/'tmp/decline.tex')==sha256(td/'tmp/old-flat.tex')
            emit('ACCEPT_EXACT_NEW','PASS' if exact_a else 'FAIL'); emit('DECLINE_EXACT_OLD','PASS' if exact_d else 'FAIL'); ok &= exact_a and exact_d
            diff=td/'git/old-new.binary.diff'; work=td/'apply'; shutil.copytree(td/'tmp/old',work)
            c=run(['git','apply','--check','--binary',str(diff)],cwd=work,capture=True); emit('GIT_APPLY_CHECK','PASS' if c.returncode==0 else 'FAIL'); ok &= c.returncode==0
            c=run(['git','apply','--binary',str(diff)],cwd=work,capture=True); emit('GIT_APPLY','PASS' if c.returncode==0 else 'FAIL'); ok &= c.returncode==0
            pairs=re.findall(r'^diff --git a/(.*?) b/(.*?)$',diff.read_text(errors='replace'),re.M)
            matched=sum((work/b).is_file() and (td/'tmp/new'/b).is_file() and sha256(work/b)==sha256(td/'tmp/new'/b) for _,b in pairs)
            coverage=bool(pairs) and matched==len(pairs); emit('GIT_CHANGED_PATHS','PASS' if coverage else 'FAIL',f'matched={matched} total={len(pairs)}'); ok &= coverage
    except Exception as exc:
        emit('DIAGNOSTIC_VALIDATION','FAIL',str(exc)); ok=False
    emit('VERIFY','PASS' if ok else 'FAIL'); return ok

def cmd_verify(args):
    project=resolve_project(args.project)
    return 0 if verify_artifacts(project,args.old,args.new) else 1

def cmd_test_quick(args):
    tests=[TOOL_ROOT/'tests/check_locked_script.py',TOOL_ROOT/'tests/test_active_blank_boundary.py']; ok=True
    for test in tests:
        emit('TEST_FILE',str(test)); r=run(['python3',str(test)],cwd=TOOL_ROOT); emit('TEST_RC',r.returncode); ok &= r.returncode==0
    emit('TEST_QUICK','PASS' if ok else 'FAIL'); return 0 if ok else 1

def cmd_test_full(args):
    project=resolve_project(args.project)
    if not doctor_checks(project,args.old,args.new,args.main,True): return 1
    q=cmd_test_quick(args)
    if q: return q
    env=os.environ.copy()
    if args.keep_tmp: env['KEEP_TMP']='1'
    r=run([str(SCRIPT),args.old,args.new,args.main],cwd=project,env=env); emit('CANONICAL_PIPELINE_RC',r.returncode)
    if r.returncode: return r.returncode
    return 0 if verify_artifacts(project,args.old,args.new) else 1

def cmd_extract(args):
    project=resolve_project(args.project); pkg=project/'reviewdiff-auto-diagnostic.zip.txt'; out=Path(args.output).expanduser().resolve()
    if not pkg.is_file(): emit('PACKAGE_PRESENT','FAIL',str(pkg)); return 1
    try:
        with zipfile.ZipFile(pkg) as z: data=z.read('git/old-new.binary.diff')
        out.write_bytes(data); emit('OUTPUT','PASS',str(out)); emit('OUTPUT_BYTES',len(data)); emit('OUTPUT_SHA256',hashlib.sha256(data).hexdigest()); return 0
    except Exception as exc: emit('EXTRACT','FAIL',str(exc)); return 1

def build_parser():
    p=argparse.ArgumentParser(prog='reviewdiff',description='CLI dla reviewdiff.sh działający na zewnętrznym repozytorium projektu')
    p.add_argument('--version',action='version',version=f'%(prog)s {VERSION}')
    sub=p.add_subparsers(dest='command',required=True)
    d=sub.add_parser('doctor'); project_args(d); d.add_argument('--skip-tools',action='store_true'); d.set_defaults(func=cmd_doctor)
    r=sub.add_parser('run'); project_args(r); r.add_argument('--keep-tmp',action='store_true'); r.set_defaults(func=cmd_run)
    v=sub.add_parser('verify'); project_args(v); v.set_defaults(func=cmd_verify)
    e=sub.add_parser('extract-git-diff'); e.add_argument('--project',required=True); e.add_argument('--output',default='old-new.binary.diff'); e.set_defaults(func=cmd_extract)
    t=sub.add_parser('test'); ts=t.add_subparsers(dest='test_command',required=True)
    q=ts.add_parser('quick'); q.set_defaults(func=cmd_test_quick)
    f=ts.add_parser('full'); project_args(f); f.add_argument('--keep-tmp',action='store_true'); f.set_defaults(func=cmd_test_full)
    return p

def main(argv=None):
    args=build_parser().parse_args(argv); return args.func(args)
