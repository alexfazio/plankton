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

    assert setup_module._has_any("*.py") is False


def test_has_any_finds_recursive_non_excluded_file(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()

    (tmp_path / "src" / "nested").mkdir(parents=True)
    (tmp_path / "src" / "nested" / "main.py").write_text("print('ok')\n", encoding="utf-8")

    monkeypatch.chdir(tmp_path)

    assert setup_module._has_any("*.py") is True


def test_language_defaults_from_effective_prefers_existing_config() -> None:
    setup_module = _load_setup_module()
    effective = setup_module.build_effective_config(
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
    )

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

    merged = setup_module.language_defaults_from_effective(detected, effective)

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
    assert merged["languages"]["typescript"]["enabled"] is False
    assert merged["languages"]["python"] is True
    # Existing nested key survives
    assert merged["languages"]["typescript"]["knip"] is True
    assert merged["languages"]["typescript"]["biome_nursery"] == "error"


def test_default_config_no_deprecated_subprocess_keys() -> None:
    """T8: DEFAULT_CONFIG has no deprecated subprocess keys."""
    setup_module = _load_setup_module()

    subprocess_config = setup_module.DEFAULT_CONFIG.get("subprocess", {})
    assert "timeout" not in subprocess_config, "DEFAULT_CONFIG has deprecated subprocess.timeout"
    assert "model_selection" not in subprocess_config, "DEFAULT_CONFIG has deprecated subprocess.model_selection"


def test_default_config_uses_correct_exclusion_key() -> None:
    """T9: DEFAULT_CONFIG uses security_linter_exclusions, not exclusions."""
    setup_module = _load_setup_module()

    assert "exclusions" not in setup_module.DEFAULT_CONFIG, (
        "DEFAULT_CONFIG uses 'exclusions' instead of 'security_linter_exclusions'"
    )
    assert "security_linter_exclusions" in setup_module.DEFAULT_CONFIG, (
        "DEFAULT_CONFIG missing 'security_linter_exclusions' key"
    )


def test_manual_install_hint_uv() -> None:
    setup_module = _load_setup_module()
    assert setup_module._manual_install_hint("uv") == "curl -LsSf https://astral.sh/uv/install.sh | sh"


def test_manual_install_hint_linux_jaq_apt(monkeypatch) -> None:
    setup_module = _load_setup_module()

    monkeypatch.setattr(setup_module, "system", lambda: "Linux")
    monkeypatch.setattr(setup_module, "_detect_linux_package_manager", lambda: "apt-get")

    assert setup_module._manual_install_hint("jaq") == "bash scripts/setup.sh"


def test_fallback_typer_calls_registered_command() -> None:
    setup_module = _load_setup_module()
    app = setup_module._FallbackTyper()
    called = {"value": False}

    @app.command()
    def fake_main() -> None:
        called["value"] = True

    app()
    assert called["value"] is True


def test_fallback_typer_call_without_command_raises() -> None:
    setup_module = _load_setup_module()
    app = setup_module._FallbackTyper()
    with pytest.raises(setup_module._FallbackTyperError):
        app()


def test_strip_rich_markup_preserves_literal_brackets() -> None:
    setup_module = _load_setup_module()
    value = "[bold]Ready[/bold] [Y/n] keep [literal]"
    assert setup_module._strip_rich_markup(value) == "Ready [Y/n] keep [literal]"


def test_render_rich_markup_emits_ansi_sequences() -> None:
    setup_module = _load_setup_module()
    rendered = setup_module._render_rich_markup("[bold green]ok[/bold green]")
    assert "\x1b[" in rendered
    assert "ok" in rendered


def test_fallback_panel_fit_draws_box() -> None:
    setup_module = _load_setup_module()
    panel = setup_module._FallbackPanel.fit("Plankton Setup Wizard")
    assert "Plankton Setup Wizard" in panel
    assert "╭" in panel
    assert "╰" in panel


def test_ensure_local_bin_on_path_uses_path_tokens(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()
    local_bin = tmp_path / ".local" / "bin"
    local_bin.mkdir(parents=True)
    monkeypatch.setattr(setup_module, "LOCAL_BIN_DIR", local_bin)
    monkeypatch.setenv("PATH", f"{tmp_path}/.local/binutils{os.pathsep}/usr/bin")

    changed = setup_module._ensure_local_bin_on_path()
    assert changed is True
    assert os.environ["PATH"].split(os.pathsep)[0] == str(local_bin)


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
    assert expected in hint


def test_with_sudo_if_needed_adds_sudo(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module.os, "geteuid", lambda: 1000)
    monkeypatch.setattr(
        setup_module.shutil,
        "which",
        lambda tool: "/usr/bin/sudo" if tool == "sudo" else f"/usr/bin/{tool}",
    )
    assert setup_module._with_sudo_if_needed(["apt-get", "install", "jaq"])[0] == "sudo"


def test_with_sudo_if_needed_keeps_command_for_root(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module.os, "geteuid", lambda: 0)
    command = ["apt-get", "install", "jaq"]
    assert setup_module._with_sudo_if_needed(command) == command


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
    assert remaining == ["ruff"]


def test_fetch_latest_release_asset_url_ignores_checksum_assets(monkeypatch) -> None:
    setup_module = _load_setup_module()

    class _FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> bool:
            return False

        def read(self) -> bytes:
            payload = {
                "assets": [
                    {
                        "browser_download_url": (
                            "https://github.com/01mf02/jaq/releases/download/v2.1.1/"
                            "jaq-x86_64-unknown-linux-musl.sha256"
                        )
                    },
                    {
                        "browser_download_url": (
                            "https://github.com/01mf02/jaq/releases/download/v2.1.1/jaq-x86_64-unknown-linux-musl"
                        )
                    },
                ]
            }
            return json.dumps(payload).encode("utf-8")

    monkeypatch.setattr(setup_module.urllib.request, "urlopen", lambda *args, **kwargs: _FakeResponse())
    url = setup_module._fetch_latest_release_asset_url("01mf02/jaq", "jaq-x86_64-unknown-linux-musl")
    assert url is not None
    assert url.endswith("jaq-x86_64-unknown-linux-musl")


def test_manual_hint_uses_shared_jaq_linux_commands(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module, "system", lambda: "Linux")
    monkeypatch.setattr(setup_module, "_detect_linux_package_manager", lambda: "dnf")
    monkeypatch.setitem(
        setup_module.JAQ_LINUX_COMMANDS,
        "dnf",
        ["dnf", "install", "-y", "jaq", "--from-shared-map"],
    )
    assert "--from-shared-map" in setup_module._manual_install_hint("jaq")


def test_install_jaq_falls_back_to_release(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr(setup_module, "system", lambda: "Linux")
    monkeypatch.setattr(setup_module, "_detect_linux_package_manager", lambda: "apt-get")
    monkeypatch.setattr(setup_module, "_with_sudo_if_needed", lambda command: command)
    monkeypatch.setattr(setup_module, "_run_install_command", lambda *args, **kwargs: False)
    monkeypatch.setattr(setup_module, "_install_jaq_from_release", lambda: True)
    assert setup_module._install_jaq() is True


def test_configure_languages_prompts_each_other_format(monkeypatch) -> None:
    setup_module = _load_setup_module()
    prompts: list[str] = []

    def fake_ask(prompt: str, default: bool = True) -> bool:
        prompts.append(prompt)
        return default

    monkeypatch.setattr(setup_module.Confirm, "ask", fake_ask)
    config = setup_module.configure_languages(
        {
            "python": True,
            "typescript": True,
            "shell": True,
            "dockerfile": True,
            "yaml": True,
            "json": False,
            "toml": True,
            "markdown": False,
        }
    )

    assert "Enable YAML enforcement?" in prompts
    assert "Enable JSON enforcement?" in prompts
    assert "Enable TOML enforcement?" in prompts
    assert "Enable Markdown enforcement?" in prompts
    assert config["languages"]["yaml"] is True
    assert config["languages"]["json"] is False
    assert config["languages"]["toml"] is True
    assert config["languages"]["markdown"] is False


def test_build_effective_config_uses_existing_and_legacy_exclusions() -> None:
    setup_module = _load_setup_module()
    effective = setup_module.build_effective_config(
        {
            "languages": {"python": False},
            "phases": {"auto_format": False},
            "exclusions": ["tests/"],
        }
    )
    assert effective["languages"]["python"] is False
    assert effective["phases"]["auto_format"] is False
    assert effective["security_linter_exclusions"] == ["tests/"]


def test_select_sections_defaults_on_rerun(monkeypatch) -> None:
    setup_module = _load_setup_module()
    defaults_seen: dict[str, bool] = {}

    def fake_ask(prompt: str, default: bool = True) -> bool:
        defaults_seen[prompt] = default
        return default

    monkeypatch.setattr(setup_module.Confirm, "ask", fake_ask)
    selected = setup_module.select_sections(has_existing_config=True)
    assert selected["languages"] is True
    assert selected["phases"] is True
    assert selected["security_exclusions"] is False
    assert selected["package_managers"] is False
    assert selected["jscpd"] is False
    assert selected["subprocess"] is False


def test_main_no_sections_selected_does_not_rewrite_existing_config(tmp_path: Path, monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.chdir(tmp_path)

    config_path = tmp_path / ".claude" / "hooks" / "config.json"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text('{"languages":{"python":false}}\n', encoding="utf-8")
    original = config_path.read_text(encoding="utf-8")

    monkeypatch.setattr(setup_module, "CONFIG_PATH", config_path)
    monkeypatch.setattr(setup_module, "check_tools", lambda: None)
    monkeypatch.setattr(setup_module, "setup_hooks", lambda: None)
    monkeypatch.setattr(
        setup_module,
        "load_existing_config",
        lambda: {"languages": {"python": False}},
    )
    monkeypatch.setattr(
        setup_module,
        "detect_languages",
        lambda: {
            "python": True,
            "typescript": False,
            "shell": False,
            "dockerfile": False,
            "yaml": False,
            "json": False,
            "toml": False,
            "markdown": False,
        },
    )
    monkeypatch.setattr(
        setup_module,
        "select_sections",
        lambda has_existing_config: {
            "languages": False,
            "phases": False,
            "security_exclusions": False,
            "package_managers": False,
            "jscpd": False,
            "subprocess": False,
        },
    )

    setup_module.main()
    assert config_path.read_text(encoding="utf-8") == original


def test_edit_list_items_add_and_remove(monkeypatch) -> None:
    setup_module = _load_setup_module()
    answers = {
        "Add an item?": [True, False],
        "Remove an item?": [False, True],
        "Edit this list again?": [True, False],
    }
    inputs = iter(["c", "2"])

    def fake_confirm(prompt: str, default: bool = False) -> bool:
        queue = answers.get(prompt)
        if queue is None or not queue:
            raise AssertionError(f"Unexpected prompt or too many calls: {prompt!r}")
        return queue.pop(0)

    monkeypatch.setattr(setup_module.Confirm, "ask", fake_confirm)
    monkeypatch.setattr(setup_module, "_ask_text", lambda *args, **kwargs: next(inputs))

    result = setup_module.edit_list_items("Test List", ["a", "b"])
    assert result == ["a", "c"]


def test_ask_text_returns_default_on_eof(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr("builtins.input", lambda _prompt: (_ for _ in ()).throw(EOFError))
    assert setup_module._ask_text("Prompt", "fallback") == "fallback"


def test_ask_int_returns_default_on_eof(monkeypatch) -> None:
    setup_module = _load_setup_module()
    monkeypatch.setattr("builtins.input", lambda _prompt: (_ for _ in ()).throw(EOFError))
    assert setup_module._ask_int("Prompt", 7, min_value=0) == 7


def test_configure_package_managers_uses_current_values(monkeypatch) -> None:
    setup_module = _load_setup_module()
    effective = {
        "package_managers": {
            "python": "pip",
            "javascript": "npm",
            "allowed_subcommands": {
                "npm": ["audit"],
                "pip": ["download"],
                "yarn": [],
                "pnpm": [],
                "poetry": [],
                "pipenv": [],
            },
        }
    }

    monkeypatch.setattr(setup_module, "_ask_text", lambda prompt, default: default)
    monkeypatch.setattr(setup_module, "edit_list_items", lambda title, current_items: current_items)

    package_managers = setup_module.configure_package_managers(effective)
    assert package_managers["package_managers"]["python"] == "pip"
    assert package_managers["package_managers"]["javascript"] == "npm"
    assert package_managers["package_managers"]["allowed_subcommands"]["npm"] == ["audit"]


def test_configure_selected_sections_only_updates_selected(monkeypatch) -> None:
    setup_module = _load_setup_module()
    effective = setup_module.build_effective_config({})
    language_defaults = {
        "python": True,
        "typescript": True,
        "shell": True,
        "dockerfile": True,
        "yaml": True,
        "json": True,
        "toml": True,
        "markdown": True,
    }
    selected = {
        "languages": False,
        "phases": True,
        "security_exclusions": False,
        "package_managers": False,
        "jscpd": False,
        "subprocess": False,
    }

    monkeypatch.setattr(setup_module.Confirm, "ask", lambda *args, **kwargs: kwargs.get("default", True))
    generated = setup_module.configure_selected_sections(effective, language_defaults, selected)
    assert "phases" in generated
    assert "languages" not in generated
    assert "package_managers" not in generated
