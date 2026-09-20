# CLI `reviewdiff`

CLI oddziela repozytorium narzędzia od repozytorium analizowanego projektu.

## Diagnostyka

```zsh
./reviewdiff doctor \
  --project /Users/drone/Documents/Publications/pawr-ieee-iot \
  --old 19bdc838918c9e89a4d4451784dd078e0a0671e1 \
  --new 93dbca00a6d4e6a494f1eb923223c0bd90ddf765 \
  --main main.tex
```

## Uruchomienie

```zsh
./reviewdiff run \
  --project /Users/drone/Documents/Publications/pawr-ieee-iot \
  --old 19bdc838918c9e89a4d4451784dd078e0a0671e1 \
  --new 93dbca00a6d4e6a494f1eb923223c0bd90ddf765 \
  --main main.tex \
  --keep-tmp
```

## Test szybki

```zsh
./reviewdiff test quick
```

## Test pełny

```zsh
./reviewdiff test full \
  --project /Users/drone/Documents/Publications/pawr-ieee-iot \
  --old 19bdc838918c9e89a4d4451784dd078e0a0671e1 \
  --new 93dbca00a6d4e6a494f1eb923223c0bd90ddf765 \
  --main main.tex \
  --keep-tmp
```

## Weryfikacja istniejącego wyniku

```zsh
./reviewdiff verify \
  --project /Users/drone/Documents/Publications/pawr-ieee-iot \
  --old 19bdc838918c9e89a4d4451784dd078e0a0671e1 \
  --new 93dbca00a6d4e6a494f1eb923223c0bd90ddf765
```

## Wyciągnięcie Git diff

```zsh
./reviewdiff extract-git-diff \
  --project /Users/drone/Documents/Publications/pawr-ieee-iot \
  --output /Users/drone/Documents/Publications/pawr-ieee-iot/old-new.binary.diff
```

CLI używa wyłącznie biblioteki standardowej Pythona. Nie wymaga instalowania `fire`.
