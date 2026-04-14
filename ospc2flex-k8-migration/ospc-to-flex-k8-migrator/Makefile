.PHONY: install test lint clean help

PYTHON  ?= python3
PIP     ?= pip3
SRC_DIR  = src
TEST_DIR = tests

help:
	@echo "Targets:"
	@echo "  install    Install runtime + dev dependencies"
	@echo "  test       Run unit tests with coverage"
	@echo "  lint       Run ruff/flake8 linter"
	@echo "  clean      Remove build artefacts"

install:
	$(PIP) install -e ".[dev]" 2>/dev/null || \
	  $(PIP) install -r requirements.txt -r requirements-dev.txt

test:
	$(PYTHON) -m pytest $(TEST_DIR) -v --tb=short \
	  --cov=$(SRC_DIR)/ospc_to_flex_k8 --cov-report=term-missing

lint:
	$(PYTHON) -m ruff check $(SRC_DIR) $(TEST_DIR) 2>/dev/null || \
	  $(PYTHON) -m flake8 $(SRC_DIR) $(TEST_DIR) --max-line-length=100

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	rm -rf .pytest_cache .coverage htmlcov dist build *.egg-info
