"""Unit tests for setup wizard helper functions."""

import importlib.util
import json
import sys
import types
from pathlib import Path


def _install_dependency_stubs() -> None:
    if "typer" not in sys.modules:
        typer_module = types.ModuleType("typer")

        class Exit(Exception):
            def __init__(self, code: int = 0) -> None:
                super().__init__(code)
                self.code = code

        class DummyTyper:
            def command(self):
                def decorator(func):
                    return func

                return decorator

        typer_module.Exit = Exit
        typer_module.Typer = DummyTyper
        sys.modules["typer"] = typer_module

    if "rich" not in sys.modules:
        rich_module = types.ModuleType("rich")
        rich_console_module = types.ModuleType("rich.console")
        rich_panel_module = types.ModuleType("rich.panel")
        rich_prompt_module = types.ModuleType("rich.prompt")

        class Console:
            def print(self, *args, **kwargs) -> None:
                return None

        class Panel:
            @staticmethod
            def fit(*args, **kwargs) -> str:
                return ""

        class Confirm:
            @staticmethod
            def ask(*args, **kwargs) -> bool:
                return kwargs.get("default", True)

        rich_console_module.Console = Console
        rich_panel_module.Panel = Panel
        rich_prompt_module.Confirm = Confirm

        sys.modules["rich"] = rich_module
        sys.modules["rich.console"] = rich_console_module
        sys.modules["rich.panel"] = rich_panel_module
        sys.modules["rich.prompt"] = rich_prompt_module


def _load_setup_module() -> object:
    _install_dependency_stubs()
    module_name = "plankton_setup_module"
    module_path = Path(__file__).resolve().parents[2] / "scripts" / "setup.py"
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Failed to load setup.py module spec")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def test_has_any_ignores_excluded_directories(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()

    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "ignored.py").write_text("print('x')\n", encoding="utf-8")

    monkeypatch.chdir(tmp_path)

    assert setup_module._has_any("*.py") is False


def test_has_any_finds_recursive_non_excluded_file(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()

    (tmp_path / "src" / "nested").mkdir(parents=True)
    (tmp_path / "src" / "nested" / "main.py").write_text("print('ok')\n", encoding="utf-8")

    monkeypatch.chdir(tmp_path)

    assert setup_module._has_any("*.py") is True


def test_load_language_defaults_prefers_existing_config(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()

    config_dir = tmp_path / ".claude" / "hooks"
    config_dir.mkdir(parents=True)
    config_path = config_dir / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "languages": {
                    "python": False,
                    "shell": True,
                    "dockerfile": False,
                    "yaml": True,
                    "json": False,
                    "toml": True,
                    "markdown": False,
                    "typescript": {"enabled": False},
                }
            }
        ),
        encoding="utf-8",
    )

    monkeypatch.chdir(tmp_path)

    detected = {
        "python": True,
        "typescript": True,
        "shell": False,
        "dockerfile": True,
        "yaml": False,
        "json": True,
        "toml": False,
        "markdown": True,
    }

    merged = setup_module.load_language_defaults(detected)

    assert merged["python"] is False
    assert merged["typescript"] is False
    assert merged["shell"] is True
    assert merged["dockerfile"] is False
    assert merged["yaml"] is True
    assert merged["json"] is False
    assert merged["toml"] is True
    assert merged["markdown"] is False


def test_merge_config_preserves_metadata_keys() -> None:
    setup_module = _load_setup_module()

    existing = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "_comment": "Claude Code Hooks Configuration - edit this file to customize hook behavior",
        "custom": {"keep": True},
        "languages": {"python": False},
    }
    generated = {
        "languages": {"python": True, "shell": True},
        "phases": {"auto_format": True, "subprocess_delegation": True},
    }

    merged = setup_module.merge_config(existing, generated)

    assert merged["$schema"] == existing["$schema"]
    assert merged["_comment"] == existing["_comment"]
    assert merged["custom"] == existing["custom"]
    assert merged["languages"] == generated["languages"]
    assert merged["phases"] == generated["phases"]
