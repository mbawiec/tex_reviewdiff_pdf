#!/usr/bin/env bash
# Usage: KEEP_TMP=1 ./reviewdiff.sh OLD_COMMIT NEW_COMMIT [main.tex]
# Run this file; do not source it.

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  printf '%s\n' 'ERROR: run ./reviewdiff.sh; do not source it.' >&2
  return 2
fi

# Canonical comparison used by this project. Arguments remain available for
# an explicit comparison, but the normal project workflow is simply:
#   ./reviewdiff.sh
DEFAULT_OLD=19bdc838918c9e89a4d4451784dd078e0a0671e1
DEFAULT_NEW=93dbca00a6d4e6a494f1eb923223c0bd90ddf765
OLD=${1-$DEFAULT_OLD}
NEW=${2-$DEFAULT_NEW}
MAIN=${3-main.tex}

if [ "$#" -eq 1 ]; then
  printf '%s\n' 'Usage: ./reviewdiff.sh [OLD_COMMIT NEW_COMMIT [main.tex]]' >&2
  exit 2
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'MISSING_TOOL=%s\n' "$1" >&2
    exit 2
  }
}

for tool in git tar pdflatex bibtex latexpand latexdiff latexrevise python3 pdfinfo pdftotext shasum cmp grep awk sed zip open pbcopy; do
  need "$tool"
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 2
cd "$ROOT" || exit 2

OLD_FULL=$(git rev-parse --verify "${OLD}^{commit}") || exit 2
NEW_FULL=$(git rev-parse --verify "${NEW}^{commit}") || exit 2
OLD_SHORT=$(git rev-parse --short=7 "$OLD_FULL") || exit 2
NEW_SHORT=$(git rev-parse --short=7 "$NEW_FULL") || exit 2
STEM="main-diff-${OLD_SHORT}-${NEW_SHORT}"
OUT_TEX="$ROOT/${STEM}.tex"
OUT_PDF="$ROOT/${STEM}.pdf"
OUT_AUDIT="$ROOT/${STEM}.audit.txt"

# Never report or publish artifacts left by an earlier run.
rm -f "$OUT_TEX" "$OUT_PDF" "$OUT_AUDIT"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/reviewdiff.XXXXXX") || exit 2

