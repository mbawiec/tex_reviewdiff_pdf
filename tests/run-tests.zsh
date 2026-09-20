#!/bin/zsh
ROOT=${0:A:h:h}
MODE=${1:-quick}
shift 2>/dev/null || true
if [[ "$MODE" == "quick" ]]; then
  exec "$ROOT/reviewdiff" test quick "$@"
elif [[ "$MODE" == "full" ]]; then
  exec "$ROOT/reviewdiff" test full "$@"
else
  print -r -- 'USAGE:'
  print -r -- '  ./tests/run-tests.zsh quick'
  print -r -- '  ./tests/run-tests.zsh full --project /path/to/project [--old SHA --new SHA --main main.tex --keep-tmp]'
  return 2 2>/dev/null || true
fi
