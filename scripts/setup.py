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
import sys
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy
from pathlib import Path
from platform import machine, system
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

_ANSI_STYLE_CODES = {
    "bold": "1",
    "dim": "2",
    "italic": "3",
    "underline": "4",
    "blink": "5",
    "reverse": "7",
    "strike": "9",
    "black": "30",
    "red": "31",
    "green": "32",
    "yellow": "33",
    "blue": "34",
    "magenta": "35",
    "cyan": "36",
    "white": "37",
}
_RICH_STYLE_TOKENS = set(_ANSI_STYLE_CODES.keys())
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


def _supports_ansi_output() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("TERM", "") in {"", "dumb"}:
        return False
    return bool(getattr(sys.stdout, "isatty", lambda: False)())


def _rich_tag_to_ansi(tag: str) -> str | None:
    cleaned = tag.strip()
    if not cleaned:
        return None
    if cleaned.startswith("/"):
        return "\033[0m"
    tokens = cleaned.split()
    codes: list[str] = []
    for token in tokens:
        code = _ANSI_STYLE_CODES.get(token)
        if code is None:
            return None
        codes.append(code)
    return f"\033[{';'.join(codes)}m"


def _render_rich_markup(value: str) -> str:
    """Render rich-style tags to ANSI escape sequences for fallback output."""
    saw_ansi = False

    def _replace_tag(match: re.Match[str]) -> str:
        nonlocal saw_ansi
        inner = match.group(1).strip()
        ansi = _rich_tag_to_ansi(inner)
        if ansi is None:
            return match.group(0)
        saw_ansi = True
        return ansi

    rendered = _RICH_TAG_PATTERN.sub(_replace_tag, value)
    if saw_ansi and not rendered.endswith("\033[0m"):
        rendered += "\033[0m"
    return rendered


class _FallbackConsole:
    @staticmethod
    def print(*args, **_kwargs) -> None:  # noqa: D102
        text = " ".join(str(arg) for arg in args)
        if _supports_ansi_output():
            print(_render_rich_markup(text))
        else:
            print(_strip_rich_markup(text))


class _FallbackPanel:
    @staticmethod
    def fit(text: str, style: str = "") -> str:  # noqa: D102
        lines = [_strip_rich_markup(line) for line in str(text).splitlines() or [""]]
        width = max(len(line) for line in lines)
        top = f"╭{'─' * (width + 2)}╮"
        bottom = f"╰{'─' * (width + 2)}╯"
        body = [f"│ {line.ljust(width)} │" for line in lines]
        panel = "\n".join([top, *body, bottom])

        if _supports_ansi_output():
            ansi = _rich_tag_to_ansi(style)
            if ansi:
                return f"{ansi}{panel}\033[0m"
        return panel


class _FallbackConfirm:
    @staticmethod
    def ask(prompt: str, default: bool = True) -> bool:  # noqa: D102
        suffix = " [Y/n]: " if default else " [y/N]: "
        prompt_text = _render_rich_markup(prompt) if _supports_ansi_output() else _strip_rich_markup(prompt)
        answer = input(f"{prompt_text}{suffix}").strip().lower()
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


def build_effective_config(existing_config: dict[str, Any]) -> dict[str, Any]:
    """Build a fully-populated config by overlaying existing values on defaults."""
    effective = merge_config(DEFAULT_CONFIG, existing_config)
    if "security_linter_exclusions" not in existing_config:
        legacy_exclusions = existing_config.get("exclusions")
        if isinstance(legacy_exclusions, list):
            effective["security_linter_exclusions"] = [
                str(item).strip() for item in legacy_exclusions if str(item).strip()
            ]
    return effective


def _ask_text(prompt: str, default: str) -> str:
    suffix = f" [{default}]" if default else ""
    try:
        answer = input(f"{prompt}{suffix}: ").strip()
    except EOFError:
        console.print("  [yellow]![/yellow] Input closed; using default value.")
        return default
    return answer or default


def _ask_int(prompt: str, default: int, min_value: int = 0) -> int:
    while True:
        answer = _ask_text(prompt, str(default))
        try:
            value = int(answer)
        except ValueError:
            console.print("  [red]✗[/red] Please enter a valid integer.")
            continue
        if value < min_value:
            console.print(f"  [red]✗[/red] Value must be >= {min_value}.")
            continue
        return value


def _normalize_string_list(items: list[str]) -> list[str]:
    normalized: list[str] = []
    for item in items:
        cleaned = str(item).strip()
        if cleaned and cleaned not in normalized:
            normalized.append(cleaned)
    return normalized


