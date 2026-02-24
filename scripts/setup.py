# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "rich",
#     "typer",
# ]
# ///
"""Interactive setup wizard for Plankton.

Detects project languages, checks dependencies, and generates
the `.claude/hooks/config.json` configuration file.
"""

import json
import os
import shutil
import subprocess  # noqa: S404
from copy import deepcopy
from pathlib import Path
from typing import Any

import typer
from rich.console import Console
from rich.panel import Panel
from rich.prompt import Confirm

console = Console()
app = typer.Typer()

CONFIG_PATH = Path(".claude/hooks/config.json")
HOOKS_DIR = Path(".claude/hooks")

REQUIRED_TOOLS = {
    "jaq": "Essential for JSON parsing in hooks. Install via brew/apt/pacman.",
    "ruff": "Required for Python linting. Install via 'uv pip install ruff'.",
    "uv": "Required for package management. Install via 'curl -LsSf https://astral.sh/uv/install.sh | sh'.",
}

OPTIONAL_TOOLS = {
    "shellcheck": "Shell script analysis",
    "shfmt": "Shell script formatting",
    "hadolint": "Dockerfile linting",
    "yamllint": "YAML linting",
    "taplo": "TOML formatting/linting",
    "markdownlint-cli2": "Markdown linting",
    "biome": "JavaScript/TypeScript linting & formatting",
}

DEFAULT_CONFIG = {
    "languages": {
        "python": True,
        "shell": True,
        "yaml": True,
        "json": True,
        "toml": True,
        "dockerfile": True,
        "markdown": True,
        "typescript": {
            "enabled": True,
            "js_runtime": "auto",
            "biome_nursery": "warn",
            "biome_unsafe_autofix": False,
            "oxlint_tsgolint": False,
            "tsgo": False,
            "semgrep": True,
            "knip": False,
        },
    },
    "protected_files": [
        ".markdownlint.jsonc",
        ".markdownlint-cli2.jsonc",
        ".shellcheckrc",
        ".yamllint",
        ".hadolint.yaml",
        ".jscpd.json",
        ".flake8",
        "taplo.toml",
        ".ruff.toml",
        "ty.toml",
        "biome.json",
        ".oxlintrc.json",
        ".semgrep.yml",
        "knip.json",
    ],
    "exclusions": ["tests/", "docs/", ".venv/", "scripts/", "node_modules/", ".git/", ".claude/"],
    "phases": {"auto_format": True, "subprocess_delegation": True},
    "subprocess": {
        "timeout": 300,
        "model_selection": {
            "sonnet_patterns": (
                "C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+|"
                "complexity|useExhaustiveDependencies|noFloatingPromises|useAwaitThenable|no-unsafe-argument|"
                "no-unsafe-assignment|no-unsafe-return|no-unsafe-call|no-unsafe-member-access|"
                "no-unsafe-type-assertion|no-unsafe-unary-minus|no-unsafe-enum-comparison|no-misused-promises|"
                "no-unnecessary-type-assertion|no-unnecessary-type-arguments|"
                "no-unnecessary-boolean-literal-compare|strict-boolean-expressions|await-thenable|"
                "no-unnecessary-condition|no-confusing-void-expression|no-base-to-string|"
                "no-redundant-type-constituents|no-duplicate-type-constituents|no-floating-promises|"
                "no-implied-eval|no-deprecated|no-for-in-array|no-misused-spread|no-array-delete|"
                "switch-exhaustiveness-check|unbound-method|return-await|only-throw-error|require-await|"
                "require-array-sort-compare|restrict-plus-operands|restrict-template-expressions|"
                "prefer-promise-reject-errors|promise-function-async"
            ),
            "opus_patterns": "unresolved-attribute|type-assertion",
            "volume_threshold": 5,
        },
    },
    "jscpd": {"session_threshold": 3, "scan_dirs": ["src/", "lib/"], "advisory_only": True},
    "package_managers": {
        "python": "uv",
        "javascript": "bun",
        "allowed_subcommands": {
            "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
            "pip": ["download"],
            "yarn": ["audit", "info"],
            "pnpm": ["audit", "info"],
            "poetry": [],
            "pipenv": [],
        },
    },
}

SCAN_EXCLUDE_DIRS = {".git", ".venv", "node_modules", ".claude", "__pycache__"}