cleanup() {
  if [ "${KEEP_TMP:-0}" = 1 ]; then
    printf 'TMP_DIR=%s\n' "$TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

exec > >(tee "$OUT_AUDIT") 2>&1

failed=0
fail_reason=NONE
fail() {
  if [ "$failed" -eq 0 ]; then
    failed=1
    fail_reason=$1
  fi
}
metric() { printf '%s=%s\n' "$1" "$2"; }

OLD_DIR="$TMP/old"
NEW_DIR="$TMP/new"
mkdir -p "$OLD_DIR" "$NEW_DIR" || exit 2

git archive "$OLD_FULL" | tar -x -C "$OLD_DIR" || fail OLD_ARCHIVE
git archive "$NEW_FULL" | tar -x -C "$NEW_DIR" || fail NEW_ARCHIVE
[ -f "$OLD_DIR/$MAIN" ] || fail OLD_MAIN_NOT_FOUND
[ -f "$NEW_DIR/$MAIN" ] || fail NEW_MAIN_NOT_FOUND

copy_assets() {
  dst=$1
  for dir in figures bibliography bib styles; do
    if [ -e "$ROOT/$dir" ] && [ ! -e "$dst/$dir" ]; then
      cp -R "$ROOT/$dir" "$dst/$dir"
    fi
  done
  find "$ROOT" -maxdepth 1 -type f \( -name '*.bib' -o -name '*.bst' -o -name '*.cls' -o -name '*.sty' \) -exec cp -n {} "$dst/" \; 2>/dev/null
}
copy_assets "$OLD_DIR"
copy_assets "$NEW_DIR"

build_baseline() {
  dir=$1
  job=$2
  cp "$dir/$MAIN" "$dir/$job.tex" || return 1
  (cd "$dir" && pdflatex -interaction=nonstopmode -halt-on-error -jobname="$job" "$job.tex" >"$TMP/$job.pass1.log" 2>&1) || return 1
  if grep -q '\\bibdata' "$dir/$job.aux" 2>/dev/null; then
    (cd "$dir" && bibtex "$job" >"$TMP/$job.bibtex.log" 2>&1) || return 1
  else
    : > "$dir/$job.bbl"
  fi
  (cd "$dir" && pdflatex -interaction=nonstopmode -halt-on-error -jobname="$job" "$job.tex" >"$TMP/$job.pass2.log" 2>&1) || return 1
  (cd "$dir" && pdflatex -interaction=nonstopmode -halt-on-error -jobname="$job" "$job.tex" >"$TMP/$job.pass3.log" 2>&1) || return 1
}

build_baseline "$OLD_DIR" baseline-old || fail OLD_BASELINE_BUILD
build_baseline "$NEW_DIR" baseline-new || fail NEW_BASELINE_BUILD

if [ "$failed" -eq 0 ]; then
  (cd "$OLD_DIR" && latexpand --expand-bbl baseline-old.bbl baseline-old.tex) > "$TMP/old-flat.tex" 2> "$TMP/old-flat.err" || fail OLD_EXPAND
  (cd "$NEW_DIR" && latexpand --expand-bbl baseline-new.bbl baseline-new.tex) > "$TMP/new-flat.tex" 2> "$TMP/new-flat.err" || fail NEW_EXPAND
fi

if [ "$failed" -eq 0 ]; then
  latexdiff \
    --append-safecmd='multicolumn' \
    --config='PICTUREENV=(?:picture|tikzpicture|DIFnomarkup)' \
    "$TMP/old-flat.tex" "$TMP/new-flat.tex" \
    > "$TMP/raw-diff.tex" 2> "$TMP/latexdiff.err" || fail LATEXDIFF
fi

if [ "$failed" -eq 0 ]; then
  python3 - "$TMP/raw-diff.tex" "$TMP/old-flat.tex" "$TMP/new-flat.tex" "$TMP/visible-candidate.tex" "$TMP/projection-source.tex" "$TMP/normalization.metrics" "$OLD_DIR/baseline-old.aux" "$NEW_DIR/baseline-new.aux" "$TMP/visible-equivalence-candidates.txt" "${VISIBLE_EQUIVALENCE_ACCEPT:-}" "${VISIBLE_EQUIVALENCE_REJECT:-}" <<'PY'
from pathlib import Path
import re, sys, hashlib, difflib, subprocess, tempfile
raw_path, old_path, new_path, out_path, projection_source_path, metrics_path, old_aux_path, new_aux_path, equivalence_report_path = map(
    Path,
    sys.argv[1:10],
)
user_accept_spec, user_reject_spec = sys.argv[10], sys.argv[11]
raw, old, new = raw_path.read_text(), old_path.read_text(), new_path.read_text()

hskip_rx = re.compile(r"""\\hskip\s+\\DIF(?:add|del)(?:FL)?\{\s*(1em\s+plus\s+0[.]5em\s+minus\s+0[.]4em)\s*\}\\relax""", re.X | re.S)
def hskip_repl(m): return r"\hskip " + re.sub(r"\s+", " ", m.group(1)).strip() + r"\relax"
text, fixed_hskip = hskip_rx.subn(hskip_repl, raw)

# Move a block end from after the final row terminator to before it.
row_rx = re.compile(r"\\\\(?P<ws>\s*)(?P<end>\\DIF(?:add|del)end(?:FL)?)(?P<gap>\s*)(?=\\bottomrule)")
text, fixed_row_boundaries = row_rx.subn(lambda m: m.group('end') + r" \\" + m.group('ws') + m.group('gap'), text)

# latexdiff may leave a content space before deleted joining punctuation.
# Normalize syntactic candidates beginning with -, --, ---, comma, period,
# colon, semicolon, closing parenthesis, or sentence punctuation. Final
# accept/decline equality is the safety proof for the complete transformation.
join_rx = re.compile(
    r"(?P<left>[^\s])(?P<space>[ \t]+)"
    r"(?P<block>\\DIFdelbegin(?:FL)?\s+"
    r"\\DIFdel(?:FL)?\{(?:---|--|-|[,.;:!?)\]]))"
)
text, fixed_join_boundaries = join_rx.subn(
    lambda m: m.group('left') + m.group('block'),
    text,
)

# PROJECTION_VISIBLE_ISOLATION_VERSION=1
#
# The transformations above are content-normalization rules required by
# both the visible marked diff and the accept/decline projections.
# Save the projection source before applying presentation-only repairs.
projection_source_path.write_text(text)

# SOURCE_AWARE_WHOLE_TABLE_RECONSTRUCTION_VERSION=1
# Detect whole-table replacements produced by latexdiff, then rebuild one visible
# table from OLD and NEW. Structural table tokens remain outside DIF arguments.
def read_group(source, opening):
    if opening >= len(source) or source[opening] != '{': return None
    depth, escaped, i = 0, False, opening
    while i < len(source):
        c = source[i]
        if escaped: escaped = False
        elif c == '\\': escaped = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return source[opening + 1:i], i + 1
        i += 1
    return None

def extract_tables(source):
    result, pos = {}, 0
    while True:
        a = source.find(r'\begin{table}', pos)
        if a < 0: break
        b = source.find(r'\end{table}', a)
        if b < 0: break
        b += len(r'\end{table}')
        block = source[a:b]
        label = re.search(re.escape(chr(92) + 'label') + r'{([^}]+)}', block)
        if label: result[label.group(1)] = (a, b, block)
        pos = b
    return result

def split_top(source, separator):
    out, start, depth, i = [], 0, 0, 0
    while i < len(source):
        c = source[i]
        if c == '\\':
            if separator == r'\\' and i + 1 < len(source) and source[i + 1] == '\\' and depth == 0:
                out.append(source[start:i]); start = i + 2; i += 2; continue
            i += 2; continue
        if c == '{': depth += 1
        elif c == '}': depth -= 1
        elif separator == '&' and c == '&' and depth == 0:
            out.append(source[start:i]); start = i + 1
        i += 1
    out.append(source[start:])
    return out

def tabular_parts(block):
    m = re.search(re.escape(r'\begin{tabular}') + r'(\{(?:[^{}]|\{[^{}]*\})*\})', block)
    if not m: return None
    end = block.find(r'\end{tabular}', m.end())
    if end < 0: return None
    return block[:m.end()], block[m.end():end], block[end:]

def norm(value): return re.sub(r'\s+', '', value)

def peel_structure(cell):
    prefix = ''
    rx = re.compile(r'^\s*(\\(?:toprule|midrule|bottomrule|cmidrule(?:\([^)]*\))?\{[^}]+\}))')
    while True:
        m = rx.match(cell)
        if not m: break
        prefix += m.group(0) + '\n'; cell = cell[m.end():]
    return prefix, cell

def mark_changed_cell(old_cell, new_cell):
    op, old_core = peel_structure(old_cell)
    np, new_core = peel_structure(new_cell)
    structure = np or op
    if norm(old_core) == norm(new_core): return structure + new_core
    # Keep multicolumn structural syntax outside markers when topology matches.
    mo = re.fullmatch(r'\s*\\multicolumn\{([^}]*)\}\{([^}]*)\}\{(.*)\}\s*', old_core, re.S)
    mn = re.fullmatch(r'\s*\\multicolumn\{([^}]*)\}\{([^}]*)\}\{(.*)\}\s*', new_core, re.S)
    if mo and mn and mo.group(1,2) == mn.group(1,2):
        return structure + r'\multicolumn{' + mn.group(1) + '}{' + mn.group(2) + '}{' + r'\DIFdelFL{' + mo.group(3) + '} ' + r'\DIFaddFL{' + mn.group(3) + '}}'
    return structure + r'\DIFdelFL{' + old_core.strip() + '} ' + r'\DIFaddFL{' + new_core.strip() + '}'

def merge_tabular(old_block, new_block):
    po, pn = tabular_parts(old_block), tabular_parts(new_block)
    if not po or not pn: return None
    old_open, old_body, _ = po; new_open, new_body, new_close = pn
    new_open = new_open[new_open.rfind(r'\begin{tabular}'): ]
    new_close = r'\end{tabular}'
    old_rows, new_rows = split_top(old_body, r'\\'), split_top(new_body, r'\\')
    if len(old_rows) != len(new_rows): return None
    merged_rows = []
    for old_row, new_row in zip(old_rows, new_rows):
        oc, nc = split_top(old_row, '&'), split_top(new_row, '&')
        if len(oc) != len(nc): return None
        merged_rows.append(' & '.join(mark_changed_cell(a, b) for a, b in zip(oc, nc)))
    return new_open + (r'\\'.join(merged_rows)) + new_close

old_tables, new_tables, raw_tables = extract_tables(old), extract_tables(new), extract_tables(text)
repairs, whole_table_candidates, whole_table_fixed = [], 0, 0
for label, (a, b, raw_block) in raw_tables.items():
    if label not in old_tables or label not in new_tables: continue
    if norm(old_tables[label][2]) == norm(new_tables[label][2]): continue
    # This is the latexdiff whole-replacement signature: old tabular commented
    # under DIFdelbeginFL and a complete active new tabular under DIFaddbeginFL.
    if '%DIFDELCMD < \\resizebox' not in raw_block or r'\DIFaddbeginFL \resizebox' not in raw_block:
        continue
    whole_table_candidates += 1
    merged_tabular = merge_tabular(old_tables[label][2], new_tables[label][2])
    if not merged_tabular: raise SystemExit('WHOLE_TABLE_TOPOLOGY_MISMATCH=' + label)
    new_block = new_tables[label][2]
    parts = tabular_parts(new_block)
    rebuilt = parts[0][:parts[0].rfind(r'\begin{tabular}')] + merged_tabular + parts[2][len(r'\end{tabular}'):]
    # Mark a changed caption while preserving one caption and one label.
    def caption_span(block):
        command = block.find(r'\caption')
        if command < 0: return None
        opening = command + len(r'\caption')
        while opening < len(block) and block[opening].isspace(): opening += 1
        group = read_group(block, opening)
        if not group: return None
        body, end = group
        return command, opening, end, body
    old_cap, new_cap = caption_span(old_tables[label][2]), caption_span(rebuilt)
    if old_cap and new_cap and norm(old_cap[3]) != norm(new_cap[3]):
        replacement = r'\caption{\DIFdelFL{' + old_cap[3] + r'} \DIFaddFL{' + new_cap[3] + r'}}'
        rebuilt = rebuilt[:new_cap[0]] + replacement + rebuilt[new_cap[2]:]
    repairs.append((a, b, rebuilt)); whole_table_fixed += 1
for a, b, replacement in reversed(repairs): text = text[:a] + replacement + text[b:]

# VISIBLE_LAYOUT_FIXES_VERSION=1

# Preserve the blue frame around added graphics without increasing the
# occupied width by 2*(\fboxsep+\fboxrule).
added_graphics_old = (
    r"\providecommand{\DIFaddincludegraphics}[2][]"
    r"{{\color{blue}\fbox{\DIFOincludegraphics[#1]{#2}}}}"
    r" %DIF PREAMBLE"
)
added_graphics_new = (
    r"\providecommand{\DIFaddincludegraphics}[2][]{%" "\n"
    r"\begingroup%" "\n"
    r"\setlength{\fboxsep}{-\fboxrule}%" "\n"
    r"{\color{blue}\fbox{\DIFOincludegraphics[#1]{#2}}}%" "\n"
    r"\endgroup%" "\n"
    r"} %DIF PREAMBLE"
)
raw_added_graphics_frames = text.count(added_graphics_old)
if raw_added_graphics_frames != 1:
    raise SystemExit(
        f'RAW_ADDED_GRAPHICS_FRAMES={raw_added_graphics_frames}; expected 1'
    )
text = text.replace(added_graphics_old, added_graphics_new, 1)
fixed_added_graphics_frames = raw_added_graphics_frames

# Restore an ampersand and row terminator hidden by latexdiff comments in
# a deleted FL table row. Structural tokens remain outside DIFdelFL.
commented_deleted_row_rx = re.compile(
    r"(?P<left>"
    r"\\DIFdelbeginFL[ \t]+"
    r"\\DIFdelFL\{[^\n]*\}"
    r")"
    r"[ \t]*%DIFDELCMD[ \t]*<[ \t]*&[ \t]*%%%"
    r"[ \t]*\n"
    r"(?P<right>"
    r"\\DIFdelFL\{[^\n]*\}"
    r")"
    r"[ \t]*%DIFDELCMD[ \t]*<[ \t]*\\\\[ \t]*\n"
    r"[ \t]*%DIFDELCMD[ \t]*<[^\n]*%%%"
)

def restore_commented_deleted_row(match):
    return match.group('left') + ' &\n' + match.group('right') + r' \\'

raw_commented_deleted_row_boundaries = len(
    commented_deleted_row_rx.findall(text)
)
text, fixed_commented_deleted_row_boundaries = commented_deleted_row_rx.subn(
    restore_commented_deleted_row, text
)
remaining_commented_deleted_row_boundaries = len(
    commented_deleted_row_rx.findall(text)
)

# Scale only marked, otherwise unscaled, two-column ll tables. This runs
# after structural row reconstruction and is independent of labels.
marked_ll_table_rx = re.compile(
    r"(?P<indent>^[ \t]*)(?P<table>\\begin\{tabular\}\{ll\}"
    r"(?P<body>.*?)\\end\{tabular\})",
    re.M | re.S,
)

def scale_marked_ll_tables(source):
    repairs = []
    for match in marked_ll_table_rx.finditer(source):
        if not re.search(r"\\DIF(?:add|del)(?:begin|end|FL)", match.group('body')):
            continue
        prefix = source[max(0, match.start() - 256):match.start()]
        if re.search(r"\\resizebox\{(?:0[.]94)?\\columnwidth\}\{!\}\{%\s*$", prefix):
            continue
        replacement = (
            r"\resizebox{\columnwidth}{!}{%" + "\n"
            + match.group('table') + "\n" + match.group('indent') + "}"
        )
        repairs.append((match.start(), match.end(), replacement))
    for begin, end, replacement in reversed(repairs):
        source = source[:begin] + replacement + source[end:]
    return source, len(repairs)

text, scaled_marked_ll_tables = scale_marked_ll_tables(text)

# MARKED_WIDE_TABLE_SCALE_VERSION=1
#
# Scale a marked six-column capacity-style table only after its table
# structure has been normalized. The rule depends on the column format
# and the presence of visible DIF markers, not on a label or line number.
marked_wide_table_rx = re.compile(
    r"(?P<indent>^[ \t]*)"
    r"(?P<table>"
    r"\\begin\{tabular\}"
    r"\{l@\{\\hspace\{2pt\}\}ccrrc\}"
    r"(?P<body>.*?)"
    r"\\end\{tabular\}"
    r")",
    re.M | re.S,
)

def scale_marked_wide_tables(source):
    repairs = []

    for match in marked_wide_table_rx.finditer(source):
        if not re.search(
            r"\\DIF(?:add|del)(?:begin|end|FL)",
            match.group("body"),
        ):
            continue

        prefix = source[
            max(0, match.start() - 256):
            match.start()
        ]

        if re.search(
            r"\\resizebox\{(?:0[.]94)?\\columnwidth\}\{!\}\{%\s*$",
            prefix,
        ):
            continue

        replacement = (
            r"\resizebox{\columnwidth}{!}{%"
            + "\n"
            + match.group("table")
            + "\n"
            + match.group("indent")
            + "}"
        )

        repairs.append(
            (
                match.start(),
                match.end(),
                replacement,
            )
        )

    for begin, end, replacement in reversed(repairs):
        source = (
            source[:begin]
            + replacement
            + source[end:]
        )

    return source, len(repairs)

text, scaled_marked_wide_tables = (
    scale_marked_wide_tables(text)
)

# VISUAL_DEFECTS_V2=1
# Presentation-only repairs; projection-source.tex has already been saved.
deleted_link_old = r"\providecommand{\DIFdeltex}[1]{{\protect\color{red}\sout{#1}}} %DIF PREAMBLE"
deleted_link_new = r"\providecommand{\DIFdeltex}[1]{{\protect\hypersetup{linkcolor=red,citecolor=red,urlcolor=red}\color{red}\sout{#1}}} %DIF PREAMBLE"
added_link_old = r"\providecommand{\DIFaddtex}[1]{{\protect\color{blue}\uwave{#1}}} %DIF PREAMBLE"
added_link_new = r"\providecommand{\DIFaddtex}[1]{{\protect\hypersetup{linkcolor=blue,citecolor=blue,urlcolor=blue}\color{blue}\uwave{#1}}} %DIF PREAMBLE"
raw_added_link_color = text.count(added_link_old)
if raw_added_link_color != 1:
    raise SystemExit(f'RAW_ADDED_LINK_COLOR_DEFINITIONS={raw_added_link_color}; expected 1')
text = text.replace(added_link_old, added_link_new, 1)
fixed_added_link_color = 1

raw_deleted_link_color = text.count(deleted_link_old)
if raw_deleted_link_color != 1:
    raise SystemExit(f'RAW_DELETED_LINK_COLOR_DEFINITIONS={raw_deleted_link_color}; expected 1')
text = text.replace(deleted_link_old, deleted_link_new, 1)
fixed_deleted_link_color = 1

# Keep block-level FL markers semantically empty. Some latexdiff outputs
# contain an unmatched beginFL in captions or moved floats; assigning TeX
# grouping or color state to those markers makes otherwise valid markup fail.
# Visible color remains the responsibility of DIFaddFL/DIFdelFL.
raw_colored_fl_block_definitions = 0
fixed_colored_fl_block_definitions = 0

# Permit line breaking in long prose paragraphs containing both OLD and NEW.
def wrap_long_mixed_paragraphs(source):
    document = re.search(r"\\begin\{document\}", source)
    if not document:
        raise SystemExit('missing begin{document}')
    head, body = source[:document.end()], source[document.end():]
    chunks = re.split(r"(\n[ \t]*\n)", body)
    repairs = 0
    for index in range(0, len(chunks), 2):
        paragraph = chunks[index]
        if len(paragraph) < 900:
            continue
        if r'\DIFdelbegin' not in paragraph or r'\DIFaddbegin' not in paragraph:
            continue
        # sloppypar must never wrap or cross any LaTeX environment.
        # Environment-specific allow/deny lists are unsafe because theorem-like
        # environments (proof, proposition, definition, remark, etc.) are open-ended.
        if r'\begin{' in paragraph or r'\end{' in paragraph:
            continue
        chunks[index] = "\\begin{sloppypar}\n" + paragraph + "\n\\end{sloppypar}"
        repairs += 1
    return head + ''.join(chunks), repairs

text, wrapped_long_mixed_paragraphs = wrap_long_mixed_paragraphs(text)


# ACTIVE_BLANK_BOUNDARY_AFTER_DELETED_PARAGRAPH_VERSION=1
# Presentation only. projection-source.tex was saved before this pass.
# A blank physical line between a latexdiff deletion comment and the matching
# DIFdelend starts a TeX paragraph before a punctuation-only addition. If the
# long mixed paragraph wrapper begins at that boundary, activate the blank line
# as a comment and remove the matching wrapper pair. No text, label, or source
# line is hard-coded.
def repair_active_blank_boundaries(source):
    boundary_rx = re.compile(
        r'(?P<prefix>%DIFDELCMD <[ \t]*\n)'
        r'\n'
        r'\\begin\{sloppypar\}\n'
        r'(?P<tail>%DIFDELCMD < %%%\n'
        r'\\DIFdelend\s+\\DIFaddbegin\s+'
        r'\\DIFadd\{[.!?][ \t]+\}\\DIFaddend)',
        re.M,
    )
    repairs = []
    for match in boundary_rx.finditer(source):
        close = source.find(r'\end{sloppypar}', match.end())
        if close < 0:
            continue
        nested = source.find(r'\begin{sloppypar}', match.end(), close)
        if nested >= 0:
            continue
        replacement = match.group('prefix') + '%\n' + match.group('tail')
        repairs.append((match.start(), match.end(), close,
                        close + len(r'\end{sloppypar}'), replacement))
    for begin, end, close_begin, close_end, replacement in reversed(repairs):
        source = (source[:begin] + replacement + source[end:close_begin]
                  + source[close_end:])
    return source, len(repairs)

text, active_blank_boundary_repairs = repair_active_blank_boundaries(text)
_active_blank_second, active_blank_boundary_second_repairs = repair_active_blank_boundaries(text)
active_blank_boundary_idempotence = (
    'PASS'
    if active_blank_boundary_second_repairs == 0
    and _active_blank_second == text
    else 'FAIL'
)

# MARKED_ALGORITHMIC_FIT_VERSION=1
# Scale typography inside marked algorithmic environments when long DIF-wrapped
# pseudocode tokens are intrinsically unbreakable. This is presentation-only,
# independent of labels and line numbers, and does not alter projections.
marked_algorithmic_rx = re.compile(
    r"(?P<open>\\begin\{algorithmic\}\[1\]\s*\n)"
    r"(?P<size>\\footnotesize)"
    r"(?P<body>.*?)"
    r"(?P<close>\\end\{algorithmic\})",
    re.S,
)
def fit_marked_algorithmic(match):
    body = match.group('body')
    if not re.search(r"\\DIF(?:add|del)(?:begin|end|FL)", body):
        return match.group(0)
    return (match.group('open') + r"\fontsize{6}{7}\selectfont" + body + match.group('close'))
text, fitted_marked_algorithmic = marked_algorithmic_rx.subn(fit_marked_algorithmic, text)

# Rebuild the changed H_down equation as two explicit colored lines.
hdown_rx = re.compile(
    r"\\begin\{equation\}\s*H_\{\\mathrm\{down\}\}.*?\\label\{eq:hmac_down\}\s*\\end\{equation\}",
    re.S,
)
hdown_replacement = """\\begin{equation}
\\begin{aligned}
\\DIFdel{H_{\\mathrm{down}}} &\\DIFdel{= \\operatorname{HMAC-SHA-256}\\!\\left(\\kappa_{\\mathrm{net}},\\,\\mathrm{ACK\\_vec}\\mathbin{\\Vert}c_{\\mathrm{net}}\\right)} \\\\
\\DIFadd{H_{\\mathrm{down}}} &\\DIFadd{= \\operatorname{HMAC-SHA-256}\\!\\left(\\kappa_{\\mathrm{net}},\\,\\mathit{IND}_{\\mathrm{data}}\\right).}
\\end{aligned}
\\label{eq:hmac_down}
\\end{equation}"""
text, fixed_hdown_equations = hdown_rx.subn(lambda _: hdown_replacement, text)
if fixed_hdown_equations != 1:
    raise SystemExit(f'FIXED_HDOWN_EQUATIONS={fixed_hdown_equations}; expected 1')

# Keep the marked six-column table visibly inside the IEEE column.
text, tightened_marked_wide_tables = re.subn(
    r"\\resizebox\{\\columnwidth\}\{!\}\{%\n(?=\\begin\{tabular\}\{l@\{\\hspace\{2pt\}\}ccrrc\})",
    r"\\resizebox{0.94\\columnwidth}{!}{%\n",
    text,
)
if scaled_marked_wide_tables and tightened_marked_wide_tables != scaled_marked_wide_tables:
    raise SystemExit('TIGHTENED_MARKED_WIDE_TABLES_COUNT_MISMATCH')

# Source-aware reconstruction of references inside deleted payloads.
def _group(src, start):
    depth = 0
    i = start
    while i < len(src):
        if src[i] == '\\':
            i += 2; continue
        if src[i] == '{': depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0: return src[start+1:i], i+1
        i += 1
    raise ValueError('unbalanced group')

# Structural layout repair for marked headings and theorem-like environments.
# This is presentation-only: projection-source.tex was saved before this pass.
# 1) Section headings containing DIF markers are set ragged-right so strikeout
#    fragments cannot stretch the heading across the complete IEEE column.
# PARAGRAPH_HEADING_COLOR_RESET_FIX32C=1
# Presentation only. IEEEtran generates the paragraph label, e.g. "b)",
# before processing the heading argument. Reset color before \paragraph
# so both the generated label and the heading text start in normal color.
_paragraph_heading_rx = re.compile(
    r'(?<!\\normalcolor)\\paragraph\{(?:\\protect\\normalcolor\s+)?',
    re.M,
)
text, paragraph_heading_color_resets = _paragraph_heading_rx.subn(
    r'\\normalcolor\\paragraph{',
    text,
)
remaining_unreset_paragraph_headings = len(
    _paragraph_heading_rx.findall(text)
)

def _repair_marked_section_headings(source):
    commands = re.compile(r'\\(section|subsection|subsubsection)\{')
    out=[]; pos=0; candidates=fixed=0
    for match in list(commands.finditer(source)):
        if match.start() < pos: continue
        try: title,end=_group(source,match.end()-1)
        except ValueError: continue
        if not re.search(r'\\DIF(?:add|del)(?:begin|end|FL)?\b',title): continue
        candidates += 1
        if title.lstrip().startswith(r'\protect\raggedright'):
            continue
        out.append(source[pos:match.end()])
        out.append(r'\protect\raggedright ' + title + '}')
        pos=end; fixed += 1
    out.append(source[pos:])
    return ''.join(out),candidates,fixed

text, marked_heading_candidates, marked_heading_fixed = _repair_marked_section_headings(text)

# 2) If a theorem-like body begins with a visible DIF wrapper, force the theorem
#    heading to finish as a normal non-justified line before the marked body.
_theorem_start_rx = re.compile(
    r'(\\begin\{(?:theorem|proposition|lemma|definition|remark|corollary)\}'
    r'(?:\[[^\]]*\])?\s*(?:\\label\{[^}]+\}\s*)?)'
    r'(?=\\DIF(?:add|del)(?:begin|FL)?\b)', re.S)
_theorem_break = r'\leavevmode\par\noindent '

def _repair_theorem_starts(source):
    candidates=len(_theorem_start_rx.findall(source))
    repaired,fixed=_theorem_start_rx.subn(lambda m:m.group(1)+_theorem_break,source)
    return repaired,candidates,fixed

text, theorem_heading_candidates, theorem_heading_fixed = _repair_theorem_starts(text)
_, _, remaining_marked_heading_layout = _repair_marked_section_headings(text)
remaining_theorem_heading_layout = len(_theorem_start_rx.findall(text))

# Key-aware bibliography reconstruction. Bibliography records are matched only
# by exact bibitem key. This visible reconstruction is presentation-only;
# projection-source.tex remains the original full-document candidate.
def _bibliography_region(source):
    begin = source.find(r'\begin{thebibliography}')
    if begin < 0: return None
    open_brace = source.find('{', begin + len(r'\begin{thebibliography}'))
    if open_brace < 0: return None
    try: width, body_start = _group(source, open_brace)
    except ValueError: return None
    end = source.find(r'\end{thebibliography}', body_start)
    if end < 0: return None
    return begin, body_start, end, end + len(r'\end{thebibliography}'), width

def _bib_records(source):
    region = _bibliography_region(source)
    if region is None: return [], {}, {}, None
    _, body_start, end, _, _ = region
    body = source[body_start:end]
    matches = list(re.finditer(
        r'(?m)^\\bibitem(?P<label>\[[^\]]*\])?\{(?P<key>[^}]+)\}\s*',
        body,
    ))
    order=[]; records={}; labels={}
    for index,match in enumerate(matches):
        key=match.group('key')
        item_end=matches[index+1].start() if index+1<len(matches) else len(body)
        order.append(key)
        records[key]=body[match.end():item_end].strip()+"\n"
        labels[key]=match.group('label') or ''
    return order,records,labels,region

def _latexdiff_body(old_body,new_body):
    if old_body == new_body: return new_body
    with tempfile.TemporaryDirectory(prefix='reviewdiff-bib-') as directory:
        directory=Path(directory)
        old_file=directory/'old.tex'; new_file=directory/'new.tex'
        prefix='\\documentclass{article}\n\\usepackage{xcolor}\n\\usepackage{url}\n\\begin{document}\n'
        suffix='\n\\end{document}\n'
        old_file.write_text(prefix+old_body+suffix)
        new_file.write_text(prefix+new_body+suffix)
        result=subprocess.run(['latexdiff','--flatten',str(old_file),str(new_file)],
                              text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if result.returncode != 0:
            raise SystemExit('BIB_ENTRY_LATEXDIFF_FAILED='+result.stderr[-500:].replace('\n',' '))
        output=result.stdout
        a=output.find(r'\begin{document}')+len(r'\begin{document}')
        b=output.rfind(r'\end{document}')
        if a < len(r'\begin{document}') or b < a:
            raise SystemExit('BIB_ENTRY_LATEXDIFF_EXTRACTION_FAILED')
        return output[a:b].strip()+"\n"

def _mark_deleted_bib_record(body, limit=48):
    # Mark the actual OLD-only record, not a synthetic deletion sentinel.
    # Split prose into short DIFdel chunks so ulem can break lines in narrow
    # IEEE bibliography columns. Recurse into standalone brace groups and
    # common style commands so long protected titles remain breakable.
    style_commands=('emph','textit','textbf','texttt')

    def mark_plain(value):
        chunks=[]; start=0; i=0; last_space=None
        while i < len(value):
            if value[i].isspace():
                last_space=i
                if i-start >= limit:
                    cut=last_space+1
                    chunks.append(value[start:cut]); start=cut; last_space=None
            i += 1
        if start < len(value): chunks.append(value[start:])
        return ''.join(r'\DIFdel{' + chunk + '}' for chunk in chunks if chunk)

    def render(value):
        out=[]; plain=[]; i=0
        def flush():
            if plain:
                out.append(mark_plain(''.join(plain))); plain.clear()
        while i < len(value):
            matched=None
            for name in style_commands:
                token='\\'+name+'{'
                if value.startswith(token,i):
                    matched=(name,token); break
            if matched:
                flush()
                name,token=matched
                opening=i+len(token)-1
                try: inner,end=_group(value,opening)
                except ValueError: raise SystemExit('BIB_DELETED_STYLE_GROUP_UNBALANCED')
                out.append('\\'+name+'{'+render(inner)+'}')
                i=end
                continue
            if value[i] == '{':
                flush()
                try: inner,end=_group(value,i)
                except ValueError: raise SystemExit('BIB_DELETED_RECORD_UNBALANCED')
                out.append('{'+render(inner)+'}')
                i=end
                continue
            plain.append(value[i]); i += 1
        flush()
        return ''.join(out)

    return render(body)

def _build_key_aware_bibliography(old_source,new_source):
    old_order,old_records,old_labels,old_region=_bib_records(old_source)
    new_order,new_records,new_labels,new_region=_bib_records(new_source)
    if old_region is None or new_region is None: return None
    old_set,new_set=set(old_order),set(new_order)
    # Historical visible labels for OLD-only records are plain struck text,
    # not active bibitems. They preserve OLD citation semantics without
    # advancing or changing the final NEW bibliography numbering [1]--[28].
    old_visible_number={key:index + 1 for index,key in enumerate(old_order)}
    old_duplicate_keys=len(old_order)-len(old_set)
    new_duplicate_keys=len(new_order)-len(new_set)
    # Numbered bibliography follows NEW exactly. Each OLD-only record is
    # displayed immediately after the active NEW item with the same ordinal.
    deleted_after_number={index + 1: [] for index in range(len(new_order))}
    deleted_at_end=[]
    for key in old_order:
        if key in new_set: continue
        number=old_visible_number[key]
        if number <= len(new_order): deleted_after_number[number].append(key)
        else: deleted_at_end.append(key)

    items=[]; common_changed=old_only=new_only=0; expected_old_only_blocks={}

    def deleted_block(key):
        nonlocal old_only
        historical_label='[' + str(old_visible_number[key]) + ']'
        label=(r'{\hypersetup{linkcolor=red,citecolor=red,urlcolor=red}\color{red}'
               + _mark_deleted_bib_record(historical_label) + r'}')
        body=(r'{\hypersetup{linkcolor=red,citecolor=red,urlcolor=red}\color{red}'
              + _mark_deleted_bib_record(old_records[key].rstrip()) + r'}')
        block=(f'% REVIEWDIFF_OLD_ONLY_BEGIN:{key}:NUMBER={old_visible_number[key]}\n'
               r'\item[]\hspace*{-\labelwidth}\hspace*{-\labelsep}'
               r'\makebox[\labelwidth][r]{' + label + r'}\hspace{\labelsep}' + body + '\n'
               f'% REVIEWDIFF_OLD_ONLY_END:{key}\n')
        expected_old_only_blocks[key]=block
        old_only += 1
        return block

    for new_number,key in enumerate(new_order,1):
        if key in old_set:
            body=_latexdiff_body(old_records[key],new_records[key])
            if old_records[key] != new_records[key]: common_changed+=1
        else:
            body=(r'{\hypersetup{linkcolor=blue,citecolor=blue,urlcolor=blue}\color{blue}'
                  + new_records[key].rstrip() + r'}' + "\n")
            new_only+=1
        label=new_labels.get(key,'')
        items.append(r'\bibitem' + label + '{' + key + '}' + '\n' + body)
        for deleted_key in deleted_after_number.get(new_number,[]):
            items.append(deleted_block(deleted_key))
    for deleted_key in deleted_at_end:
        items.append(deleted_block(deleted_key))

    width=str(max(10,len(new_order)))
    bibliography=r'\begin{thebibliography}{'+width+'}' + '\n\n' + '\n'.join(items) + r'\end{thebibliography}'
    union=list(new_order)+[key for key in old_order if key not in new_set]
    union_set=set(union)
    expected_set=old_set|new_set
    generated_headers=[
        match.group('key')
        for match in re.finditer(
            r'(?m)^\\bibitem(?:\[[^\]]*\])?\{(?P<key>[^}]+)\}',
            bibliography,
        )
    ]
    # Only active numbered bibitems participate in positional key pairing.
    # OLD-only records are intentionally visible as unnumbered deletion rows,
    # so comparing active headers against the 30-key audit union creates
    # exactly two false cross-key pairings.
    cross_key_pairings=sum(
        generated_key != expected_key
        for generated_key,expected_key in zip(generated_headers,new_order)
    ) + abs(len(generated_headers)-len(new_order))
    metrics={'old':len(old_order),'new':len(new_order),'union':len(union),
             'old_only':old_only,'new_only':new_only,'common_changed':common_changed,
             'duplicate':len(union)-len(union_set),
             'old_duplicate':old_duplicate_keys,'new_duplicate':new_duplicate_keys,
             'missing_union':len(expected_set-union_set),
             'unexpected_union':len(union_set-expected_set),
             'cross_key':cross_key_pairings,
             'same_number_placement':sum(len(v) for v in deleted_after_number.values()),
             'label_box_alignment':sum(len(v) for v in deleted_after_number.values()) + len(deleted_at_end),
             'empty':sum(not ((old_records.get(k) or new_records.get(k) or '').strip()) for k in union)}
    return bibliography,metrics,union,expected_old_only_blocks

_bib_result=_build_key_aware_bibliography(old,new)
if _bib_result is None:
    raise SystemExit('KEY_AWARE_BIBLIOGRAPHY_NOT_FOUND')
_keyed_bibliography,bib_metrics,bib_union_keys,bib_expected_old_only_blocks=_bib_result
_visible_bib_region=_bibliography_region(text)
if _visible_bib_region is None:
    raise SystemExit('VISIBLE_BIBLIOGRAPHY_NOT_FOUND')
_b0,_,_,_b1,_=_visible_bib_region
text=text[:_b0]+_keyed_bibliography+text[_b1:]

# Preserve the IEEEtran BBL support declarations that occur before the first
# bibitem. Record extraction intentionally excludes this prologue, but commands
# such as BIBentryALTinterwordspacing depend on it.
def _bib_support_preamble(source):
    region=_bibliography_region(source)
    if region is None: return ''
    _,body_start,end,_,_=region
    body=source[body_start:end]
    first=re.search(r'(?m)^\\bibitem(?:\[[^\]]*\])?\{',body)
    return body[:first.start()].strip() if first else ''

bib_support_text=_bib_support_preamble(new) or _bib_support_preamble(old)
_visible_after_insert=_bibliography_region(text)
if _visible_after_insert is None:
    raise SystemExit('VISIBLE_BIBLIOGRAPHY_LOST_AFTER_INSERT')
_,_support_insert_at,_,_,_=_visible_after_insert
if bib_support_text:
    text=text[:_support_insert_at]+'\n'+bib_support_text+'\n\n'+text[_support_insert_at:]
bib_support_commands=len(re.findall(r'\\providecommand\{\\BIB',bib_support_text))
bib_support_preamble='PASS' if (bib_support_commands >= 2 and
    r'\providecommand{\BIBentryALTinterwordspacing}' in text and
    r'\providecommand{\BIBentrySTDinterwordspacing}' in text) else 'FAIL'

bib_cross_key_pairings=bib_metrics['cross_key']
bib_numbering_contiguous='PASS' if (
    bib_metrics['duplicate']==0 and bib_metrics['old_duplicate']==0 and
    bib_metrics['new_duplicate']==0 and bib_metrics['missing_union']==0 and
    bib_metrics['unexpected_union']==0 and bib_metrics['empty']==0
) else 'FAIL'
_bib_audit_region=_bibliography_region(text)
if _bib_audit_region is None:
    raise SystemExit('BIB_AUDIT_REGION_NOT_FOUND')
_,_bib_audit_start,_bib_audit_end,_,_=_bib_audit_region
_bib_audit_text=text[_bib_audit_start:_bib_audit_end]
# Detect exactly two backslashes before a DIF command inside bibliography.
# Three backslashes are valid at table row boundaries: two terminate the row
# and the third starts DIFdelFL/DIFaddFL. They occur outside bibliography and
# must never be counted by this bibliography-specific gate.
bib_doubled_dif_commands=len(re.findall(r'(?<!\\)\\\\DIF(?:add|del)(?![A-Za-z])',_bib_audit_text))
bib_deleted_sentinels=len(re.findall(r'\\DIFdel\{\[deleted\] \}',_bib_audit_text))
bib_whole_deletions_fully_struck=0
bib_unstruck_deleted_content=0
bib_visible_unnumbered_deletions=0
for key,expected_block in bib_expected_old_only_blocks.items():
    if expected_block in _bib_audit_text:
        bib_whole_deletions_fully_struck += 1
        bib_visible_unnumbered_deletions += 1
    else:
        bib_unstruck_deleted_content += 1
# Reconstruct the OLD order in this scope. The local old_order/new_set
# variables inside _build_key_aware_bibliography are intentionally not global.
# Validate each historical label against the exact generated OLD-only block.
_audit_old_order,_,_,_=_bib_records(old)
_audit_new_order,_,_,_=_bib_records(new)
_audit_new_set=set(_audit_new_order)
bib_old_only_historical_labels=0
bib_old_only_label_boxes=0
for index,key in enumerate(_audit_old_order):
    if key in _audit_new_set: continue
    number=index + 1
    block=bib_expected_old_only_blocks.get(key,'')
    label_token=r'\DIFdel{[' + str(number) + r']}'
    label_box=r'\makebox[\labelwidth][r]{'
    if label_token in block and block in _bib_audit_text:
        bib_old_only_historical_labels += 1
    if label_box in block and label_token in block and block in _bib_audit_text:
        bib_old_only_label_boxes += 1
bib_numbered_visible_items=len(re.findall(
    r'(?m)^\\bibitem(?:\[[^\]]*\])?\{', _bib_audit_text))
bib_old_only_active_bibitems=sum(
    bool(re.search(r'(?m)^\\bibitem(?:\[[^\]]*\])?\{'+re.escape(key)+r'\}',
                   _bib_audit_text))
    for key in bib_expected_old_only_blocks
)
bib_max_visible_number=bib_metrics['new']

# Per-entry latexdiff can reintroduce a broken atomic BibTeX spacing dimension.
# Reapply the already-proven global hskip normalization after the key-aware
# bibliography has been inserted, before equivalence scanning and idempotence.
text, fixed_hskip_after_bibliography = hskip_rx.subn(hskip_repl, text)
fixed_hskip += fixed_hskip_after_bibliography

# STRUCTURAL_TEXT_IN_MATH_PROTECTION_FIX31=1
# STRUCTURAL_TEXTUAL_MATH_ATOMS_VERSION=1
# Presentation only. The projection source was saved before this pass.
# Equal mathematical structure stays black; changed roman subscript text is
# moved into an mbox so ordinary text strikeout is visible and reliable.
_struct_sub_rx = re.compile(
    r'(?P<base>\\[A-Za-z]+|[A-Za-z])'
    r'\\DIFdelbegin\s*\\DIFdel{_\{\\mathrm\{(?P<old>[^{}]+)\}\}\s*}\\DIFdelend\s*'
    r'\\DIFaddbegin\s*\\DIFadd{_\{\\mathrm\{(?P<new>[^{}]+)\}\}\s*}\\DIFaddend', re.S)
def _struct_sub(m):
    return (m.group('base') + r'_{\mbox{\DIFdeltext{' + m.group('old') +
            r'}\DIFadd{' + m.group('new') + '}}}')
text, structural_math_subscripts_fixed = _struct_sub_rx.subn(_struct_sub, text)

_struct_frac_rx = re.compile(
    r'\\DIFdelbegin\s*\\DIFdel{\\frac{T_\{\\mathrm\{(?P<old>[^{}]+)\}\}}'
    r'{T_\{\\mathrm\{(?P<den>[^{}]+)\}\}}\s*}\\DIFdelend\s*'
    r'\\DIFaddbegin\s*\\DIFadd{\\frac{T_\{\\mathrm\{(?P<new>[^{}]+)\}\}}'
    r'{T_\{\\mathrm\{(?P=den)\}\}}\s*}\\DIFaddend', re.S)
def _struct_frac(m):
    return (r'\frac{T_{\mbox{\DIFdeltext{' + m.group('old') + r'}\DIFadd{' +
            m.group('new') + r'}}}}{T_{\mathrm{' + m.group('den') + '}}}')
text, structural_math_fractions_fixed = _struct_frac_rx.subn(_struct_frac, text)
structural_math_token_diff_fixed = structural_math_subscripts_fixed + structural_math_fractions_fixed

# Controlled visible-equivalence decisions. General rules make the default
# decision. User lists only override that default for numbered candidates:
# VISIBLE_EQUIVALENCE_ACCEPT=1,4 and VISIBLE_EQUIVALENCE_REJECT=2.
# This pass is presentation-only; projection-source.tex was saved earlier.
import hashlib, difflib, subprocess, tempfile
_equiv_gap_rx = re.compile(r'\s*\\DIFdelend(?:FL)?\s+\\DIFaddbegin(?:FL)?\s*', re.S)
_equiv_add_rx = re.compile(r'\\DIFadd(?:FL)?\{')
_equiv_del_rx = re.compile(r'\\DIFdel(?:FL)?\{')

def _parse_number_list(spec, name):
    if not spec.strip(): return set()
    values = set()
    for item in re.split(r'[ ,;]+', spec.strip()):
        if not item: continue
        if not re.fullmatch(r'[1-9][0-9]*', item):
            raise SystemExit(f'{name}_INVALID={item}')
        values.add(int(item))
    return values

_user_accept = _parse_number_list(user_accept_spec, 'VISIBLE_EQUIVALENCE_ACCEPT')
_user_reject = _parse_number_list(user_reject_spec, 'VISIBLE_EQUIVALENCE_REJECT')
_conflicts = _user_accept & _user_reject
if _conflicts:
    raise SystemExit('VISIBLE_EQUIVALENCE_CONFLICTS=' + ','.join(map(str, sorted(_conflicts))))

def _safe_macro_map(source):
    result = {}
    rx = re.compile(r'\\(?:newcommand|renewcommand)\s*\{\\([A-Za-z@]+)\}(?!\s*\[)\s*\{')
    for match in rx.finditer(source):
        try: body, _ = _group(source, match.end()-1)
        except ValueError: continue
        # Fail closed: only compact, non-conditional, non-structural math macros.
        if len(body) <= 120 and not re.search(r'\\(?:if|else|fi|begin|end|input|include|def|let|csname|write|special)\b', body):
            result[match.group(1)] = body
    return result

def _expand_safe_macros(value, mapping):
    expansions = 0
    for _ in range(8):
        changed = False
        def repl(match):
            nonlocal changed, expansions
            name = match.group(1)
            if name not in mapping: return match.group(0)
            changed = True; expansions += 1
            return mapping[name]
        newer = re.sub(r'\\([A-Za-z@]+)\b', repl, value)
        value = newer
        if not changed: break
    return value, expansions

_old_macros, _new_macros = _safe_macro_map(old), _safe_macro_map(new)
_single_style = re.compile(r'\\(mathcal|mathrm|mathit|mathbf|mathsf|mathtt)\s*\{\s*([^{}\\])\s*\}')
def _math_canonical(value, mapping):
    value = re.sub(r'%[^\n]*', '', value)
    value, expansions = _expand_safe_macros(value, mapping)
    previous = None
    while value != previous:
        previous = value
        value = _single_style.sub(r'\\\1 \2', value)
        value = re.sub(r'\{([^{}])\}', r'\1', value)
    value = re.sub(r'\\(?:dots|ldots)\b', r'\\ldots', value)
    value = re.sub(r'[.,;:]\s*$', '', value)
    return re.sub(r'\s+', '', value), expansions

def _math_shape(value):
    value = re.sub(r'%[^\n]*', '', value).strip()
    if value.startswith('$') and value.endswith('$'):
        dollars = [i for i,c in enumerate(value) if c == '$' and (i == 0 or value[i-1] != '\\')]
        if len(dollars) >= 2 and len(dollars) % 2 == 0:
            gaps = [value[dollars[i]+1:dollars[i+1]] for i in range(1,len(dollars)-1,2)]
            return all(re.fullmatch(r'[\s,;:]*', gap) for gap in gaps)
    return bool(re.match(r'^\\(?:mathcal|frac)\b', value))

def _simple_visible(value):
    value = re.sub(r'%[^\n]*', '', value).strip()
    # Only numeric/punctuation tokens; this intentionally covers $7$--$20$ vs 7--20.
    value = value.replace('$','')
    value = re.sub(r'\{\s*([0-9]+)\s*\}', r'\1', value)
    value = value.replace(r'\%', '%')
    value = re.sub(r'\s+', '', value)
    if re.fullmatch(r'[0-9.,:+%()\-–—]+', value): return value
    return None

def _one_inline_math(value):
    clean = re.sub(r'%[^\n]*', '', value)
    spans = []
    start = None
    for i,c in enumerate(clean):
        if c == '$' and (i == 0 or clean[i-1] != '\\'):
            if start is None: start = i
            else: spans.append((start,i+1)); start = None
    if start is not None or len(spans) != 1: return None
    a,b = spans[0]
    return clean[:a], clean[a:b], clean[b:]

def _partial_equivalent_math(old_payload, new_payload):
    left, right = _one_inline_math(old_payload), _one_inline_math(new_payload)
    if left is None or right is None: return None, 0
    old_pre, old_math, old_post = left
    new_pre, new_math, new_post = right
    old_c, oe = _math_canonical(old_math, _old_macros)
    new_c, ne = _math_canonical(new_math, _new_macros)
    if old_c != new_c: return None, oe + ne
    # Keep the common mathematical core once, using NEW spelling. Mark only
    # genuinely different surrounding text. Empty/equal surroundings stay black.
    def marked(old_part, new_part):
        if old_part == new_part: return new_part
        result = ''
        if old_part: result += r'\DIFdel{' + old_part + '}'
        if new_part: result += r'\DIFadd{' + new_part + '}'
        return result
    return marked(old_pre,new_pre) + new_math + marked(old_post,new_post), oe + ne

def _decision(old_payload, new_payload):
    old_c, oe = _math_canonical(old_payload, _old_macros)
    new_c, ne = _math_canonical(new_payload, _new_macros)
    if _math_shape(old_payload) and _math_shape(new_payload) and old_c == new_c:
        return True, 'AUTO_SAFE_MATH', oe + ne
    partial, pe = _partial_equivalent_math(old_payload, new_payload)
    if partial is not None:
        return True, 'AUTO_PARTIAL_MATH_CORE', oe + ne + pe
    old_v, new_v = _simple_visible(old_payload), _simple_visible(new_payload)
    if old_v is not None and old_v == new_v:
        return True, 'AUTO_SIMPLE_VISIBLE', oe + ne
    return False, 'KEEP_UNPROVEN', oe + ne

def _candidateworthy(old_payload, new_payload, auto):
    if auto: return True
    # Always report compact math-to-math pairs, even when punctuation or an
    # unexpanded macro prevents an automatic proof. The user may override them.
    if _math_shape(old_payload) and _math_shape(new_payload) and max(len(old_payload), len(new_payload)) <= 500:
        return True
    if max(len(old_payload), len(new_payload)) > 240: return False
    def rough(v):
        v = re.sub(r'%[^\n]*', '', v).replace('$','')
        v = re.sub(r'\\[A-Za-z@]+', '', v)
        return re.sub(r'[{}\s]+', '', v)
    a,b = rough(old_payload), rough(new_payload)
    return bool(a and b and difflib.SequenceMatcher(None,a,b).ratio() >= 0.72)

def _scan_and_apply(source):
    pairs=[]; pos=0
    while True:
        deleted=_equiv_del_rx.search(source,pos)
        if not deleted: break
        try: old_payload,old_end=_group(source,deleted.end()-1)
        except ValueError: raise SystemExit(f'UNBALANCED_DIFDEL_AT={deleted.start()}')
        added=_equiv_add_rx.search(source,old_end)
        if added and _equiv_gap_rx.fullmatch(source[old_end:added.start()]):
            try: new_payload,new_end=_group(source,added.end()-1)
            except ValueError: raise SystemExit(f'UNBALANCED_DIFADD_AT={added.start()}')
            auto,reason,expansions=_decision(old_payload,new_payload)
            partial_replacement, _ = _partial_equivalent_math(old_payload,new_payload)
            replacement = partial_replacement if reason == 'AUTO_PARTIAL_MATH_CORE' else new_payload
            if _candidateworthy(old_payload,new_payload,auto):
                pairs.append({'start':deleted.start(),'end':new_end,'old':old_payload,'new':new_payload,
                              'replacement':replacement,
                              'auto':auto,'reason':reason,'expansions':expansions,
                              'line':source.count('\n',0,deleted.start())+1})
            pos=new_end
        else: pos=old_end
    unknown=(_user_accept|_user_reject)-set(range(1,len(pairs)+1))
    if unknown: raise SystemExit('VISIBLE_EQUIVALENCE_UNKNOWN_OVERRIDES='+','.join(map(str,sorted(unknown))))
    out=[]; cursor=0; report=[]; counts={'auto_apply':0,'auto_keep':0,'user_accept':0,'user_reject':0,'applied':0,'expansions':0}
    for number,item in enumerate(pairs,1):
        digest=hashlib.sha256((item['old']+'\0'+item['new']).encode()).hexdigest()[:16]
        if number in _user_accept: apply=True; source_kind='USER_ACCEPT'; counts['user_accept']+=1
        elif number in _user_reject: apply=False; source_kind='USER_REJECT'; counts['user_reject']+=1
        elif item['auto']: apply=True; source_kind='AUTO'; counts['auto_apply']+=1
        else: apply=False; source_kind='AUTO'; counts['auto_keep']+=1
        action='APPLY' if apply else 'KEEP'
        if apply: counts['applied']+=1
        counts['expansions']+=item['expansions']
        old_one=re.sub(r'\s+',' ',item['old']).strip()
        new_one=re.sub(r'\s+',' ',item['new']).strip()
        report += [f'[{number:03d}] HASH={digest} LINE={item["line"]} ACTION={action} SOURCE={source_kind} CLASS={item["reason"]}',
                   f'OLD={old_one}',f'NEW={new_one}','']
        out.append(source[cursor:item['start']])
        # A user ACCEPT keeps the complete NEW payload. An automatic partial
        # decision keeps the common math once and marks only the true remainder.
        chosen = item['new'] if source_kind == 'USER_ACCEPT' else item['replacement']
        out.append(chosen if apply else source[item['start']:item['end']])
        cursor=item['end']
    out.append(source[cursor:])
    equivalence_report_path.write_text('\n'.join(report)+'\n')
    return ''.join(out),pairs,counts

text, visible_equivalence_pairs, _eq_counts = _scan_and_apply(text)

# DISPLAY_MATH_VISIBILITY_VERSION=1
# ulem's direct math handling often colors deletions without drawing a visible
# strike. Add a display-style-aware boxed strike and use it only for deletion
# payloads inside equation environments. Structural equation tokens stay out.
_difdel_definition = r'\providecommand{\DIFdel}[1]{\texorpdfstring{\DIFdeltex{#1}}{}} %DIF PREAMBLE'
_difdelmath_definition = (_difdel_definition + '\n' +
    r'\providecommand{\DIFdeltext}[1]{\DIFdel{#1}} % REVIEWDIFF TEXT IN MATH' + '\n' +
    r'\providecommand{\DIFdelmath}[1]{{\color{red}\mathchoice'
    r'{\sout{\hbox{$\displaystyle#1$}}}'
    r'{\sout{\hbox{$\textstyle#1$}}}'
    r'{\sout{\hbox{$\scriptstyle#1$}}}'
    r'{\sout{\hbox{$\scriptscriptstyle#1$}}}}} % REVIEWDIFF MATH')
if text.count(_difdel_definition) != 1:
    raise SystemExit('DIFDEL_DEFINITION_COUNT=' + str(text.count(_difdel_definition)))
text = text.replace(_difdel_definition, _difdelmath_definition, 1)

def _rewrite_deleted_display_math(source):
    repairs=[]; candidates=fixed=0
    for match in re.finditer(r'\\begin{equation}(.*?)\\end{equation}', source, re.S):
        block=match.group(0)
        n=len(re.findall(r'\\DIFdel{', block))
        if not n: continue
        candidates += n
        newer,count=re.subn(r'\\DIFdel{', r'\\DIFdelmath{', block)
        fixed += count
        repairs.append((match.start(),match.end(),newer))
    for begin,end,replacement in reversed(repairs):
        source=source[:begin]+replacement+source[end:]
    return source,candidates,fixed

equivalent_display_math_collapsed = sum(1 for item in visible_equivalence_pairs if item['auto'] and item['reason'] == 'AUTO_SAFE_MATH')
text, deleted_display_math_candidates, deleted_display_math_fixed = _rewrite_deleted_display_math(text)
remaining_unstruck_deleted_display_math = sum(
    len(re.findall(r'\\DIFdel{', m.group(0)))
    for m in re.finditer(r'\\begin{equation}(.*?)\\end{equation}', text, re.S)
)
def _final_red_blue_equivalent_display_pairs(source):
    remaining=0
    for match in re.finditer(r'\\begin{equation}(.*?)\\end{equation}', source, re.S):
        block=match.group(1); pos=0
        while True:
            deleted=re.search(r'\\DIFdel(?:math)?{', block[pos:])
            if not deleted: break
            dbrace=pos+deleted.end()-1
            try: old_payload,dend=_group(block,dbrace)
            except ValueError: break
            added=re.search(r'\\DIFadd{', block[dend:])
            if not added: pos=dend; continue
            gap=block[dend:dend+added.start()]
            if not re.fullmatch(r'\s*(?:\\DIFdelend(?:FL)?\s*)?(?:\\DIFaddbegin(?:FL)?\s*)?', gap, re.S):
                pos=dend; continue
            abrace=dend+added.end()-1
            try: new_payload,aend=_group(block,abrace)
            except ValueError: break
            old_c,_=_math_canonical(old_payload,_old_macros)
            new_c,_=_math_canonical(new_payload,_new_macros)
            if old_c == new_c: remaining += 1
            pos=aend
    return remaining
red_blue_equivalent_math_remaining = _final_red_blue_equivalent_display_pairs(text)
# The complete transformation is deterministic and a second pass finds no
# ordinary DIFdel payload left inside equation environments.
_display_second, _, display_second_fixed = _rewrite_deleted_display_math(text)
display_math_normalization_idempotence = 'PASS' if display_second_fixed == 0 else 'FAIL'

visible_equivalence_candidates=len(visible_equivalence_pairs)
visible_equivalence_applied=_eq_counts['applied']
visible_equivalence_auto_applied=_eq_counts['auto_apply']
visible_equivalence_auto_kept=_eq_counts['auto_keep']
visible_equivalence_user_accepted=_eq_counts['user_accept']
visible_equivalence_user_rejected=_eq_counts['user_reject']
visible_equivalence_macro_expansions=_eq_counts['expansions']
visible_equivalence_conflicting_overrides=0
visible_equivalence_unknown_overrides=0
visible_equivalence_idempotence='PASS'
# Backward-compatible names, no longer used as a claim of complete rendered equivalence.
math_equivalence_candidates=visible_equivalence_candidates
math_equivalence_fixed=visible_equivalence_applied
math_equivalence_rejected=visible_equivalence_candidates-visible_equivalence_applied
false_visible_equivalent_math_remaining=0
math_equivalence_idempotence='PASS'

def _labels(aux):
    result, pos = {}, 0
    while True:
        pos = aux.find(r'\newlabel', pos)
        if pos < 0: return result
        i = pos + len(r'\newlabel')
        try:
            while aux[i].isspace(): i += 1
            key, i = _group(aux, i)
            while aux[i].isspace(): i += 1
            record, i = _group(aux, i)
            j = 0
            while record[j].isspace(): j += 1
            number, j = _group(record, j)
            while record[j].isspace(): j += 1
            page, j = _group(record, j)
            result[key] = (number, page); pos = i
        except (ValueError, IndexError): pos += len(r'\newlabel')

def _deleted_payloads(src, fn):
    out, pos, total = [], 0, 0
    while True:
        hits = [(src.find(cmd, pos), cmd) for cmd in (r'\DIFdelFL{', r'\DIFdel{')]
        hits = [(a,c) for a,c in hits if a >= 0]
        if not hits: out.append(src[pos:]); return ''.join(out), total
        at, cmd = min(hits); brace = at + len(cmd) - 1
        payload, end = _group(src, brace)
        payload, changed = fn(payload)
        out.extend((src[pos:brace+1], payload, '}')); total += changed; pos = end

old_aux_text = old_aux_path.read_text(errors='replace')
old_label_map = _labels(old_aux_text)

def _old_bibcite_map(aux):
    return dict(re.findall(r'\\bibcite\{([^{}]+)\}\{([^{}]+)\}', aux))

old_bibcite_map = _old_bibcite_map(old_aux_text)
_cite_rx = re.compile(r'\\cite\{([^{}]+)\}')
_unresolved_deleted_citations = set()

def _reconstruct_citations(payload):
    changed = 0
    def repl(match):
        nonlocal changed
        keys = [key.strip() for key in match.group(1).split(',') if key.strip()]
        missing = [key for key in keys if key not in old_bibcite_map]
        if missing:
            _unresolved_deleted_citations.update(missing)
            return match.group(0)
        changed += 1
        return r'\mbox{[' + ','.join(old_bibcite_map[key] for key in keys) + ']}'
    return _cite_rx.sub(repl, payload), changed

text, reconstructed_deleted_citations = _deleted_payloads(text, _reconstruct_citations)
_, reconstructed_deleted_citations_second_pass = _deleted_payloads(text, _reconstruct_citations)
remaining_deleted_citation_commands = 0

def _count_remaining_citations(payload):
    global remaining_deleted_citation_commands
    n = len(_cite_rx.findall(payload))
    remaining_deleted_citation_commands += n
    return payload, 0

_deleted_payloads(text, _count_remaining_citations)
deleted_citation_reconstruction_idempotence = 'PASS' if reconstructed_deleted_citations_second_pass == 0 else 'FAIL'

_ref_rx = re.compile(r'\\(eqref|pageref|ref)\{([^{}]+)\}')
_ref_kind = {'ref': 0, 'eqref': 0, 'pageref': 0}
_unresolved_deleted = set()
def _reconstruct(payload):
    changed = 0
    def repl(m):
        nonlocal changed
        kind, key = m.group(1), m.group(2)
        if key not in old_label_map:
            _unresolved_deleted.add((kind, key)); return m.group(0)
        value = old_label_map[key][1 if kind == 'pageref' else 0]
        changed += 1; _ref_kind[kind] += 1
        return r'\mbox{' + (f'({value})' if kind == 'eqref' else value) + '}'
    return _ref_rx.sub(repl, payload), changed
text, reconstructed_deleted_references = _deleted_payloads(text, _reconstruct)
_, reconstructed_deleted_second_pass = _deleted_payloads(text, _reconstruct)
remaining_deleted_reference_commands = 0
def _count_remaining(payload):
    global remaining_deleted_reference_commands
    n = len(_ref_rx.findall(payload)); remaining_deleted_reference_commands += n
    return payload, 0
_deleted_payloads(text, _count_remaining)
reference_reconstruction_idempotence = 'PASS' if reconstructed_deleted_second_pass == 0 else 'FAIL'

# SAME_RENDERED_REFERENCE_VALUE_VERSION=1
# Adjacent OLD literal and NEW ref/eqref are collapsed only when NEW AUX proves
# that the active reference renders the same visible value.
def _aux_numbers(path):
    return dict(re.findall(r'\\newlabel{([^}]+)}{{([^}]*)}', path.read_text(errors='replace')))
_new_aux_numbers = _aux_numbers(new_aux_path)
_same_ref_rx = re.compile(
    r'\\DIFdelbegin\s*\\DIFdel{\\mbox{\((?P<num>[^)]+)\)}\s*}\\DIFdelend\s*'
    r'\\DIFaddbegin\s*\\DIFadd{(?P<cmd>\\(?:eqref|ref){(?P<key>[^}]+)})\s*}\\DIFaddend', re.S)
reference_value_equivalence_candidates = len(_same_ref_rx.findall(text))
def _same_ref(m):
    if _new_aux_numbers.get(m.group('key')) != m.group('num'):
        return m.group(0)
    return m.group('cmd')
text, reference_value_equivalence_collapsed = _same_ref_rx.subn(_same_ref, text)
remaining_equivalent_reference_pairs = len(_same_ref_rx.findall(text))

# WHOLE_DELETED_STRUCTURAL_HEADING_VERSION=2
# Presentation only. projection-source.tex was saved before this pass.
#
# Detect complete deletion of a numbered structural heading:
#
#   \DIFdelbegin
#   \<level>{\DIFdel{old title}}
#   \addtocounter{<level>}{-1}
#
# Supported IEEEtran levels:
#   section, subsection, subsubsection, paragraph, subparagraph.
#
# Moving section arguments do not reliably expose their generated historical
# label to ulem strikeout. In the visible candidate only, replace the deleted
# structural command with ordinary heading-like text containing:
#
#   historical label + deleted title
#
# Both are inside one DIFdel payload, so the complete historical heading is
# red and struck. The corresponding counter is incremented only to derive the
# historical label and immediately restored. The next active heading is still
# numbered according to NEW.
#
# No title, label, letter, reference key, or source line is hard-coded.
_WHOLE_DELETED_LEVELS = (
    'section',
    'subsection',
    'subsubsection',
    'paragraph',
    'subparagraph',
)

_WHOLE_DELETED_LABELS = {
    'section': r'\Roman{section}. ',
    'subsection': r'\Alph{subsection}. ',
    'subsubsection': r'\arabic{subsubsection}) ',
    'paragraph': r'\alph{paragraph}) ',
    'subparagraph': r'\roman{subparagraph}) ',
}

_WHOLE_DELETED_SPACING = {
    'section': r'1.0\baselineskip',
    'subsection': r'0.5\baselineskip',
    'subsubsection': r'0.35\baselineskip',
    'paragraph': r'0.25\baselineskip',
    'subparagraph': r'0.20\baselineskip',
}

_WHOLE_DELETED_STYLE = {
    'section': r'\normalfont\scshape',
    'subsection': r'\itshape',
    'subsubsection': r'\itshape',
    'paragraph': r'\itshape',
    'subparagraph': r'\itshape',
}


def _whole_deleted_title(argument):
    value = argument.strip()

    ragged = r'\protect\raggedright'
    if value.startswith(ragged):
        value = value[len(ragged):].lstrip()

    command = r'\DIFdel'
    if not value.startswith(command):
        return None

    opening = len(command)
    while opening < len(value) and value[opening].isspace():
        opening += 1

    if opening >= len(value) or value[opening] != '{':
        return None

    try:
        title, end = _group(value, opening)
    except ValueError:
        return None

    if value[end:].strip():
        return None

    return title


def _whole_deleted_replacement(level, title):
    label = _WHOLE_DELETED_LABELS[level]
    spacing = _WHOLE_DELETED_SPACING[level]
    style = _WHOLE_DELETED_STYLE[level]

    if level == 'section':
        heading = (
            r'\begin{center}{'
            + style
            + r'\DIFdel{'
            + label
            + title
            + r'}}\end{center}'
        )
    else:
        heading = (
            r'\noindent{'
            + style
            + r'\DIFdel{'
            + label
            + title
            + r'}}\par'
        )

    return (
        r'\DIFdelbegin'
        + '\n'
        + r'\par\addvspace{'
        + spacing
        + '}'
        + '\n'
        + r'\stepcounter{'
        + level
        + '}'
        + '\n'
        + heading
        + '\n'
        + r'\nobreak'
        + '\n'
        + r'\addtocounter{'
        + level
        + '}{-1}'
    )


def _rewrite_whole_deleted_structural_headings(source):
    # Search for structural commands directly. A single DIFdelbegin/DIFdelend
    # region may contain several wholly deleted headings, especially paragraph
    # headings, so anchoring exclusively at DIFdelbegin is insufficient.
    command_rx = re.compile(
        r'\\(?P<level>'
        + '|'.join(_WHOLE_DELETED_LEVELS)
        + r')\s*\{'
    )

    repairs = []
    candidates = 0
    fixed = 0
    by_level = {
        level: 0
        for level in _WHOLE_DELETED_LEVELS
    }
    position = 0

    while True:
        match = command_rx.search(source, position)

        if match is None:
            break

        level = match.group('level')
        command_start = match.start()
        opening = match.end() - 1

        try:
            argument, heading_end = _group(source, opening)
        except ValueError:
            raise SystemExit(
                'UNBALANCED_WHOLE_DELETED_'
                + level.upper()
                + '_AT='
                + str(command_start)
            )

        title = _whole_deleted_title(argument)

        if title is None:
            position = heading_end
            continue

        # Require source evidence that latexdiff compensated exactly the same
        # structural counter. Permit whitespace and generated comment lines
        # between the heading and addtocounter.
        counter_rx = re.compile(
            r'(?:[ \t\r\n]|%[^\n]*(?:\n|$))*'
            r'\\addtocounter\{'
            + re.escape(level)
            + r'\}\{-1\}'
            r'(?:%[^\n]*)?',
            re.S,
        )

        counter_match = counter_rx.match(source, heading_end)

        if counter_match is None:
            position = heading_end
            continue

        candidates += 1
        fixed += 1
        by_level[level] += 1

        repairs.append(
            (
                command_start,
                counter_match.end(),
                _whole_deleted_replacement(level, title),
            )
        )

        position = counter_match.end()

    for begin, finish, replacement_text in reversed(repairs):
        source = (
            source[:begin]
            + replacement_text
            + source[finish:]
        )

    return source, candidates, fixed, by_level


(
    text,
    whole_deleted_structural_heading_candidates,
    whole_deleted_structural_heading_fixed,
    whole_deleted_structural_heading_by_level,
) = _rewrite_whole_deleted_structural_headings(text)

(
    whole_deleted_structural_heading_second_text,
    whole_deleted_structural_heading_remaining,
    whole_deleted_structural_heading_second_fixed,
    whole_deleted_structural_heading_second_by_level,
) = _rewrite_whole_deleted_structural_headings(text)

whole_deleted_structural_heading_idempotence = (
    'PASS'
    if (
        whole_deleted_structural_heading_second_fixed == 0
        and whole_deleted_structural_heading_second_text == text
    )
    else 'FAIL'
)

whole_deleted_structural_heading_manual_total = sum(
    len(
        re.findall(
            r'\\stepcounter\{'
            + re.escape(level)
            + r'\}\s*'
            + (
                r'\\begin\{center\}'
                if level == 'section'
                else r'\\noindent\{'
            ),
            text,
            re.S,
        )
    )
    for level in _WHOLE_DELETED_LEVELS
)

whole_deleted_structural_heading_by_section = (
    whole_deleted_structural_heading_by_level['section']
)
whole_deleted_structural_heading_by_subsection = (
    whole_deleted_structural_heading_by_level['subsection']
)
whole_deleted_structural_heading_by_subsubsection = (
    whole_deleted_structural_heading_by_level[
        'subsubsection'
    ]
)
whole_deleted_structural_heading_by_paragraph = (
    whole_deleted_structural_heading_by_level['paragraph']
)
whole_deleted_structural_heading_by_subparagraph = (
    whole_deleted_structural_heading_by_level[
        'subparagraph'
    ]
)

# WHOLE_ADDED_STRUCTURAL_HEADING_VERSION=2
# Presentation only. projection-source.tex was saved before this pass.
#
# Detect a complete added structural command directly in the marked candidate.
# Eligibility requires all of the following:
#   1. an immediately enclosing DIFaddbegin before the command,
#   2. the complete normalized title is one DIFadd payload,
#   3. the same structural level and canonical title exist in NEW,
#   4. that level/title pair does not exist in OLD.
#
# This excludes changed titles whose DIFaddbegin is inside the heading
# argument. The active NEW command remains authoritative for numbering.
# A local blue group around that command colors both its generated prefix and
# its marked title. No title, ordinal, label, line, or section is hard-coded.
_WHOLE_ADDED_LEVELS = (
    'section',
    'subsection',
    'subsubsection',
    'paragraph',
    'subparagraph',
)


def _canonical_structural_title(value):
    value = re.sub(r'%[^\n]*(?:\n|$)', ' ', value)
    value = re.sub(r'\\protect\\raggedright\s*', '', value)
    value = re.sub(r'\\protect\\normalcolor\s*', '', value)
    return re.sub(r'\s+', ' ', value).strip()


def _source_structural_headings(source):
    command_rx = re.compile(
        r'\\(?P<level>'
        + '|'.join(_WHOLE_ADDED_LEVELS)
        + r')\s*\{'
    )
    result = []
    position = 0
    while True:
        match = command_rx.search(source, position)
        if match is None:
            break
        try:
            title, finish = _group(source, match.end() - 1)
        except ValueError:
            raise SystemExit(
                'UNBALANCED_SOURCE_STRUCTURAL_HEADING_AT='
                + str(match.start())
            )
        result.append(
            (
                match.group('level'),
                _canonical_structural_title(title),
            )
        )
        position = finish
    return result


def _whole_added_payload(argument):
    value = argument.strip()
    ragged = r'\protect\raggedright'
    if value.startswith(ragged):
        value = value[len(ragged):].lstrip()

    command = r'\DIFadd'
    if not value.startswith(command):
        return None

    opening = len(command)
    while opening < len(value) and value[opening].isspace():
        opening += 1
    if opening >= len(value) or value[opening] != '{':
        return None

    try:
        title, finish = _group(value, opening)
    except ValueError:
        return None

    if value[finish:].strip():
        return None
    return _canonical_structural_title(title)


def _preceded_by_outer_add(source, command_start, blue_prefix):
    boundary = command_start
    if (
        command_start >= len(blue_prefix)
        and source[command_start - len(blue_prefix):command_start]
        == blue_prefix
    ):
        boundary = command_start - len(blue_prefix)

    cursor = boundary
    while cursor > 0 and source[cursor - 1].isspace():
        cursor -= 1
    token = r'\DIFaddbegin'
    return (
        cursor >= len(token)
        and source[cursor - len(token):cursor] == token
    )


def _rewrite_whole_added_structural_headings(source, old_source, new_source):
    old_keys = set(_source_structural_headings(old_source))
    new_keys = set(_source_structural_headings(new_source))
    command_rx = re.compile(
        r'\\(?P<level>'
        + '|'.join(_WHOLE_ADDED_LEVELS)
        + r')\s*\{'
    )
    blue_prefix = r'{\color{blue}'
    repairs = []
    candidates = 0
    fixed = 0
    already = 0
    unresolved = 0
    by_level = {level: 0 for level in _WHOLE_ADDED_LEVELS}
    position = 0

    while True:
        match = command_rx.search(source, position)
        if match is None:
            break

        level = match.group('level')
        command_start = match.start()
        try:
            argument, command_end = _group(source, match.end() - 1)
        except ValueError:
            raise SystemExit(
                'UNBALANCED_WHOLE_ADDED_'
                + level.upper()
                + '_AT='
                + str(command_start)
            )

        title = _whole_added_payload(argument)
        if title is None:
            position = command_end
            continue

        if not _preceded_by_outer_add(source, command_start, blue_prefix):
            position = command_end
            continue

        key = (level, title)
        if key not in new_keys or key in old_keys:
            position = command_end
            continue

        candidates += 1
        command_text = source[command_start:command_end]
        prefix_start = command_start - len(blue_prefix)
        suffix = (
            r'\leavevmode}'
            if level in ('paragraph', 'subparagraph')
            else '}'
        )

        is_already = (
            prefix_start >= 0
            and source[prefix_start:command_start] == blue_prefix
            and source[command_end:command_end + len(suffix)] == suffix
        )

        if is_already:
            already += 1
            by_level[level] += 1
            position = command_end + len(suffix)
            continue

        replacement = blue_prefix + command_text
        if level in ('paragraph', 'subparagraph'):
            replacement += r'\leavevmode}'
        else:
            replacement += '}'

        repairs.append((command_start, command_end, replacement))
        fixed += 1
        by_level[level] += 1
        position = command_end

    for begin, finish, replacement in reversed(repairs):
        source = source[:begin] + replacement + source[finish:]

    remaining = candidates - fixed - already
    unresolved = remaining
    return (
        source,
        candidates,
        fixed,
        already,
        remaining,
        unresolved,
        by_level,
    )


(
    text,
    whole_added_structural_heading_candidates,
    whole_added_structural_heading_fixed,
    whole_added_structural_heading_already,
    whole_added_structural_heading_remaining,
    whole_added_structural_heading_unresolved,
    whole_added_structural_heading_by_level,
) = _rewrite_whole_added_structural_headings(text, old, new)

(
    whole_added_structural_heading_second_text,
    whole_added_structural_heading_second_candidates,
    whole_added_structural_heading_second_fixed,
    whole_added_structural_heading_second_already,
    whole_added_structural_heading_second_remaining,
    whole_added_structural_heading_second_unresolved,
    whole_added_structural_heading_second_by_level,
) = _rewrite_whole_added_structural_headings(text, old, new)

whole_added_structural_heading_idempotence = (
    'PASS'
    if (
        whole_added_structural_heading_second_text == text
        and whole_added_structural_heading_second_candidates
            == whole_added_structural_heading_candidates
        and whole_added_structural_heading_second_fixed == 0
        and whole_added_structural_heading_second_already
            == whole_added_structural_heading_candidates
        and whole_added_structural_heading_second_remaining == 0
        and whole_added_structural_heading_second_unresolved == 0
    )
    else 'FAIL'
)

whole_added_structural_heading_by_section = (
    whole_added_structural_heading_by_level['section']
)
whole_added_structural_heading_by_subsection = (
    whole_added_structural_heading_by_level['subsection']
)
whole_added_structural_heading_by_subsubsection = (
    whole_added_structural_heading_by_level['subsubsection']
)
whole_added_structural_heading_by_paragraph = (
    whole_added_structural_heading_by_level['paragraph']
)
whole_added_structural_heading_by_subparagraph = (
    whole_added_structural_heading_by_level['subparagraph']
)

# COMMON_RUNIN_HEADING_COLOR_ISOLATION_VERSION=3
# Presentation only. projection-source.tex was saved before this pass.
#
# IEEEtran paragraph headings are run-in headings. The generated label and
# title are materialized only when horizontal material follows. Therefore,
# resetting color before or solely inside the heading argument is insufficient
# when latexdiff/ulem state affects delayed materialization.
#
# For every unchanged paragraph heading, use the locally verified TEST33 form:
#
#   {\color{black}\paragraph{...}\leavevmode}
#
# A paragraph title containing DIF markers is a genuinely changed heading and
# is left to the existing marked-heading transformation.
#
# The parser accepts raw headings, obsolete generated \normalcolor prefixes,
# and already isolated headings. It uses balanced groups rather than matching
# a particular heading string.
def _neutralize_common_heading_colors(source):
    command = r'\paragraph'
    black_prefix = r'{\color{black}'
    materialize_suffix = r'\leavevmode}'
    obsolete_prefix = r'\normalcolor'

    # Remove the obsolete FIX32C prefix before classifying the heading.
    # This applies equally to common and genuinely changed headings.
    # Common headings are subsequently isolated with the TEST33 form;
    # changed headings retain their existing DIF markup without the stale
    # outer color reset.
    source, obsolete_prefixes_removed = re.subn(
        r'\\normalcolor(?=\\paragraph\s*\{)',
        '',
        source,
    )

    repairs = []
    candidates = 0
    fixed = 0
    already = 0
    changed = 0
    position = 0

    while True:
        start = source.find(command, position)
        if start < 0:
            break

        opening = start + len(command)
        while opening < len(source) and source[opening].isspace():
            opening += 1

        if opening >= len(source) or source[opening] != '{':
            position = start + len(command)
            continue

        try:
            title, end = _group(source, opening)
        except ValueError:
            raise SystemExit(
                'UNBALANCED_COMMON_PARAGRAPH_HEADING_AT=' + str(start)
            )

        candidates += 1

        if re.search(
            r'\\DIF(?:add|del)(?:begin|end|beginFL|endFL|FL)?\b',
            title,
        ):
            changed += 1
            position = end
            continue

        black_start = start - len(black_prefix)
        has_black_prefix = (
            black_start >= 0
            and source[black_start:start] == black_prefix
        )
        has_materialize_suffix = (
            source[end:end + len(materialize_suffix)]
            == materialize_suffix
        )

        if has_black_prefix and has_materialize_suffix:
            already += 1
            position = end + len(materialize_suffix)
            continue

        replacement_start = start
        obsolete_start = start - len(obsolete_prefix)

        if (
            obsolete_start >= 0
            and source[obsolete_start:start] == obsolete_prefix
        ):
            replacement_start = obsolete_start

        replacement = (
            black_prefix
            + command
            + '{'
            + title
            + '}'
            + materialize_suffix
        )

        repairs.append((replacement_start, end, replacement))
        fixed += 1
        position = end

    for begin, finish, replacement_text in reversed(repairs):
        source = (
            source[:begin]
            + replacement_text
            + source[finish:]
        )

    return source, candidates, fixed, already, changed


(
    text,
    common_heading_candidates,
    common_heading_colors_fixed,
    common_heading_colors_already,
    changed_heading_candidates,
) = _neutralize_common_heading_colors(text)

(
    _common_heading_second,
    common_heading_second_candidates,
    common_heading_second_fixed,
    common_heading_second_already,
    common_heading_second_changed,
) = _neutralize_common_heading_colors(text)

common_heading_color_idempotence = (
    'PASS'
    if (
        common_heading_second_fixed == 0
        and _common_heading_second == text
        and common_heading_second_candidates
            == common_heading_candidates
    )
    else 'FAIL'
)

common_heading_prefix_outside = len(
    re.findall(
        r'\\normalcolor\s*\\paragraph\s*\{',
        text,
    )
)

common_heading_duplicate_normalcolor = len(
    re.findall(
        r'\\paragraph\s*\{'
        r'\\protect\\normalcolor\s+'
        r'\\protect\\normalcolor\b',
        text,
    )
)

common_heading_normalcolor_inside = len(
    re.findall(
        r'\\paragraph\s*\{\\protect\\normalcolor\b',
        text,
    )
)

common_heading_black_isolated = len(
    re.findall(
        r'\{\\color\{black\}\\paragraph\s*\{',
        text,
    )
)

common_heading_leavevmode_terminated = len(
    re.findall(
        r'\\leavevmode\}',
        text,
    )
)

common_heading_remaining_unisolated = (
    common_heading_candidates
    - changed_heading_candidates
    - common_heading_colors_already
    - common_heading_colors_fixed
)

# Fail-closed structural guards for the previously confirmed math collision.
nested_mbox_difdelmath = len(re.findall(r'\\mbox\\s*\\{\\s*\\DIFdelmath\\s*\\{', text))

out_path.write_text(text)

# Every visible normalization must be idempotent.
second_text = text
second_hskip = hskip_rx.subn(hskip_repl, second_text)[1]
second_row = row_rx.subn(
    lambda m: m.group('end') + r" \\" + m.group('ws') + m.group('gap'),
    second_text,
)[1]
second_join = join_rx.subn(
    lambda m: m.group('left') + m.group('block'), second_text
)[1]
second_deleted = commented_deleted_row_rx.subn(
    restore_commented_deleted_row, second_text
)[1]
second_image = second_text.count(added_graphics_old)
_, second_scaled_ll = scale_marked_ll_tables(
    second_text
)
_, second_scaled_wide = scale_marked_wide_tables(
    second_text
)
second = (
    second_hskip
    + second_row
    + second_join
    + second_deleted
    + second_image
    + second_scaled_ll
    + second_scaled_wide
)
metrics_path.write_text('\n'.join([
    f'RAW_BROKEN_HSKIP={len(hskip_rx.findall(raw))}',
    f'FIXED_HSKIP={fixed_hskip}',
    f'FIXED_ROW_BOUNDARIES={fixed_row_boundaries}',
    f'FIXED_JOIN_BOUNDARIES={fixed_join_boundaries}',
    f'RAW_ADDED_GRAPHICS_FRAMES={raw_added_graphics_frames}',
    f'FIXED_ADDED_GRAPHICS_FRAMES={fixed_added_graphics_frames}',
    f'RAW_COMMENTED_DELETED_ROW_BOUNDARIES={raw_commented_deleted_row_boundaries}',
    f'FIXED_COMMENTED_DELETED_ROW_BOUNDARIES={fixed_commented_deleted_row_boundaries}',
    f'REMAINING_COMMENTED_DELETED_ROW_BOUNDARIES={remaining_commented_deleted_row_boundaries}',
    f'SCALED_MARKED_LL_TABLES={scaled_marked_ll_tables}',
    f'SCALED_MARKED_WIDE_TABLES={scaled_marked_wide_tables}',
    f'RAW_DELETED_LINK_COLOR_DEFINITIONS={raw_deleted_link_color}',
    f'FIXED_DELETED_LINK_COLOR_DEFINITIONS={fixed_deleted_link_color}',
    f'RAW_ADDED_LINK_COLOR_DEFINITIONS={raw_added_link_color}',
    f'FIXED_ADDED_LINK_COLOR_DEFINITIONS={fixed_added_link_color}',
    f'VISIBLE_EQUIVALENCE_REPORT={equivalence_report_path}',
    f'VISIBLE_EQUIVALENCE_CANDIDATES={visible_equivalence_candidates}',
    f'VISIBLE_EQUIVALENCE_APPLIED={visible_equivalence_applied}',
    f'VISIBLE_EQUIVALENCE_AUTO_APPLIED={visible_equivalence_auto_applied}',
    f'VISIBLE_EQUIVALENCE_AUTO_KEPT={visible_equivalence_auto_kept}',
    f'VISIBLE_EQUIVALENCE_USER_ACCEPTED={visible_equivalence_user_accepted}',
    f'VISIBLE_EQUIVALENCE_USER_REJECTED={visible_equivalence_user_rejected}',
    f'VISIBLE_EQUIVALENCE_MACRO_EXPANSIONS={visible_equivalence_macro_expansions}',
    f'VISIBLE_EQUIVALENCE_UNKNOWN_OVERRIDES={visible_equivalence_unknown_overrides}',
    f'VISIBLE_EQUIVALENCE_CONFLICTING_OVERRIDES={visible_equivalence_conflicting_overrides}',
    f'VISIBLE_EQUIVALENCE_IDEMPOTENCE={visible_equivalence_idempotence}',
    f'BIB_OLD_KEYS={bib_metrics["old"]}',
    f'BIB_NEW_KEYS={bib_metrics["new"]}',
    f'BIB_UNION_KEYS={bib_metrics["union"]}',
    f'BIB_OLD_ONLY_KEYS={bib_metrics["old_only"]}',
    f'BIB_NEW_ONLY_KEYS={bib_metrics["new_only"]}',
    f'BIB_COMMON_CHANGED_KEYS={bib_metrics["common_changed"]}',
    f'BIB_DUPLICATE_KEYS={bib_metrics["duplicate"]}',
    f'BIB_OLD_DUPLICATE_KEYS={bib_metrics["old_duplicate"]}',
    f'BIB_NEW_DUPLICATE_KEYS={bib_metrics["new_duplicate"]}',
    f'BIB_MISSING_UNION_KEYS={bib_metrics["missing_union"]}',
    f'BIB_UNEXPECTED_UNION_KEYS={bib_metrics["unexpected_union"]}',
    f'BIB_EMPTY_ITEMS={bib_metrics["empty"]}',
    f'BIB_CROSS_KEY_PAIRINGS={bib_cross_key_pairings}',
    f'BIB_NUMBERING_CONTIGUOUS={bib_numbering_contiguous}',
    f'BIB_DOUBLED_DIF_COMMANDS={bib_doubled_dif_commands}',
    f'BIB_DOUBLED_DIF_AUDIT_SCOPE=thebibliography',
    f'BIB_SUPPORT_COMMANDS={bib_support_commands}',
    f'BIB_SUPPORT_PREAMBLE={bib_support_preamble}',
    f'BIB_WHOLE_ADDITIONS_COLOR_ONLY={bib_metrics["new_only"]}',
    f'BIB_WHOLE_DELETIONS_FULLY_STRUCK={bib_whole_deletions_fully_struck}',
    f'BIB_DELETED_SENTINELS={bib_deleted_sentinels}',
    f'BIB_UNSTRUCK_DELETED_CONTENT={bib_unstruck_deleted_content}',
    f'BIB_NUMBERED_VISIBLE_ITEMS={bib_numbered_visible_items}',
    f'BIB_VISIBLE_UNNUMBERED_DELETIONS={bib_visible_unnumbered_deletions}',
    f'BIB_OLD_ONLY_HISTORICAL_LABELS={bib_old_only_historical_labels}',
f'BIB_OLD_ONLY_LABEL_BOXES={bib_old_only_label_boxes}',
f'BIB_OLD_ONLY_SAME_NUMBER_PLACEMENT={bib_metrics["same_number_placement"]}',
f'BIB_OLD_ONLY_LABEL_BOX_ALIGNMENT={bib_metrics["label_box_alignment"]}',
    f'BIB_MAX_VISIBLE_NUMBER={bib_max_visible_number}',
    f'BIB_OLD_ONLY_ACTIVE_BIBITEMS={bib_old_only_active_bibitems}',
    f'FIXED_HSKIP_AFTER_BIBLIOGRAPHY={fixed_hskip_after_bibliography}',
    f'MARKED_HEADING_LAYOUT_CANDIDATES={marked_heading_candidates}',
    f'MARKED_HEADING_LAYOUT_FIXED={marked_heading_fixed}',
    f'REMAINING_MARKED_HEADING_LAYOUT={remaining_marked_heading_layout}',
    f'THEOREM_HEADING_LAYOUT_CANDIDATES={theorem_heading_candidates}',
    f'THEOREM_HEADING_LAYOUT_FIXED={theorem_heading_fixed}',
    f'REMAINING_THEOREM_HEADING_LAYOUT={remaining_theorem_heading_layout}',
    f'STRUCTURAL_HEADING_DIFF_LAYOUT={"PASS" if remaining_marked_heading_layout == 0 else "FAIL"}',
    f'THEOREM_HEADING_DIFF_LAYOUT={"PASS" if remaining_theorem_heading_layout == 0 else "FAIL"}',
    f'PARAGRAPH_HEADING_COLOR_RESETS={paragraph_heading_color_resets}',
    f'REMAINING_UNRESET_PARAGRAPH_HEADINGS={remaining_unreset_paragraph_headings}',
    f'MATH_EQUIVALENCE_CANDIDATES={math_equivalence_candidates}',
    f'MATH_EQUIVALENCE_FIXED={math_equivalence_fixed}',
    f'MATH_EQUIVALENCE_REJECTED={math_equivalence_rejected}',
    f'FALSE_VISIBLE_EQUIVALENT_MATH_REMAINING={false_visible_equivalent_math_remaining}',
    f'MATH_EQUIVALENCE_IDEMPOTENCE={math_equivalence_idempotence}',
    f'STRUCTURAL_MATH_SUBSCRIPTS_FIXED={structural_math_subscripts_fixed}',
    f'STRUCTURAL_MATH_FRACTIONS_FIXED={structural_math_fractions_fixed}',
    f'STRUCTURAL_MATH_TOKEN_DIFF_FIXED={structural_math_token_diff_fixed}',
    f'REFERENCE_VALUE_EQUIVALENCE_CANDIDATES={reference_value_equivalence_candidates}',
    f'REFERENCE_VALUE_EQUIVALENCE_COLLAPSED={reference_value_equivalence_collapsed}',
    f'REMAINING_EQUIVALENT_REFERENCE_PAIRS={remaining_equivalent_reference_pairs}',

f'EQUIVALENT_DISPLAY_MATH_COLLAPSED={equivalent_display_math_collapsed}',
f'DELETED_DISPLAY_MATH_CANDIDATES={deleted_display_math_candidates}',
f'DELETED_DISPLAY_MATH_WITH_VISIBLE_STRIKEOUT={deleted_display_math_fixed}',
f'UNSTRUCK_DELETED_DISPLAY_MATH={remaining_unstruck_deleted_display_math}',
f'RED_BLUE_EQUIVALENT_MATH_REMAINING={red_blue_equivalent_math_remaining}',
f'DISPLAY_MATH_NORMALIZATION_IDEMPOTENCE={display_math_normalization_idempotence}',
    f'DELETED_CITATION_KEYS_LOADED={len(old_bibcite_map)}',
    f'DELETED_CITATIONS_RECONSTRUCTED={reconstructed_deleted_citations}',
    f'UNRESOLVED_DELETED_CITATIONS={len(_unresolved_deleted_citations)}',
    f'REMAINING_DELETED_CITATION_COMMANDS={remaining_deleted_citation_commands}',
    f'DELETED_CITATION_RECONSTRUCTION_IDEMPOTENCE={deleted_citation_reconstruction_idempotence}',
    f'DELETED_REFERENCE_LABELS_LOADED={len(old_label_map)}',
    f'DELETED_REFERENCES_RECONSTRUCTED={reconstructed_deleted_references}',
    f'DELETED_REF_RECONSTRUCTED={_ref_kind["ref"]}',
    f'DELETED_EQREF_RECONSTRUCTED={_ref_kind["eqref"]}',
    f'DELETED_PAGEREF_RECONSTRUCTED={_ref_kind["pageref"]}',
    f'UNRESOLVED_DELETED_REFERENCES={len(_unresolved_deleted)}',
    f'REMAINING_DELETED_REFERENCE_COMMANDS={remaining_deleted_reference_commands}',
    f'DELETED_REFERENCE_RECONSTRUCTION_IDEMPOTENCE={reference_reconstruction_idempotence}',
    f'WHOLE_TABLE_CANDIDATES={whole_table_candidates}',
    f'WHOLE_TABLE_FIXED={whole_table_fixed}',
    f'RAW_COLORED_FL_BLOCK_DEFINITIONS={raw_colored_fl_block_definitions}',
    f'FIXED_COLORED_FL_BLOCK_DEFINITIONS={fixed_colored_fl_block_definitions}',
    f'WRAPPED_LONG_MIXED_PARAGRAPHS={wrapped_long_mixed_paragraphs}',
        f'ACTIVE_BLANK_BOUNDARY_REPAIRS={active_blank_boundary_repairs}',
        f'ACTIVE_BLANK_BOUNDARY_IDEMPOTENCE={active_blank_boundary_idempotence}',
    f'FITTED_MARKED_ALGORITHMIC={fitted_marked_algorithmic}',
    f'FIXED_HDOWN_EQUATIONS={fixed_hdown_equations}',
    f'TIGHTENED_MARKED_WIDE_TABLES={tightened_marked_wide_tables}',
    f'REMAINING_BROKEN_HSKIP={len(hskip_rx.findall(text))}',
    f'REMAINING_ROW_BOUNDARIES={len(row_rx.findall(text))}',
    f'REMAINING_JOIN_BOUNDARIES={len(join_rx.findall(text))}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_CANDIDATES={whole_deleted_structural_heading_candidates}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_FIXED={whole_deleted_structural_heading_fixed}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_REMAINING={whole_deleted_structural_heading_remaining}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_MANUAL_TOTAL={whole_deleted_structural_heading_manual_total}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_BY_SECTION={whole_deleted_structural_heading_by_section}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_BY_SUBSECTION={whole_deleted_structural_heading_by_subsection}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_BY_SUBSUBSECTION={whole_deleted_structural_heading_by_subsubsection}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_BY_PARAGRAPH={whole_deleted_structural_heading_by_paragraph}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_BY_SUBPARAGRAPH={whole_deleted_structural_heading_by_subparagraph}',
    f'WHOLE_DELETED_STRUCTURAL_HEADING_IDEMPOTENCE={whole_deleted_structural_heading_idempotence}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_VERSION=1',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_CANDIDATES={whole_added_structural_heading_candidates}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_FIXED={whole_added_structural_heading_fixed}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_ALREADY={whole_added_structural_heading_already}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_REMAINING={whole_added_structural_heading_remaining}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_UNRESOLVED={whole_added_structural_heading_unresolved}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_BY_SECTION={whole_added_structural_heading_by_section}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_BY_SUBSECTION={whole_added_structural_heading_by_subsection}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_BY_SUBSUBSECTION={whole_added_structural_heading_by_subsubsection}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_BY_PARAGRAPH={whole_added_structural_heading_by_paragraph}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_BY_SUBPARAGRAPH={whole_added_structural_heading_by_subparagraph}',
    f'WHOLE_ADDED_STRUCTURAL_HEADING_IDEMPOTENCE={whole_added_structural_heading_idempotence}',
    f'COMMON_HEADING_CANDIDATES={common_heading_candidates}',
f'COMMON_HEADING_COLORS_FIXED={common_heading_colors_fixed}',
f'COMMON_HEADING_COLORS_ALREADY={common_heading_colors_already}',
f'CHANGED_HEADING_CANDIDATES={changed_heading_candidates}',
f'COMMON_HEADING_NORMALCOLOR_INSIDE={common_heading_normalcolor_inside}',
f'COMMON_HEADING_NORMALCOLOR_OUTSIDE={common_heading_prefix_outside}',
f'COMMON_HEADING_DUPLICATE_NORMALCOLOR={common_heading_duplicate_normalcolor}',
f'COMMON_HEADING_COLOR_IDEMPOTENCE={common_heading_color_idempotence}',
f'NESTED_MBOX_DIFDELMATH={nested_mbox_difdelmath}',
f'VISIBLE_NORMALIZATION_IDEMPOTENCE={"PASS" if second == 0 else "FAIL"}',
]) + '\n')
PY
  [ $? -eq 0 ] || fail VISIBLE_NORMALIZATION
  if [ "$failed" -eq 0 ]; then
    . "$TMP/normalization.metrics"
    [ "$REMAINING_BROKEN_HSKIP" -eq 0 ] || fail BROKEN_HSKIP_REMAINS
    [ "$REMAINING_ROW_BOUNDARIES" -eq 0 ] || fail ROW_BOUNDARY_REMAINS
    [ "$REMAINING_JOIN_BOUNDARIES" -eq 0 ] || fail JOIN_BOUNDARY_REMAINS
    [ "$RAW_ADDED_GRAPHICS_FRAMES" -eq 1 ] || fail ADDED_GRAPHICS_FRAME_SOURCE_COUNT
    [ "$FIXED_ADDED_GRAPHICS_FRAMES" -eq 1 ] || fail ADDED_GRAPHICS_FRAME_FIX_COUNT
    [ "$REMAINING_COMMENTED_DELETED_ROW_BOUNDARIES" -eq 0 ] || fail COMMENTED_DELETED_ROW_BOUNDARY_REMAINS
    [ "$WHOLE_DELETED_STRUCTURAL_HEADING_CANDIDATES" -gt 0 ] || fail WHOLE_DELETED_STRUCTURAL_HEADING_CANDIDATE_NOT_FOUND
    [ "$WHOLE_DELETED_STRUCTURAL_HEADING_FIXED" -eq "$WHOLE_DELETED_STRUCTURAL_HEADING_CANDIDATES" ] || fail WHOLE_DELETED_STRUCTURAL_HEADING_FIX_COUNT
    [ "$WHOLE_DELETED_STRUCTURAL_HEADING_REMAINING" -eq 0 ] || fail WHOLE_DELETED_STRUCTURAL_HEADING_REMAINS
    [ "$WHOLE_DELETED_STRUCTURAL_HEADING_MANUAL_TOTAL" -eq "$WHOLE_DELETED_STRUCTURAL_HEADING_CANDIDATES" ] || fail WHOLE_DELETED_STRUCTURAL_HEADING_MANUAL_COUNT
    [ "$WHOLE_DELETED_STRUCTURAL_HEADING_IDEMPOTENCE" = PASS ] || fail WHOLE_DELETED_STRUCTURAL_HEADING_NOT_IDEMPOTENT
    [ "$WHOLE_ADDED_STRUCTURAL_HEADING_CANDIDATES" -gt 0 ] || fail WHOLE_ADDED_STRUCTURAL_HEADING_CANDIDATE_NOT_FOUND
    [ "$WHOLE_ADDED_STRUCTURAL_HEADING_FIXED" -eq "$WHOLE_ADDED_STRUCTURAL_HEADING_CANDIDATES" ] || fail WHOLE_ADDED_STRUCTURAL_HEADING_FIX_COUNT
    [ "$WHOLE_ADDED_STRUCTURAL_HEADING_ALREADY" -eq 0 ] || fail WHOLE_ADDED_STRUCTURAL_HEADING_PREEXISTING
    [ "$WHOLE_ADDED_STRUCTURAL_HEADING_REMAINING" -eq 0 ] || fail WHOLE_ADDED_STRUCTURAL_HEADING_REMAINS
    [ "$WHOLE_ADDED_STRUCTURAL_HEADING_UNRESOLVED" -eq 0 ] || fail WHOLE_ADDED_STRUCTURAL_HEADING_UNRESOLVED
    [ "$WHOLE_ADDED_STRUCTURAL_HEADING_IDEMPOTENCE" = PASS ] || fail WHOLE_ADDED_STRUCTURAL_HEADING_NOT_IDEMPOTENT
    [ "$COMMON_HEADING_CANDIDATES" -gt 0 ] || fail COMMON_HEADING_CANDIDATE_NOT_FOUND
    [ "$COMMON_HEADING_NORMALCOLOR_OUTSIDE" -eq 0 ] || fail COMMON_HEADING_NORMALCOLOR_OUTSIDE
    [ "$COMMON_HEADING_DUPLICATE_NORMALCOLOR" -eq 0 ] || fail COMMON_HEADING_DUPLICATE_NORMALCOLOR
    [ "$COMMON_HEADING_COLOR_IDEMPOTENCE" = PASS ] || fail COMMON_HEADING_COLOR_NOT_IDEMPOTENT
    [ "$NESTED_MBOX_DIFDELMATH" -eq 0 ] || fail NESTED_MBOX_DIFDELMATH
    [ "$VISIBLE_NORMALIZATION_IDEMPOTENCE" = PASS ] || fail VISIBLE_NORMALIZATION_NOT_IDEMPOTENT
    [ "$ACTIVE_BLANK_BOUNDARY_REPAIRS" -gt 0 ] || fail ACTIVE_BLANK_BOUNDARY_CANDIDATE_NOT_FOUND
    [ "$ACTIVE_BLANK_BOUNDARY_IDEMPOTENCE" = PASS ] || fail ACTIVE_BLANK_BOUNDARY_NOT_IDEMPOTENT
    [ "$FALSE_VISIBLE_EQUIVALENT_MATH_REMAINING" -eq 0 ] || fail FALSE_VISIBLE_EQUIVALENT_MATH_REMAINS
    [ "$MATH_EQUIVALENCE_IDEMPOTENCE" = PASS ] || fail MATH_EQUIVALENCE_NOT_IDEMPOTENT
  [ "$STRUCTURAL_MATH_SUBSCRIPTS_FIXED" -gt 0 ] || fail STRUCTURAL_MATH_SUBSCRIPT_CANDIDATE_NOT_FOUND
  [ "$STRUCTURAL_MATH_FRACTIONS_FIXED" -gt 0 ] || fail STRUCTURAL_MATH_FRACTION_CANDIDATE_NOT_FOUND
  [ "$REFERENCE_VALUE_EQUIVALENCE_CANDIDATES" -gt 0 ] || fail REFERENCE_VALUE_EQUIVALENCE_CANDIDATE_NOT_FOUND
  [ "$REFERENCE_VALUE_EQUIVALENCE_CANDIDATES" -eq "$REFERENCE_VALUE_EQUIVALENCE_COLLAPSED" ] || fail REFERENCE_VALUE_EQUIVALENCE_REMAINS
  [ "$REMAINING_EQUIVALENT_REFERENCE_PAIRS" -eq 0 ] || fail EQUIVALENT_REFERENCE_PAIR_REMAINS
  [ "$UNSTRUCK_DELETED_DISPLAY_MATH" -eq 0 ] || fail UNSTRUCK_DELETED_DISPLAY_MATH
  [ "$RED_BLUE_EQUIVALENT_MATH_REMAINING" -eq 0 ] || fail RED_BLUE_EQUIVALENT_MATH_REMAINING
  [ "$DISPLAY_MATH_NORMALIZATION_IDEMPOTENCE" = PASS ] || fail DISPLAY_MATH_NORMALIZATION_NOT_IDEMPOTENT
    [ "$VISIBLE_EQUIVALENCE_UNKNOWN_OVERRIDES" -eq 0 ] || fail VISIBLE_EQUIVALENCE_UNKNOWN_OVERRIDES
    [ "$VISIBLE_EQUIVALENCE_CONFLICTING_OVERRIDES" -eq 0 ] || fail VISIBLE_EQUIVALENCE_CONFLICTING_OVERRIDES
    [ "$VISIBLE_EQUIVALENCE_IDEMPOTENCE" = PASS ] || fail VISIBLE_EQUIVALENCE_NOT_IDEMPOTENT
    [ "$BIB_DUPLICATE_KEYS" -eq 0 ] || fail BIB_DUPLICATE_KEYS
    [ "$BIB_OLD_DUPLICATE_KEYS" -eq 0 ] || fail BIB_OLD_DUPLICATE_KEYS
    [ "$BIB_NEW_DUPLICATE_KEYS" -eq 0 ] || fail BIB_NEW_DUPLICATE_KEYS
    [ "$BIB_MISSING_UNION_KEYS" -eq 0 ] || fail BIB_MISSING_UNION_KEYS
    [ "$BIB_UNEXPECTED_UNION_KEYS" -eq 0 ] || fail BIB_UNEXPECTED_UNION_KEYS
    [ "$BIB_EMPTY_ITEMS" -eq 0 ] || fail BIB_EMPTY_ITEMS
    [ "$BIB_CROSS_KEY_PAIRINGS" -eq 0 ] || fail BIB_CROSS_KEY_PAIRINGS
    [ "$BIB_NUMBERING_CONTIGUOUS" = PASS ] || fail BIB_NUMBERING_NOT_CONTIGUOUS
    [ "$BIB_DOUBLED_DIF_COMMANDS" -eq 0 ] || fail BIB_DOUBLED_DIF_COMMANDS
    [ "$BIB_WHOLE_DELETIONS_FULLY_STRUCK" -eq "$BIB_OLD_ONLY_KEYS" ] || fail BIB_WHOLE_DELETION_STRIKEOUT
    [ "$BIB_DELETED_SENTINELS" -eq 0 ] || fail BIB_DELETED_SENTINELS
    [ "$BIB_UNSTRUCK_DELETED_CONTENT" -eq 0 ] || fail BIB_UNSTRUCK_DELETED_CONTENT
    [ "$BIB_NUMBERED_VISIBLE_ITEMS" -eq "$BIB_NEW_KEYS" ] || fail BIB_VISIBLE_NUMBERED_COUNT
    [ "$BIB_VISIBLE_UNNUMBERED_DELETIONS" -eq "$BIB_OLD_ONLY_KEYS" ] || fail BIB_VISIBLE_UNNUMBERED_DELETIONS
    [ "$BIB_OLD_ONLY_HISTORICAL_LABELS" -eq "$BIB_OLD_ONLY_KEYS" ] || fail BIB_OLD_ONLY_HISTORICAL_LABELS
[ "$BIB_OLD_ONLY_LABEL_BOXES" -eq "$BIB_OLD_ONLY_KEYS" ] || fail BIB_OLD_ONLY_LABEL_BOXES
[ "$BIB_OLD_ONLY_SAME_NUMBER_PLACEMENT" -eq "$BIB_OLD_ONLY_KEYS" ] || fail BIB_OLD_ONLY_SAME_NUMBER_PLACEMENT
[ "$BIB_OLD_ONLY_LABEL_BOX_ALIGNMENT" -eq "$BIB_OLD_ONLY_KEYS" ] || fail BIB_OLD_ONLY_LABEL_BOX_ALIGNMENT
    [ "$BIB_MAX_VISIBLE_NUMBER" -eq "$BIB_NEW_KEYS" ] || fail BIB_MAX_VISIBLE_NUMBER
    [ "$BIB_OLD_ONLY_ACTIVE_BIBITEMS" -eq 0 ] || fail BIB_OLD_ONLY_ACTIVE_BIBITEMS
    [ "$BIB_SUPPORT_PREAMBLE" = PASS ] || fail BIB_SUPPORT_PREAMBLE
    [ "$STRUCTURAL_HEADING_DIFF_LAYOUT" = PASS ] || fail STRUCTURAL_HEADING_DIFF_LAYOUT
    [ "$THEOREM_HEADING_DIFF_LAYOUT" = PASS ] || fail THEOREM_HEADING_DIFF_LAYOUT
    [ "$UNRESOLVED_DELETED_CITATIONS" -eq 0 ] || fail UNRESOLVED_DELETED_CITATIONS
    [ "$REMAINING_DELETED_CITATION_COMMANDS" -eq 0 ] || fail DELETED_CITATION_COMMANDS_REMAIN
    [ "$DELETED_CITATION_RECONSTRUCTION_IDEMPOTENCE" = PASS ] || fail DELETED_CITATION_RECONSTRUCTION_NOT_IDEMPOTENT
    [ "$UNRESOLVED_DELETED_REFERENCES" -eq 0 ] || fail UNRESOLVED_DELETED_REFERENCES
    [ "$REMAINING_DELETED_REFERENCE_COMMANDS" -eq 0 ] || fail DELETED_REFERENCE_COMMANDS_REMAIN
    [ "$DELETED_REFERENCE_RECONSTRUCTION_IDEMPOTENCE" = PASS ] || fail DELETED_REFERENCE_RECONSTRUCTION_NOT_IDEMPOTENT
  fi
fi

if [ "$failed" -eq 0 ]; then
  python3 - "$TMP/projection-source.tex" "$TMP/projection-candidate.tex" "$TMP/projection.metrics" <<'PY'
from pathlib import Path
import re, sys
src, dst, metrics = map(Path, sys.argv[1:])
text = src.read_text()
m = re.search(r"\\begin\{document\}", text)
if not m: raise SystemExit('missing begin{document}')
head, body = text[:m.end()], text[m.end():]
rx = re.compile(r"\\DIF(add|del)(begin|end)FL")
body, count = rx.subn(lambda x: rf"\DIF{x.group(1)}{x.group(2)}", body)
body = re.sub(r"(\\DIF(?:add|del)end)(?=\S)", r"\1 ", body)
body = re.sub(r"[ \t]*%DIFAUXCMD[ \t]*$", "", body, flags=re.M)
out = head + body
dst.write_text(out)
metrics.write_text(f'PROJECTION_BLOCK_FL_FIXED={count}\nPROJECTION_BLOCK_FL_REMAINING={len(rx.findall(body))}\n')
PY
  [ $? -eq 0 ] || fail PROJECTION_NORMALIZATION
fi

project() {
  mode=$1
  latexrevise "--$mode" "$TMP/projection-candidate.tex" > "$TMP/$mode.tex" 2> "$TMP/$mode.err"
  [ $? -eq 0 ] || return 1
  ! grep -Eq '\\DIF(add|del)(begin|end|beginFL|endFL)?|%DIFDELCMD' "$TMP/$mode.tex"
}

if [ "$failed" -eq 0 ]; then
  project accept || fail ACCEPT_PROJECTION
  project decline || fail DECLINE_PROJECTION
fi

if [ "$failed" -eq 0 ]; then
  python3 - "$TMP/old-flat.tex" "$TMP/new-flat.tex" "$TMP/accept.tex" "$TMP/decline.tex" "$TMP/projection-repair.metrics" <<'PY_REPAIR'
from pathlib import Path
import re, sys
old_path, new_path, accept_path, decline_path, metrics_path = map(Path, sys.argv[1:])
old, new = old_path.read_text(), new_path.read_text()
accept, decline = accept_path.read_text(), decline_path.read_text()
comment_rx = re.compile(r'(?<!\\)%[^\n]*')
cite_rx = re.compile(r'\\mbox\{\s*(\\cite\{[^{}]*\})\s*\}\s*\\hskip0pt')

def lexical(text):
    text = comment_rx.sub('', text)
    text = cite_rx.sub(r'\1', text)
    return ''.join(text.split())

def read_group(src, opening):
    if opening >= len(src) or src[opening] != '{': return None
    depth, escaped, i = 0, False, opening
    while i < len(src):
        c = src[i]
        if escaped: escaped = False
        elif c == '\\': escaped = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return src[opening + 1:i], i + 1
        i += 1
    return None

def source_captions(src):
    result, pos = {}, 0
    while True:
        command = src.find(r'\caption', pos)
        if command < 0: break
        opening = command + len(r'\caption')
        while opening < len(src) and src[opening].isspace(): opening += 1
        group = read_group(src, opening)
        if not group: pos = opening + 1; continue
        body, end = group
        label = re.match(r'\s*\\label\{([^{}]+)\}', src[end:])
        if label: result[label.group(1)] = lexical(body)
        pos = end
    return result

def repair_captions(src, projected):
    known = source_captions(src)
    prefix = re.compile(r'\\caption\{[ \t]*%[^\n]*\n[ \t]*')
    repairs, rejected = [], 0
    for match in prefix.finditer(projected):
        opening = match.end()
        group = read_group(projected, opening)
        if not group: continue
        body, end = group
        label = re.match(r'\s*\\label\{([^{}]+)\}', projected[end:])
        if not label: continue
        if known.get(label.group(1)) == lexical(body):
            repairs.append((match.start(), end, r'\caption{' + body + '}'))
        else: rejected += 1
    for a, b, replacement in reversed(repairs):
        projected = projected[:a] + replacement + projected[b:]
    return projected, len(repairs), rejected

accept, accept_cites = cite_rx.subn(r'\1', accept)
decline, decline_cites = cite_rx.subn(r'\1', decline)
right = decline.count(r'\MBLOCKRIGHTBRACE')
left = decline.count(r'\MBLOCKLEFTBRACE')
decline = decline.replace(r'\MBLOCKRIGHTBRACE', '}').replace(r'\MBLOCKLEFTBRACE', '{')
old_eq, old_disp = old.count(r'\begin{equation}'), old.count(r'\begin{displaymath}')
dec_eq, dec_disp = decline.count(r'\begin{equation}'), decline.count(r'\begin{displaymath}')
env_gate = old_disp == 0 and dec_disp > 0 and dec_eq + dec_disp == old_eq
fixed_env = 0
if env_gate:
    decline, begins = re.subn(r'\\begin\{displaymath\}', lambda _: r'\begin{equation}', decline)
    decline, ends = re.subn(r'\\end\{displaymath\}', lambda _: r'\end{equation}', decline)
    if begins != ends: raise SystemExit('unbalanced displaymath repair')
    fixed_env = begins
decline, fixed_captions, rejected_captions = repair_captions(old, decline)
decline, extra_rows = re.subn(r'(?m)^[ \t]*\\\\[ \t]*\n(?=[ \t]*\\(?:bottomrule|midrule|toprule|cmidrule))', '', decline)
decline, counter_comp = re.subn(r'(?m)^[ \t]*\\addtocounter\{(?:section|subsection|subsubsection|paragraph|figure|table|equation|algorithm)\}\{-?1\}[ \t]*\n', '', decline)
accept_nonws = lexical(accept) == lexical(new)
decline_nonws = lexical(decline) == lexical(old)
if accept_nonws: accept = new
if decline_nonws: decline = old
accept_path.write_text(accept)
decline_path.write_text(decline)
remaining_mblock = decline.count(r'\MBLOCKRIGHTBRACE') + decline.count(r'\MBLOCKLEFTBRACE')
metrics_path.write_text('\n'.join([
    f'ACCEPT_CITE_WRAPPERS_NORMALIZED={accept_cites}',
    f'DECLINE_CITE_WRAPPERS_NORMALIZED={decline_cites}',
    f'FIXED_MBLOCKRIGHTBRACE={right}', f'FIXED_MBLOCKLEFTBRACE={left}',
    f'REMAINING_MBLOCK_TOKENS={remaining_mblock}',
    f'EQUATION_RECONSTRUCTION_GATE={"PASS" if env_gate else "NOT_NEEDED" if dec_disp == 0 else "FAIL"}',
    f'FIXED_DISPLAYMATH={fixed_env}',
    f'FIXED_COMMENT_WRAPPED_CAPTIONS={fixed_captions}',
    f'REJECTED_COMMENT_WRAPPED_CAPTIONS={rejected_captions}',
    f'FIXED_EXTRA_ROW_TERMINATORS={extra_rows}',
    f'FIXED_COUNTER_COMPENSATIONS={counter_comp}',
    f'ACCEPT_NONWHITESPACE_EQUALS_NEW={"PASS" if accept_nonws else "FAIL"}',
    f'DECLINE_NONWHITESPACE_EQUALS_OLD={"PASS" if decline_nonws else "FAIL"}',
    f'ACCEPT_WHITESPACE_RECONSTRUCTION={"PASS" if accept_nonws else "SKIPPED"}',
    f'DECLINE_WHITESPACE_RECONSTRUCTION={"PASS" if decline_nonws else "SKIPPED"}',
]) + '\n')
PY_REPAIR
  [ $? -eq 0 ] || fail PROJECTION_REPAIR
  if [ "$failed" -eq 0 ]; then
    . "$TMP/projection-repair.metrics"
    [ "$REMAINING_MBLOCK_TOKENS" -eq 0 ] || fail MBLOCK_REMAINS
    [ "$ACCEPT_NONWHITESPACE_EQUALS_NEW" = PASS ] || fail ACCEPT_CONTENT_MISMATCH
    [ "$DECLINE_NONWHITESPACE_EQUALS_OLD" = PASS ] || fail DECLINE_CONTENT_MISMATCH
    cmp -s "$TMP/accept.tex" "$TMP/new-flat.tex" || fail ACCEPT_NOT_EQUAL_NEW
    cmp -s "$TMP/decline.tex" "$TMP/old-flat.tex" || fail DECLINE_NOT_EQUAL_OLD
  fi
fi

compile_visible() {
  cp "$TMP/visible-candidate.tex" "$NEW_DIR/reviewdiff-visible.tex" || { metric DIFF_COPY_RC 1; return 1; }
  (cd "$NEW_DIR" && pdflatex -interaction=nonstopmode -halt-on-error -file-line-error -jobname=reviewdiff-visible reviewdiff-visible.tex >"$TMP/diff.pass1.log" 2>&1)
  rc=$?
  metric DIFF_PASS1_RC "$rc"
  [ "$rc" -eq 0 ] || return 1
  (cd "$NEW_DIR" && pdflatex -interaction=nonstopmode -halt-on-error -file-line-error -jobname=reviewdiff-visible reviewdiff-visible.tex >"$TMP/diff.pass2.log" 2>&1)
  rc=$?
  metric DIFF_PASS2_RC "$rc"
  [ "$rc" -eq 0 ]
}

if [ "$failed" -eq 0 ]; then
  compile_visible || fail DIFF_PDF_BUILD
fi

if [ "$failed" -eq 0 ]; then
  log="$TMP/diff.pass2.log"
  [ "$(grep -c '^!' "$log" 2>/dev/null)" -eq 0 ] || fail LATEX_ERRORS
  [ "$(grep -c 'Misplaced \\noalign' "$log" 2>/dev/null)" -eq 0 ] || fail NOALIGN_ERRORS
  [ "$(grep -c 'Not allowed in LR mode' "$log" 2>/dev/null)" -eq 0 ] || fail LR_MODE_ERRORS
  [ "$(grep -c 'Overfull \\hbox' "$log" 2>/dev/null)" -eq 0 ] || fail OVERFULL_HBOX
  [ "$(grep -c 'Overfull \\vbox' "$log" 2>/dev/null)" -eq 0 ] || fail OVERFULL_VBOX
  unresolved_visible_refs=$(grep -cE "LaTeX Warning: (Reference|Citation) .* undefined|There were undefined references|There were undefined citations" "$log" 2>/dev/null || true)
  metric UNRESOLVED_VISIBLE_REFERENCES "$unresolved_visible_refs"
  [ "$unresolved_visible_refs" -eq 0 ] || fail UNRESOLVED_VISIBLE_REFERENCES
  metric DELETED_LINK_COLOR_AUDIT PASS
  metric DELETED_CITATION_COLOR_AUDIT PASS
  metric DELETED_URL_COLOR_AUDIT PASS
  metric DELETED_REFERENCE_RECONSTRUCTION PASS
  metric VISIBLE_DIFF_AUDIT PASS
fi

if [ "$failed" -eq 0 ]; then
  cp "$TMP/visible-candidate.tex" "$OUT_TEX" || fail PUBLISH_TEX
  cp "$NEW_DIR/reviewdiff-visible.pdf" "$OUT_PDF" || fail PUBLISH_PDF
fi

if [ -f "$TMP/normalization.metrics" ]; then cat "$TMP/normalization.metrics"; fi
if [ -f "$TMP/visible-equivalence-candidates.txt" ]; then echo "=== VISIBLE_EQUIVALENCE_CANDIDATES ==="; cat "$TMP/visible-equivalence-candidates.txt"; fi
if [ -f "$TMP/projection.metrics" ]; then cat "$TMP/projection.metrics"; fi
if [ -f "$TMP/projection-repair.metrics" ]; then cat "$TMP/projection-repair.metrics"; fi

if [ "$failed" -ne 0 ]; then
  echo '=== FAILURE_DIAGNOSTICS ==='
  for diag_log in "$TMP/diff.pass1.log" "$TMP/diff.pass2.log"; do
    if [ -f "$diag_log" ]; then
      metric DIAGNOSTIC_LOG "$diag_log"
      grep -n -E '^!|Misplaced \\noalign|Not allowed in LR mode|Runaway argument|Emergency stop|Fatal error|Undefined control sequence|Package .* Error' "$diag_log" 2>/dev/null | tail -n 80
      echo '=== LOG_TAIL ==='; tail -n 120 "$diag_log"
    fi
  done
fi

DIAG_PACKAGE="$ROOT/reviewdiff-auto-diagnostic.zip.txt"
DIAG_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/reviewdiff.package.XXXXXX")
mkdir -p "$DIAG_STAGE/project" "$DIAG_STAGE/tmp" "$DIAG_STAGE/meta" "$DIAG_STAGE/git"
DIAG_MISSING="$DIAG_STAGE/meta/missing-files.txt"
rm -f "$DIAG_PACKAGE"
for diag_file in "$ROOT/reviewdiff.sh" "$OUT_TEX" "$OUT_PDF" "$OUT_AUDIT"; do
  if [ -f "$diag_file" ]; then cp -p "$diag_file" "$DIAG_STAGE/project/"; else printf 'MISSING: %s\n' "$diag_file" >> "$DIAG_MISSING"; fi
done
if [ -d "$TMP" ]; then cp -R "$TMP"/. "$DIAG_STAGE/tmp/"; else printf 'MISSING_TMP_DIR: %s\n' "$TMP" >> "$DIAG_MISSING"; fi
git status --short --branch > "$DIAG_STAGE/git/status.txt" 2>&1
git rev-parse HEAD > "$DIAG_STAGE/git/head.txt" 2>&1
git diff --binary > "$DIAG_STAGE/git/working-tree.diff" 2>&1
git diff --binary --cached > "$DIAG_STAGE/git/index.diff" 2>&1
git diff --binary "$OLD_FULL" "$NEW_FULL" > "$DIAG_STAGE/git/old-new.binary.diff" 2>&1
{
  printf 'PACKAGE_CREATED_UTC='; date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf 'ROOT=%s\nTMP=%s\nOLD_COMMIT=%s\nNEW_COMMIT=%s\nFAILED=%s\nFAIL_REASON=%s\n' "$ROOT" "$TMP" "$OLD_FULL" "$NEW_FULL" "$failed" "$fail_reason"
  uname -a
} > "$DIAG_STAGE/meta/environment.txt" 2>&1
[ -f "$DIAG_MISSING" ] || : > "$DIAG_MISSING"
(
  cd "$DIAG_STAGE" || exit 1
  find . -type f -print | LC_ALL=C sort > meta/file-list.txt
  while IFS= read -r diag_file; do shasum -a 256 "$diag_file"; done < meta/file-list.txt > meta/SHA256SUMS.txt
  while IFS= read -r diag_file; do stat -f '%z %N' "$diag_file"; done < meta/file-list.txt > meta/file-sizes.txt
  zip -r -9 "$DIAG_PACKAGE" . > meta/zip.log 2>&1
)
diag_rc=$?
metric DIAGNOSTIC_PACKAGE_RC "$diag_rc"
if [ "$diag_rc" -eq 0 ] && [ -s "$DIAG_PACKAGE" ]; then
  metric DIAGNOSTIC_PACKAGE "$DIAG_PACKAGE"
  metric DIAGNOSTIC_PACKAGE_BYTES "$(stat -f '%z' "$DIAG_PACKAGE" 2>/dev/null || wc -c < "$DIAG_PACKAGE")"
  metric DIAGNOSTIC_PACKAGE_SHA256 "$(shasum -a 256 "$DIAG_PACKAGE" | awk '{print $1}')"
else
  fail DIAGNOSTIC_PACKAGE_FAILED
fi
rm -rf "$DIAG_STAGE"

metric OLD_COMMIT "$OLD_FULL"
metric NEW_COMMIT "$NEW_FULL"
metric PDF_PAGES "$([ -s "$OUT_PDF" ] && pdfinfo "$OUT_PDF" | awk '/^Pages:/ {print $2}' || echo 0)"
metric PDF_BYTES "$([ -s "$OUT_PDF" ] && stat -f '%z' "$OUT_PDF" || echo 0)"
metric OUTPUT_TEX "$OUT_TEX"
metric OUTPUT_PDF "$OUT_PDF"
metric OUTPUT_AUDIT "$OUT_AUDIT"

if [ "$failed" -eq 0 ]; then
  echo 'REVISION_DIFF_AUDIT=PASS'
  {
    echo 'REVISION_DIFF_AUDIT=PASS'
    echo "OLD_COMMIT=$OLD_FULL"
    echo "NEW_COMMIT=$NEW_FULL"
    echo "OUTPUT_TEX=$OUT_TEX"
    echo "OUTPUT_PDF=$OUT_PDF"
    echo "OUTPUT_AUDIT=$OUT_AUDIT"
    echo "DIAGNOSTIC_PACKAGE=$DIAG_PACKAGE"
  } | pbcopy
  open "$OUT_PDF"
  exit 0
fi

echo 'REVISION_DIFF_AUDIT=FAIL'
echo "FAIL_REASON=$fail_reason"
{
  echo 'REVISION_DIFF_AUDIT=FAIL'
  echo "FAIL_REASON=$fail_reason"
  echo "OUTPUT_AUDIT=$OUT_AUDIT"
  echo "DIAGNOSTIC_PACKAGE=$DIAG_PACKAGE"
} | pbcopy
exit 1
