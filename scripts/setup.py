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
import re
import shlex
import shutil
import subprocess  # noqa: S404  # nosec B404
from copy import deepcopy
from pathlib import Path
from platform import system
from types import SimpleNamespace
from typing import Any, cast


class _FallbackExit(SystemExit):
    def __init__(self, code: int = 0) -> None:
        super().__init__(code)
        self.code = code


class _FallbackTyperError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("No command registered on fallback Typer app.")


class _FallbackTyper:
    def __init__(self) -> None:
        self._main: Any = None

    def command(self):
        def decorator(func):
            self._main = func
            return func

        return decorator

    def __call__(self) -> None:
        if self._main is None:
            raise _FallbackTyperError()
        self._main()


typer: Any
try:
    import typer as _typer
except ModuleNotFoundError:
    typer = SimpleNamespace(Exit=_FallbackExit, Typer=_FallbackTyper)
else:
    typer = _typer

_RICH_STYLE_TOKENS = {
    "bold",
    "dim",
    "italic",
    "underline",
    "blink",
    "reverse",
    "strike",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
    "white",
    "black",
}
_RICH_TAG_PATTERN = re.compile(r"\[([^\]]+)\]")


def _strip_rich_markup(value: str) -> str:
    """Strip rich-style tags while preserving literal bracket content."""

    def _replace_tag(match: re.Match[str]) -> str:
        inner = match.group(1).strip()
        if inner.startswith("/"):
            inner = inner[1:].strip()
        tokens = inner.split()
        if tokens and all(token in _RICH_STYLE_TOKENS for token in tokens):
            return ""
        return match.group(0)

    return _RICH_TAG_PATTERN.sub(_replace_tag, value)


class _FallbackConsole:
    @staticmethod
    def print(*args, **_kwargs) -> None:  # noqa: D102
        text = " ".join(str(arg) for arg in args)
        print(_strip_rich_markup(text))


class _FallbackPanel:
    @staticmethod
    def fit(text: str, style: str = "") -> str:  # noqa: D102
        del style
        return text


class _FallbackConfirm:
    @staticmethod
    def ask(prompt: str, default: bool = True) -> bool:  # noqa: D102
        suffix = " [Y/n]: " if default else " [y/N]: "
        answer = input(f"{_strip_rich_markup(prompt)}{suffix}").strip().lower()
        if not answer:
            return default
        return answer in {"y", "yes"}


Console: Any
Panel: Any
Confirm: Any
try:
    from rich.console import Console as _Console
    from rich.panel import Panel as _Panel
    from rich.prompt import Confirm as _Confirm
except ModuleNotFoundError:
    Console = _FallbackConsole
    Panel = _FallbackPanel
    Confirm = _FallbackConfirm
