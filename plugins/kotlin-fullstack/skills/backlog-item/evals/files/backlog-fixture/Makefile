# The gate of this fixture: the same target CI would run.
PY ?= python3
.PHONY: check fix
check:
	$(PY) scripts/backlog_index.py --check
	$(PY) scripts/docs_check.py
	$(PY) scripts/coverage_map.py --check
fix:
	$(PY) scripts/backlog_index.py
	$(PY) scripts/coverage_map.py --fix