def edit_list_items(title: str, current_items: list[str]) -> list[str]:
    """Interactively add/remove list entries and return normalized results."""
    items = _normalize_string_list(current_items)
    while True:
        console.print(f"\n[bold]{title}[/bold]")
        if items:
            for index, item in enumerate(items, start=1):
                console.print(f"  {index}. {item}")
        else:
            console.print("  (empty)")

        if Confirm.ask("Add an item?", default=False):
            new_item = _ask_text("  Enter value", "")
            items = _normalize_string_list([*items, new_item])

        if items and Confirm.ask("Remove an item?", default=False):
            raw_index = _ask_text("  Number to remove", "")
            try:
                remove_index = int(raw_index)
            except ValueError:
                console.print("  [red]✗[/red] Invalid number; nothing removed.")
            else:
                if 1 <= remove_index <= len(items):
                    del items[remove_index - 1]
                else:
                    console.print("  [red]✗[/red] Number out of range; nothing removed.")

        if not Confirm.ask("Edit this list again?", default=False):
            break

    return items


def select_sections(has_existing_config: bool) -> dict[str, bool]:
    """Prompt which config sections should be edited on this run."""
    defaults = {
        "languages": True,
        "phases": True,
        "security_exclusions": not has_existing_config,
        "package_managers": not has_existing_config,
        "jscpd": not has_existing_config,
        "subprocess": not has_existing_config,
    }

    prompts = [
        ("languages", "Edit language enforcement settings?"),
        ("phases", "Edit phases (auto_format, subprocess_delegation)?"),
        ("security_exclusions", "Edit security linter exclusions?"),
        ("package_managers", "Edit package manager settings?"),
        ("jscpd", "Edit JSCPD settings?"),
        ("subprocess", "Edit subprocess settings?"),
    ]

    selected: dict[str, bool] = {}
    for key, prompt in prompts:
        selected[key] = bool(Confirm.ask(prompt, default=defaults[key]))
    return selected


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


def _linux_jaq_asset_suffix() -> str | None:
    normalized_arch = machine().lower()
    if normalized_arch in {"x86_64", "amd64"}:
        return "x86_64-unknown-linux-musl"
    if normalized_arch in {"aarch64", "arm64"}:
        return "aarch64-unknown-linux-gnu"
    return None


def _fetch_latest_release_asset_url(repo: str, pattern: str) -> str | None:
    api_url = f"https://api.github.com/repos/{repo}/releases/latest"
    try:
        with urllib.request.urlopen(api_url, timeout=20) as response:  # noqa: S310  # nosec B310
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, json.JSONDecodeError, urllib.error.URLError):
        return None

    for asset in payload.get("assets", []):
        if not isinstance(asset, dict):
            continue
        download_url = asset.get("browser_download_url")
        if not isinstance(download_url, str):
            continue
        parsed = urllib.parse.urlparse(download_url)
        filename = Path(parsed.path).name
        if filename == pattern:
            return download_url
    return None


def _install_jaq_from_release() -> bool:
    suffix = _linux_jaq_asset_suffix()
    if suffix is None:
        console.print(f"  [red]✗[/red] Unsupported Linux architecture for jaq: {machine()}")
        return False

    download_url = _fetch_latest_release_asset_url("01mf02/jaq", f"jaq-{suffix}")
    if download_url is None:
        console.print("  [red]✗[/red] Could not locate jaq binary in latest GitHub release.")
        return False

    LOCAL_BIN_DIR.mkdir(parents=True, exist_ok=True)
    temp_path = LOCAL_BIN_DIR / "jaq.tmp"
    target_path = LOCAL_BIN_DIR / "jaq"

    try:
        with (
            urllib.request.urlopen(download_url, timeout=30) as response,  # noqa: S310  # nosec B310
            open(temp_path, "wb") as file_handle,
        ):
            shutil.copyfileobj(response, file_handle)
        os.chmod(temp_path, 0o755)  # noqa: S103  # nosec B103
        temp_path.replace(target_path)
    except OSError:
        temp_path.unlink(missing_ok=True)
        return False

    _ensure_local_bin_on_path(show_hint=True)
    return shutil.which("jaq") is not None


def _manual_install_hint(tool: str) -> str:  # noqa: PLR0911
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
    if manager == "apt-get":
        return "bash scripts/setup.sh"

    command = JAQ_LINUX_COMMANDS.get(manager)
    if command is None:
        return "bash scripts/setup.sh"
    return f"sudo {_render_command(command)} (or: bash scripts/setup.sh)"


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
    if base_command is not None:
        command = _with_sudo_if_needed(base_command)
        if _run_install_command(command, f"Installing jaq via {manager}") and shutil.which("jaq") is not None:
            return True
        console.print("  [yellow]![/yellow] Package-manager install failed; trying GitHub release binary.")
    else:
        console.print("  [yellow]![/yellow] No supported Linux package manager detected; trying GitHub release binary.")

    if _install_jaq_from_release():
        return True

    console.print("  [red]✗[/red] Could not auto-install jaq.")
    return False


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