else:
    Console = _Console
    Panel = _Panel
    Confirm = _Confirm


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
    "security_linter_exclusions": [".venv/", "node_modules/", ".git/"],
    "phases": {"auto_format": True, "subprocess_delegation": True},
    "subprocess": {
        "settings_file": ".claude/subprocess-settings.json",
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
LOCAL_BIN_DIR = Path.home() / ".local" / "bin"
JAQ_LINUX_COMMANDS = {
    "apt-get": ["apt-get", "install", "-y", "jaq"],
    "dnf": ["dnf", "install", "-y", "jaq"],
    "yum": ["yum", "install", "-y", "jaq"],
    "pacman": ["pacman", "-Sy", "--noconfirm", "jaq"],
    "apk": ["apk", "add", "jaq"],
    "zypper": ["zypper", "install", "-y", "jaq"],
}


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
    """Deep merge generated config into existing, preserving nested keys not in generated."""
    merged = deepcopy(existing_config)
    for key, value in generated_config.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = merge_config(merged[key], value)
        else:
            merged[key] = deepcopy(value)
    return merged


def _path_persist_hint() -> str:
    shell_name = Path(os.environ.get("SHELL", "")).name
    if shell_name == "bash":
        return "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.bashrc"
    if shell_name == "zsh":
        return "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"
    if shell_name == "fish":
        return "fish_add_path ~/.local/bin"
    return "Add ~/.local/bin to PATH in your shell profile."


def _ensure_local_bin_on_path(show_hint: bool = False) -> bool:
    """Ensure ~/.local/bin is available in this process PATH."""
    local_bin = str(LOCAL_BIN_DIR)
    path_entries = os.environ.get("PATH", "").split(os.pathsep)
    if not LOCAL_BIN_DIR.exists():
        return False
    if local_bin in path_entries:
        return False

    os.environ["PATH"] = f"{local_bin}{os.pathsep}{os.environ.get('PATH', '')}"
    if show_hint:
        console.print("  [yellow]![/yellow] Added ~/.local/bin to PATH for this setup run.")
        console.print(f"  [yellow]Persist:[/yellow] {_path_persist_hint()}")
    return True


def _detect_linux_package_manager() -> str | None:
    for manager in ("apt-get", "dnf", "yum", "pacman", "apk", "zypper"):
        if shutil.which(manager):
            return manager
    return None


def _with_sudo_if_needed(command: list[str]) -> list[str]:
    if os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() != 0 and shutil.which("sudo"):
        return ["sudo", *command]
    return command


def _render_command(command: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


def _run_install_command(command: list[str], description: str) -> bool:
    console.print(f"  [cyan]→[/cyan] {description}")
    console.print(f"    [dim]$ {_render_command(command)}[/dim]")
    try:
        result = subprocess.run(command, check=False)  # noqa: S603,S607  # nosec B603 B607
    except FileNotFoundError:
        console.print("    [red]✗[/red] Installer command not found in PATH.")
        return False
    if result.returncode != 0:
        console.print(f"    [red]✗[/red] Installer exited with status {result.returncode}.")
        return False
    return True


def _manual_install_hint(tool: str) -> str:
    os_name = system().lower()
    if tool in {"uv", "ruff"}:
        return f"curl -LsSf https://astral.sh/{tool}/install.sh | sh"

    if tool != "jaq":
        return "bash scripts/setup.sh"

    if os_name == "darwin":
        return "brew install jaq"

    if os_name != "linux":
        return "bash scripts/setup.sh"

    manager = _detect_linux_package_manager()
    command = JAQ_LINUX_COMMANDS.get(manager)
    if command is None:
        return "bash scripts/setup.sh"
    return f"sudo {_render_command(command)}"


def _install_uv() -> bool:
    command = ["sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"]
    if not _run_install_command(command, "Installing uv via official installer"):
        return False
    _ensure_local_bin_on_path(show_hint=True)
    return shutil.which("uv") is not None


def _install_ruff() -> bool:
    command = ["sh", "-c", "curl -LsSf https://astral.sh/ruff/install.sh | sh"]
    if not _run_install_command(command, "Installing ruff via official installer"):
        return False
    _ensure_local_bin_on_path(show_hint=True)
    return shutil.which("ruff") is not None


def _install_jaq() -> bool:  # noqa: PLR0911
    os_name = system().lower()
    if os_name == "darwin":
        if not shutil.which("brew"):
            console.print("  [red]✗[/red] Homebrew not found; cannot auto-install jaq on macOS.")
            return False
        if not _run_install_command(["brew", "install", "jaq"], "Installing jaq with Homebrew"):
            return False
        return shutil.which("jaq") is not None

    if os_name != "linux":
        console.print(f"  [red]✗[/red] Unsupported OS for automatic jaq install: {os_name}")
        return False

    manager = _detect_linux_package_manager()
    base_command = JAQ_LINUX_COMMANDS.get(manager)
    if base_command is None:
        console.print("  [red]✗[/red] Could not detect a supported Linux package manager for jaq.")
        return False

    command = _with_sudo_if_needed(base_command)
    if not _run_install_command(command, f"Installing jaq via {manager}"):
        return False
    return shutil.which("jaq") is not None


def _guided_install_missing_tools(missing_required: list[str]) -> list[str]:
    if not missing_required:
        return []

    installers = {
        "jaq": _install_jaq,
        "ruff": _install_ruff,
        "uv": _install_uv,
    }

    console.print("\n[bold yellow]Missing required tools detected.[/bold yellow]")
    if not Confirm.ask("Run guided installer for missing tools now?", default=True):
        return missing_required

    _ensure_local_bin_on_path()
    for tool in list(missing_required):
        if shutil.which(tool):
            continue

        if not Confirm.ask(f"Install '{tool}' now?", default=True):
            continue

        installer = installers.get(tool)
        if installer is None:
            continue

        if installer():
            console.print(f"    [green]✓[/green] {tool} installed successfully.")
            continue

        manual_hint = _manual_install_hint(tool)
        console.print(f"    [yellow]![/yellow] Could not install {tool} automatically.")
        console.print(f"    [yellow]Manual:[/yellow] {manual_hint}")

    _ensure_local_bin_on_path()
    return [tool for tool in REQUIRED_TOOLS if not shutil.which(tool)]


def check_tools():
    """Verify that required system tools are installed."""
    console.print("[bold blue]Checking System Dependencies...[/bold blue]")
    _ensure_local_bin_on_path()
    missing_required = []

    for tool, desc in REQUIRED_TOOLS.items():
        path = shutil.which(tool)
        if path:
            console.print(f"  [green]✓[/green] {tool} found at {path}")
        else:
            console.print(f"  [red]✗[/red] {tool} NOT found. {desc}")
            missing_required.append(tool)

    if missing_required:
        missing_required = _guided_install_missing_tools(missing_required)

    if missing_required:
        console.print("\n[bold red]Still missing required tools:[/bold red]")
        for tool in missing_required:
            console.print(f"  [red]- {tool}[/red] -> [yellow]{_manual_install_hint(tool)}[/yellow]")
        console.print("Install them now for full functionality, or continue with limited checks.")
        if not Confirm.ask("Continue anyway?", default=False):
            raise typer.Exit(code=1)
    else:
        console.print("  [green]✓[/green] All required tools are installed.")

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
    config: dict[str, Any] = deepcopy(DEFAULT_CONFIG)
    languages = cast("dict[str, Any]", config["languages"])

    # Python
    if Confirm.ask("Enable Python enforcement?", default=defaults.get("python", True)):
        languages["python"] = True
    else:
        languages["python"] = False

    # TypeScript
    if Confirm.ask("Enable TypeScript/JavaScript enforcement?", default=defaults.get("typescript", True)):
        # If enabling, use the default complex object
        # If currently boolean in default config, swap to object
        pass  # Keep default object
    else:
        languages["typescript"] = False  # Set to false

    # Shell
    if Confirm.ask("Enable Shell Script enforcement?", default=defaults.get("shell", True)):
        languages["shell"] = True
    else:
        languages["shell"] = False

    # Docker
    if Confirm.ask("Enable Dockerfile enforcement?", default=defaults.get("dockerfile", True)):
        languages["dockerfile"] = True
    else:
        languages["dockerfile"] = False

    # Others (group them to be less tedious)
    others = ["yaml", "json", "toml", "markdown"]
    if Confirm.ask("Enable other formats (YAML, JSON, TOML, Markdown)?", default=True):
        for lang in others:
            languages[lang] = True
    else:
        for lang in others:
            if Confirm.ask(f"Enable {lang}?", default=False):
                languages[lang] = True
            else:
                languages[lang] = False

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
        os.chmod(script, 0o755)  # noqa: S103  # nosec B103
        console.print(f"    [green]✓[/green] chmod +x {script.name}")

    # Check pre-commit
    if Path(".pre-commit-config.yaml").exists():
        if shutil.which("pre-commit"):
            console.print("  Installing pre-commit hooks...")
            try:
                subprocess.run(["pre-commit", "install"], check=True)  # noqa: S607  # nosec B603 B607
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
        f.write("\n")
    console.print("  [green]✓[/green] Configuration saved.")

    setup_hooks()

    console.print("\n[bold green]Setup Complete![/bold green]")
    console.print("Run a Claude Code session to start using Plankton.")
    console.print("To test hooks manually: [cyan].claude/hooks/test_hook.sh --self-test[/cyan]")


if __name__ == "__main__":
    app()
