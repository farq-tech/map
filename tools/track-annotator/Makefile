# tools/track-annotator — three commands: make setup / make run / make test
PY ?= python3.12
VENV = .venv

setup:
	$(PY) -m venv $(VENV)
	$(VENV)/bin/pip install -q --upgrade pip
	$(VENV)/bin/pip install -q -r requirements.txt

run:
	$(VENV)/bin/python -m annotator serve --port 8791

test:
	$(VENV)/bin/python -m pytest

.PHONY: setup run test