def detect_languages() -> dict[str, bool]:  # noqa: PLR0912
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

    # YAML
    if _has_any("*.yml") or _has_any("*.yaml"):
        console.print("  [green]✓[/green] YAML files detected")
        detected["yaml"] = True
    else:
        detected["yaml"] = False

    # JSON
    if _has_any("*.json"):
        console.print("  [green]✓[/green] JSON files detected")
        detected["json"] = True
    else:
        detected["json"] = False

    # TOML
    if Path("pyproject.toml").exists() or _has_any("*.toml"):
        console.print("  [green]✓[/green] TOML files detected")
        detected["toml"] = True
    else:
        detected["toml"] = False

    # Markdown
    if _has_any("*.md") or _has_any("*.mdx"):
        console.print("  [green]✓[/green] Markdown files detected")
        detected["markdown"] = True
    else:
        detected["markdown"] = False

    return detected


def language_defaults_from_effective(detected: dict[str, bool], effective_config: dict[str, Any]) -> dict[str, bool]:
    """Resolve language prompt defaults from detected files + current config."""
    defaults = dict(detected)
    languages = effective_config.get("languages", {})
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


def configure_languages(defaults: dict[str, bool]) -> dict[str, Any]:  # noqa: PLR0912
    """Interactive wizard to enable/disable languages."""
    console.print("\n[bold blue]Configuration Wizard[/bold blue]")
    languages = cast("dict[str, Any]", deepcopy(DEFAULT_CONFIG["languages"]))

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

    # Format-specific prompts (granular per language)
    format_prompts = [
        ("yaml", "Enable YAML enforcement?"),
        ("json", "Enable JSON enforcement?"),
        ("toml", "Enable TOML enforcement?"),
        ("markdown", "Enable Markdown enforcement?"),
    ]
    for language, prompt in format_prompts:
        languages[language] = bool(Confirm.ask(prompt, default=defaults.get(language, True)))

    return {"languages": languages}


def configure_phases(effective_config: dict[str, Any]) -> dict[str, Any]:
    """Prompt and return phase settings from current effective config."""
    phases = effective_config.get("phases", {})
    if not isinstance(phases, dict):
        phases = {}

    auto_format = bool(phases.get("auto_format", True))
    subprocess_delegation = bool(phases.get("subprocess_delegation", True))

    return {
        "phases": {
            "auto_format": bool(Confirm.ask("Enable auto-format phase?", default=auto_format)),
            "subprocess_delegation": bool(
                Confirm.ask("Enable subprocess delegation phase?", default=subprocess_delegation)
            ),
        }
    }


def configure_security_exclusions(effective_config: dict[str, Any]) -> dict[str, Any]:
    """Prompt and return security linter exclusions."""
    exclusions = effective_config.get("security_linter_exclusions")
    if not isinstance(exclusions, list):
        exclusions = []
    exclusion_items = [str(item) for item in exclusions]
    edited = edit_list_items("Security linter exclusions", exclusion_items)
    return {"security_linter_exclusions": edited}


def configure_package_managers(effective_config: dict[str, Any]) -> dict[str, Any]:
    """Prompt and return package manager settings."""
    package_managers = effective_config.get("package_managers", {})
    if not isinstance(package_managers, dict):
        package_managers = {}

    defaults_pm = cast("dict[str, Any]", DEFAULT_CONFIG["package_managers"])
    default_allowed = defaults_pm.get("allowed_subcommands", {})
    if not isinstance(default_allowed, dict):
        default_allowed = {}

    python_default = str(package_managers.get("python", defaults_pm["python"]))
    javascript_default = str(package_managers.get("javascript", defaults_pm["javascript"]))

    allowed_subcommands = package_managers.get("allowed_subcommands", {})
    if not isinstance(allowed_subcommands, dict):
        allowed_subcommands = {}

    updated_allowed: dict[str, list[str]] = {}
    for manager, default_commands in default_allowed.items():
        current = allowed_subcommands.get(manager, default_commands)
        if isinstance(current, list):
            current_list = [str(item) for item in current]
        elif isinstance(default_commands, list):
            current_list = [str(item) for item in default_commands]
        else:
            current_list = []
        updated_allowed[manager] = edit_list_items(f"Allowed subcommands for {manager}", current_list)

    return {
        "package_managers": {
            "python": _ask_text("Python package manager", python_default),
            "javascript": _ask_text("JavaScript package manager", javascript_default),
            "allowed_subcommands": updated_allowed,
        }
    }


