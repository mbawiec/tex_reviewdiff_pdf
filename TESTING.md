# Testowanie

## Szybkie testy narzędzia

```zsh
./reviewdiff test quick
```

Nie wymagają repozytorium artykułu.

## Pełny test na zewnętrznym projekcie

```zsh
./reviewdiff test full \
  --project /Users/drone/Documents/Publications/pawr-ieee-iot \
  --old 19bdc838918c9e89a4d4451784dd078e0a0671e1 \
  --new 93dbca00a6d4e6a494f1eb923223c0bd90ddf765 \
  --main main.tex \
  --keep-tmp
```

Runner najpierw wykonuje `doctor`. Jeżeli wskazane repozytorium nie zawiera obu commitów lub `main.tex`, kończy się czytelnym `FAIL` przed uruchomieniem kosztownego pipeline.

Po sukcesie pełnego pipeline wykonywane są:

- dokładne `accept == NEW`;
- dokładne `decline == OLD`;
- `git apply --check --binary`;
- zastosowanie binarnego Git diff do OLD;
- porównanie wszystkich zmienionych ścieżek z NEW;
- kontrola bramek audytu i zamkniętych regresji.
