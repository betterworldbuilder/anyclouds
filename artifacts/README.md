# artifacts

Generated migration output — tenant deploy scripts, flavormaps, blockmaps,
rollback scripts, per-account CSVs. Everything here is reproducible output,
not source.

The contents are gitignored; only this README is tracked.

**Wiring note:** four report files currently written to the repo root are read
back and served by `workflow_dashboard/app.py` and must be redirected here
together with their call sites:
`Final_Migration_TCO_Report.csv` / `.xlsx` (~line 21488),
`TCO_Comparison_Report.csv` (~line 21571), `1342314_flavormap.csv` (~line 21520).