def _is_excluded_path(path: Path) -> bool:
    """Return True when a path should be excluded from language detection."""
    return any(part in SCAN_EXCLUDE_DIRS for part in path.parts)


def _has_any(pattern: str) -> bool:
    """Return True if a non-excluded file matching pattern exists anywhere."""
    return any(match.is_file() and not _is_excluded_path(match) for match in Path(".").rglob(pattern))


def load_language_defaults(detected: dict[str, bool]) -> dict[str, bool]:
    """Merge detected language defaults with existing config language choices."""
    defaults = dict(detected)
    if not CONFIG_PATH.exists():
        return defaults

    try:
        with open(CONFIG_PATH, encoding="utf-8") as file_handle:
            existing_config = json.load(file_handle)
    except Exception:
        return defaults

    languages = existing_config.get("languages")
    if not isinstance(languages, dict):
        return defaults

    simple_languages = ["python", "shell", "dockerfile", "yaml", "json", "toml", "markdown"]
    for language in simple_languages:
        existing_value = languages.get(language)
        if isinstance(existing_value, bool):
            defaults[language] = existing_value

    existing_typescript = languages.get("typescript")
    if isinstance(existing_typescript, bool):
        defaults["typescript"] = existing_typescript
    elif isinstance(existing_typescript, dict):
        defaults["typescript"] = bool(existing_typescript.get("enabled", True))

    return defaults


def load_existing_config() -> dict[str, Any]:
    """Load existing config file if present and valid, else return empty dict."""
    if not CONFIG_PATH.exists():
        return {}

    try:
        with open(CONFIG_PATH, encoding="utf-8") as file_handle:
            existing_config = json.load(file_handle)
    except Exception:
        return {}

    if not isinstance(existing_config, dict):
        return {}
    return existing_config


def merge_config(existing_config: dict[str, Any], generated_config: dict[str, Any]) -> dict[str, Any]:
    """Merge generated config into existing config while preserving unknown keys."""
    merged = deepcopy(existing_config)
    merged.update(generated_config)
    return merged


def check_tools():
    """Verify that required system tools are installed."""
    console.print("[bold blue]Checking System Dependencies...[/bold blue]")
    missing_required = []

    for tool, desc in REQUIRED_TOOLS.items():
        path = shutil.which(tool)
        if path:
            console.print(f"  [green]✓[/green] {tool} found at {path}")
        else:
            console.print(f"  [red]✗[/red] {tool} NOT found. {desc}")
            missing_required.append(tool)

    if missing_required:
        console.print("\n[bold red]Missing required tools. Please install them and run this script again.[/bold red]")
        if "jaq" in missing_required:
            console.print(
                "  [yellow]Note: 'jaq' is a faster alternative to 'jq'. "
                "On macOS: 'brew install jaq'. "
                "On Linux: 'apt/pacman install jaq' or download from GitHub.[/yellow]"
            )
        # We don't exit here, we let the user proceed to config generation if they want
        if not Confirm.ask("Continue anyway?"):
            raise typer.Exit(code=1)

    console.print("\n[bold blue]Checking Optional Linters...[/bold blue]")
    for tool, desc in OPTIONAL_TOOLS.items():
        path = shutil.which(tool)
        if path:
            console.print(f"  [green]✓[/green] {tool} found")
        else:
            console.print(f"  [dim]•[/dim] {tool} not found ({desc})")


def detect_languages() -> dict[str, bool]:
    """Detect used languages in the project based on file existence."""
    console.print("\n[bold blue]Detecting Project Languages...[/bold blue]")
    detected = {}

    # Python
    if Path("pyproject.toml").exists() or _has_any("*.py"):
        console.print("  [green]✓[/green] Python detected (pyproject.toml or .py files)")
        detected["python"] = True
    else:
        detected["python"] = False

    # TypeScript/JS
    if Path("package.json").exists() or _has_any("*.ts") or _has_any("*.js"):
        console.print("  [green]✓[/green] TypeScript/JavaScript detected (package.json or .ts/.js files)")
        detected["typescript"] = True  # We use the complex object structure later
    else:
        detected["typescript"] = False

    # Shell
    if _has_any("*.sh"):
        console.print("  [green]✓[/green] Shell scripts detected (*.sh)")
        detected["shell"] = True
    else:
        detected["shell"] = False

    # Docker
    if Path("Dockerfile").exists() or Path("docker-compose.yml").exists():
        console.print("  [green]✓[/green] Docker detected")
        detected["dockerfile"] = True
    else:
        detected["dockerfile"] = False

    return detected