def configure_jscpd(effective_config: dict[str, Any]) -> dict[str, Any]:
    """Prompt and return JSCPD settings."""
    jscpd = effective_config.get("jscpd", {})
    if not isinstance(jscpd, dict):
        jscpd = {}

    default_jscpd = cast("dict[str, Any]", DEFAULT_CONFIG["jscpd"])
    threshold_default = jscpd.get("session_threshold", default_jscpd["session_threshold"])
    try:
        threshold_default_int = int(threshold_default)
    except (TypeError, ValueError):
        threshold_default_int = int(default_jscpd["session_threshold"])

    advisory_default = bool(jscpd.get("advisory_only", default_jscpd["advisory_only"]))
    current_scan_dirs = jscpd.get("scan_dirs", default_jscpd["scan_dirs"])
    scan_dirs = [str(item) for item in current_scan_dirs] if isinstance(current_scan_dirs, list) else ["src/", "lib/"]

    return {
        "jscpd": {
            "session_threshold": _ask_int("JSCPD session threshold", threshold_default_int, min_value=1),
            "scan_dirs": edit_list_items("JSCPD scan directories", scan_dirs),
            "advisory_only": bool(Confirm.ask("Run JSCPD as advisory only?", default=advisory_default)),
        }
    }


def configure_subprocess(effective_config: dict[str, Any]) -> dict[str, Any]:
    """Prompt and return subprocess settings."""
    subprocess_cfg = effective_config.get("subprocess", {})
    if not isinstance(subprocess_cfg, dict):
        subprocess_cfg = {}

    default_subprocess = cast("dict[str, Any]", DEFAULT_CONFIG["subprocess"])
    default_settings = str(subprocess_cfg.get("settings_file", default_subprocess["settings_file"]))
    settings_file = _ask_text("Subprocess settings file", default_settings).strip()
    if not settings_file:
        settings_file = default_settings

    return {"subprocess": {"settings_file": settings_file}}


def configure_selected_sections(
    effective_config: dict[str, Any], language_defaults: dict[str, bool], selected_sections: dict[str, bool]
) -> dict[str, Any]:
    """Build generated config by prompting only selected sections."""
    generated: dict[str, Any] = {}

    if selected_sections.get("languages"):
        generated = merge_config(generated, configure_languages(language_defaults))
    if selected_sections.get("phases"):
        generated = merge_config(generated, configure_phases(effective_config))
    if selected_sections.get("security_exclusions"):
        generated = merge_config(generated, configure_security_exclusions(effective_config))
    if selected_sections.get("package_managers"):
        generated = merge_config(generated, configure_package_managers(effective_config))
    if selected_sections.get("jscpd"):
        generated = merge_config(generated, configure_jscpd(effective_config))
    if selected_sections.get("subprocess"):
        generated = merge_config(generated, configure_subprocess(effective_config))

    return generated


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

    existing_config = load_existing_config()
    effective_config = build_effective_config(existing_config)
    detected_langs = detect_languages()
    prompt_defaults = language_defaults_from_effective(detected_langs, effective_config)

    if existing_config:
        console.print(f"  [dim]Loaded existing configuration from {CONFIG_PATH}[/dim]")
    elif CONFIG_PATH.exists():
        console.print(f"  [yellow]Could not parse existing {CONFIG_PATH}, starting fresh.[/yellow]")

    section_selection = select_sections(has_existing_config=bool(existing_config))
    new_config: dict[str, Any] | None = None
    if not any(section_selection.values()):
        if existing_config:
            console.print("  [yellow]![/yellow] No sections selected; existing configuration will be kept unchanged.")
        else:
            console.print("  [red]✗[/red] No sections selected and no existing config found; aborting.")
            raise typer.Exit(code=1)
    else:
        generated_config = configure_selected_sections(effective_config, prompt_defaults, section_selection)
        new_config = merge_config(existing_config, generated_config)

    if new_config is not None:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        console.print(f"\n[bold]Writing configuration to {CONFIG_PATH}...[/bold]")
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(new_config, f, indent=2)
            f.write("\n")
        console.print("  [green]✓[/green] Configuration saved.")
    else:
        console.print("\n[bold]Configuration unchanged; skipping file write.[/bold]")

    setup_hooks()

    console.print("\n[bold green]Setup Complete![/bold green]")
    console.print("Run a Claude Code session to start using Plankton.")
    console.print("To test hooks manually: [cyan].claude/hooks/test_hook.sh --self-test[/cyan]")


if __name__ == "__main__":
    app()
