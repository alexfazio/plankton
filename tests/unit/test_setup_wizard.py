"""Unit tests for setup wizard helper functions."""

import importlib.util
import json
import os
import sys
import types
from pathlib import Path
from typing import Any

import pytest


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

        setattr(typer_module, "Exit", Exit)
        setattr(typer_module, "Typer", DummyTyper)
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

        setattr(rich_console_module, "Console", Console)
        setattr(rich_panel_module, "Panel", Panel)
        setattr(rich_prompt_module, "Confirm", Confirm)

        sys.modules["rich"] = rich_module
        sys.modules["rich.console"] = rich_console_module
        sys.modules["rich.panel"] = rich_panel_module
        sys.modules["rich.prompt"] = rich_prompt_module


def _load_setup_module() -> Any:
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

    assert setup_module._has_any("*.py") is False  # nosec B101


def test_has_any_finds_recursive_non_excluded_file(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()

    (tmp_path / "src" / "nested").mkdir(parents=True)
    (tmp_path / "src" / "nested" / "main.py").write_text("print('ok')\n", encoding="utf-8")

    monkeypatch.chdir(tmp_path)

    assert setup_module._has_any("*.py") is True  # nosec B101


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

    assert merged["python"] is False  # nosec B101
    assert merged["typescript"] is False  # nosec B101
    assert merged["shell"] is True  # nosec B101
    assert merged["dockerfile"] is False  # nosec B101
    assert merged["yaml"] is True  # nosec B101
    assert merged["json"] is False  # nosec B101
    assert merged["toml"] is True  # nosec B101
    assert merged["markdown"] is False  # nosec B101


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

    assert merged["$schema"] == existing["$schema"]  # nosec B101
    assert merged["_comment"] == existing["_comment"]  # nosec B101
    assert merged["custom"] == existing["custom"]  # nosec B101
    assert merged["languages"] == generated["languages"]  # nosec B101
    assert merged["phases"] == generated["phases"]  # nosec B101


def test_deep_merge_preserves_nested_keys() -> None:
    """T7: Deep merge preserves nested keys not in generated config."""
    setup_module = _load_setup_module()

    existing = {
        "languages": {
            "typescript": {
                "enabled": True,
                "knip": True,
                "biome_nursery": "error",
            },
        },
    }
    generated = {
        "languages": {
            "typescript": {
                "enabled": False,
            },
            "python": True,
        },
    }

    merged = setup_module.merge_config(existing, generated)

    # Generated key overwrites
    assert merged["languages"]["typescript"]["enabled"] is False  # nosec B101
    assert merged["languages"]["python"] is True  # nosec B101
    # Existing nested key survives
    assert merged["languages"]["typescript"]["knip"] is True  # nosec B101
    assert merged["languages"]["typescript"]["biome_nursery"] == "error"  # nosec B101


def test_default_config_no_deprecated_subprocess_keys() -> None:
    """T8: DEFAULT_CONFIG has no deprecated subprocess keys."""
    setup_module = _load_setup_module()

    subprocess_config = setup_module.DEFAULT_CONFIG.get("subprocess", {})
    assert "timeout" not in subprocess_config, "DEFAULT_CONFIG has deprecated subprocess.timeout"  # nosec B101
    assert "model_selection" not in subprocess_config, "DEFAULT_CONFIG has deprecated subprocess.model_selection"  # nosec B101


def test_default_config_uses_correct_exclusion_key() -> None:
    """T9: DEFAULT_CONFIG uses security_linter_exclusions, not exclusions."""
    setup_module = _load_setup_module()

    assert "exclusions" not in setup_module.DEFAULT_CONFIG, (  # nosec B101
        "DEFAULT_CONFIG uses 'exclusions' instead of 'security_linter_exclusions'"
    )
    assert "security_linter_exclusions" in setup_module.DEFAULT_CONFIG, (  # nosec B101
        "DEFAULT_CONFIG missing 'security_linter_exclusions' key"
    )


def test_manual_install_hint_uv() -> None:
    setup_module = _load_setup_module()
    assert setup_module._manual_install_hint("uv") == "curl -LsSf https://astral.sh/uv/install.sh | sh"  # nosec B101


def test_manual_install_hint_linux_jaq_apt(monkeypatch) -> None:
    setup_module = _load_setup_module()

    monkeypatch.setattr(setup_module, "system", lambda: "Linux")
    monkeypatch.setattr(setup_module, "_detect_linux_package_manager", lambda: "apt-get")

    assert setup_module._manual_install_hint("jaq") == "sudo apt-get install -y jaq"  # nosec B101


def test_fallback_typer_calls_registered_command() -> None:
    setup_module = _load_setup_module()
    app = setup_module._FallbackTyper()
    called = {"value": False}

    @app.command()
    def fake_main() -> None:
        called["value"] = True

    app()
    assert called["value"] is True  # nosec B101


def test_fallback_typer_call_without_command_raises() -> None:
    setup_module = _load_setup_module()
    app = setup_module._FallbackTyper()
    with pytest.raises(RuntimeError):
        app()


def test_strip_rich_markup_preserves_literal_brackets() -> None:
    setup_module = _load_setup_module()
    value = "[bold]Ready[/bold] [Y/n] keep [literal]"
    assert setup_module._strip_rich_markup(value) == "Ready [Y/n] keep [literal]"  # nosec B101


def test_ensure_local_bin_on_path_uses_path_tokens(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()
    local_bin = tmp_path / ".local" / "bin"
    local_bin.mkdir(parents=True)
    monkeypatch.setattr(setup_module, "LOCAL_BIN_DIR", local_bin)
    monkeypatch.setenv("PATH", f"{tmp_path}/.local/binutils{os.pathsep}/usr/bin")

    changed = setup_module._ensure_local_bin_on_path()
    assert changed is True  # nosec B101
    assert os.environ["PATH"].split(os.pathsep)[0] == str(local_bin)  # nosec B101


@pytest.mark.parametrize(
    ("shell", "expected"),
    [
        ("/bin/bash", "~/.bashrc"),
        ("/bin/zsh", "~/.zshrc"),
        ("/usr/bin/fish", "fish_add_path"),
        ("", "shell profile"),
    ],
)
def test_path_persist_hint_by_shell(monkeypatch, shell: str, expected: str) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setenv("SHELL", shell)
    hint = setup_module._path_persist_hint()
    assert expected in hint  # nosec B101


def test_with_sudo_if_needed_adds_sudo(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module.os, "geteuid", lambda: 1000)
    monkeypatch.setattr(
        setup_module.shutil,
        "which",
        lambda tool: "/usr/bin/sudo" if tool == "sudo" else f"/usr/bin/{tool}",
    )
    assert setup_module._with_sudo_if_needed(["apt-get", "install", "jaq"])[0] == "sudo"  # nosec B101


def test_with_sudo_if_needed_keeps_command_for_root(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module.os, "geteuid", lambda: 0)
    command = ["apt-get", "install", "jaq"]
    assert setup_module._with_sudo_if_needed(command) == command  # nosec B101


def test_guided_install_returns_remaining_missing(monkeypatch, tmp_path: Path) -> None:
    setup_module = _load_setup_module()

    local_bin = tmp_path / ".local" / "bin"
    local_bin.mkdir(parents=True)
    monkeypatch.setattr(setup_module, "LOCAL_BIN_DIR", local_bin)

    installed = {"jaq"}

    def fake_which(tool: str) -> str | None:
        if tool in installed:
            return f"/usr/bin/{tool}"
        if tool == "sudo":
            return "/usr/bin/sudo"
        return None

    answers = iter([True, True, True])  # run installer, install uv, install ruff
    monkeypatch.setattr(setup_module.Confirm, "ask", lambda *args, **kwargs: next(answers))
    monkeypatch.setattr(setup_module.shutil, "which", fake_which)
    monkeypatch.setattr(setup_module, "_install_uv", lambda: installed.add("uv") or True)
    monkeypatch.setattr(setup_module, "_install_ruff", lambda: False)
    monkeypatch.setattr(setup_module, "_manual_install_hint", lambda tool: f"manual:{tool}")

    remaining = setup_module._guided_install_missing_tools(["uv", "ruff"])
    assert remaining == ["ruff"]  # nosec B101


def test_manual_hint_uses_shared_jaq_linux_commands(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module, "system", lambda: "Linux")
    monkeypatch.setattr(setup_module, "_detect_linux_package_manager", lambda: "apt-get")
    monkeypatch.setitem(
        setup_module.JAQ_LINUX_COMMANDS,
        "apt-get",
        ["apt-get", "install", "-y", "jaq", "--from-shared-map"],
    )
    assert "--from-shared-map" in setup_module._manual_install_hint("jaq")  # nosec B101