def configure_languages(defaults: dict[str, bool]) -> dict[str, Any]:  # noqa: PLR0912
    """Interactive wizard to enable/disable languages."""
    console.print("\n[bold blue]Configuration Wizard[/bold blue]")
    config = deepcopy(DEFAULT_CONFIG)

    # Python
    if Confirm.ask("Enable Python enforcement?", default=defaults.get("python", True)):
        config["languages"]["python"] = True
    else:
        config["languages"]["python"] = False

    # TypeScript
    if Confirm.ask("Enable TypeScript/JavaScript enforcement?", default=defaults.get("typescript", True)):
        # If enabling, use the default complex object
        # If currently boolean in default config, swap to object
        pass  # Keep default object
    else:
        config["languages"]["typescript"] = False  # Set to false

    # Shell
    if Confirm.ask("Enable Shell Script enforcement?", default=defaults.get("shell", True)):
        config["languages"]["shell"] = True
    else:
        config["languages"]["shell"] = False

    # Docker
    if Confirm.ask("Enable Dockerfile enforcement?", default=defaults.get("dockerfile", True)):
        config["languages"]["dockerfile"] = True
    else:
        config["languages"]["dockerfile"] = False

    # Others (group them to be less tedious)
    others = ["yaml", "json", "toml", "markdown"]
    if Confirm.ask("Enable other formats (YAML, JSON, TOML, Markdown)?", default=True):
        for lang in others:
            config["languages"][lang] = True
    else:
        for lang in others:
            if Confirm.ask(f"Enable {lang}?", default=False):
                config["languages"][lang] = True
            else:
                config["languages"][lang] = False

    return config


def setup_hooks():
    """Ensure hooks directory exists and scripts are executable."""
    console.print("\n[bold blue]Setting up Hooks...[/bold blue]")

    if not HOOKS_DIR.exists():
        console.print(f"  [yellow]![/yellow] Hooks directory {HOOKS_DIR} not found. Are you in the project root?")
        if Confirm.ask("Create .claude/hooks directory?"):
            HOOKS_DIR.mkdir(parents=True, exist_ok=True)
        else:
            return

    # Make scripts executable
    console.print("  Making hook scripts executable...")
    for script in HOOKS_DIR.glob("*.sh"):
        # S103: Chmod 755 is standard for executable scripts
        os.chmod(script, 0o755)  # noqa: S103
        console.print(f"    [green]✓[/green] chmod +x {script.name}")

    # Check pre-commit
    if Path(".pre-commit-config.yaml").exists():
        if shutil.which("pre-commit"):
            console.print("  Installing pre-commit hooks...")
            try:
                subprocess.run(["pre-commit", "install"], check=True)  # noqa: S607
                console.print("    [green]✓[/green] pre-commit installed")
            except subprocess.CalledProcessError:
                console.print("    [red]✗[/red] pre-commit install failed")
        else:
            console.print("  [yellow]![/yellow] .pre-commit-config.yaml found but 'pre-commit' not installed.")


@app.command()
def main():
    """Run the main setup wizard."""
    console.print(Panel.fit("Plankton Setup Wizard", style="bold magenta"))

    check_tools()

    detected_langs = detect_languages()
    prompt_defaults = load_language_defaults(detected_langs)

    existing_config = load_existing_config()
    if existing_config:
        console.print(f"  [dim]Loaded existing configuration from {CONFIG_PATH}[/dim]")
    elif CONFIG_PATH.exists():
        console.print(f"  [yellow]Could not parse existing {CONFIG_PATH}, starting fresh.[/yellow]")

    new_config = configure_languages(prompt_defaults)
    new_config = merge_config(existing_config, new_config)

    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)

    # Write config
    console.print(f"\n[bold]Writing configuration to {CONFIG_PATH}...[/bold]")
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(new_config, f, indent=2)
    console.print("  [green]✓[/green] Configuration saved.")

    setup_hooks()

    console.print("\n[bold green]Setup Complete![/bold green]")
    console.print("Run a Claude Code session to start using Plankton.")
    console.print("To test hooks manually: [cyan].claude/hooks/test_hook.sh --self-test[/cyan]")


if __name__ == "__main__":
    app()
