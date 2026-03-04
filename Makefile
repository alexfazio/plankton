.PHONY: install lint test format install-hooks strict strict-protected clean

install:
	uv sync --all-extras

lint:
	uv run ruff check src tests
	uv run ruff format --check src tests

test:
	uv run pytest tests/

format:
	uv run ruff format src tests
	uv run ruff check --fix src tests

install-hooks:
	uv run pre-commit install

strict:
	@files="$$(git diff --cached --name-only --diff-filter=ACMR)"; \
	if [ -z "$$files" ]; then \
		echo "No staged files to check."; \
		exit 0; \
	fi; \
	uv run pre-commit run plankton-strict-runtime --hook-stage manual --files $$files

strict-protected:
	@if [ -z "$(FILES)" ]; then \
		echo "Usage: make strict-protected FILES='.semgrep.yml'"; \
		exit 1; \
	fi; \
	PLANKTON_STRICT_ALLOW_PROTECTED=1 \
	uv run pre-commit run plankton-strict-runtime --hook-stage manual --files $(FILES)

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type d -name .pytest_cache -exec rm -rf {} +
	rm -rf dist build *.egg-info
