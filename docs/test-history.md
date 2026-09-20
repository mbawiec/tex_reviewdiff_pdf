# Historia zamkniętych klas regresji

## TEST46

- Reguła: `ACTIVE_BLANK_BOUNDARY_AFTER_DELETED_PARAGRAPH_VERSION=1`.
- Klasyfikacja: wyłącznie prezentacyjna.
- Zablokowany SHA256: `a56c8a6112138f0069d43aee894cb3a2b1bddf8cf87ac38ec5ebf44f50674bee`.
- Pełny pipeline: PASS.
- Accept dokładnie równy NEW: PASS.
- Decline dokładnie równy OLD: PASS.
- Binarny Git diff: 14/14 ścieżek.
- Testy dodatnie, negatywne, wielokrotne i idempotencja: PASS.

Nie otwierać bez nowego dowodu regresji.

## Pozostałe zamknięte reguły

- FIX31: ochrona tekstowych atomów matematycznych.
- `WHOLE_DELETED_STRUCTURAL_HEADING_VERSION=2`.
- FIX42B / `WHOLE_ADDED_STRUCTURAL_HEADING_VERSION=2`.
- `COMMON_RUNIN_HEADING_COLOR_ISOLATION_VERSION=3`.

Przesunięty prefiks wspólnego nagłówka pozostaje osobnym problemem poza TEST46.
