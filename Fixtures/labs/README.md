# Synthetic lab-report text fixtures

Invented text that only *resembles* common report layouts. Every person, ID, address, and value here is made up and contains `SYNTHETIC` / `ZZTEST` markers. **No real PHI ever goes in this repo.**

- `*.synthetic.txt`: extracted text as PDFKit/Vision would return it (one line per row, form feed = page break).
- `*.expected.json`: the rows the parser must find (`analyte` key, `value`, canonical `unit`, report `ref_low`/`ref_high`/`flag`), the collection date, and `forbidden` identifier strings that must never appear in any candidate.

Real redacted reports (M2 exit criterion: ≥ 30 reports from ≥ 5 formats) go in a separate, git-ignored local folder. They are never committed.
