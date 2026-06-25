"""
kctx-fuzzy Python CLI — kubectl context and namespace switcher.

Uses python-prompt-toolkit for interactive fuzzy search so it works without
fzf installed.  Reads kubeconfig via PyYAML; supports KUBECONFIG env var with
colon-separated paths.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Optional

try:
    import yaml
except ImportError:
    print(
        "pyyaml is required: pip install pyyaml",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    from prompt_toolkit import prompt as pt_prompt
    from prompt_toolkit.completion import FuzzyWordCompleter
    from prompt_toolkit.formatted_text import HTML
    from prompt_toolkit.shortcuts import radiolist_dialog
    from prompt_toolkit.styles import Style

    HAS_PROMPT_TOOLKIT = True
except ImportError:  # pragma: no cover
    HAS_PROMPT_TOOLKIT = False

# ── ANSI colours ──────────────────────────────────────────────────────────────
GREEN = "\033[0;32m"
CYAN = "\033[0;36m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
BOLD = "\033[1m"
RESET = "\033[0m"


def _color(text: str, code: str) -> str:
    return f"{code}{text}{RESET}"


# ── Kubeconfig loading ────────────────────────────────────────────────────────

def _kubeconfig_paths() -> list[Path]:
    """Return existing kubeconfig file paths respecting KUBECONFIG env var."""
    raw = os.environ.get("KUBECONFIG", str(Path.home() / ".kube" / "config"))
    paths = [Path(p) for p in raw.split(":") if p]
    return [p for p in paths if p.is_file()]


def _load_kubeconfigs() -> list[dict]:
    """Load and return all kubeconfig dicts."""
    configs = []
    for path in _kubeconfig_paths():
        try:
            with open(path) as f:
                data = yaml.safe_load(f)
            if isinstance(data, dict):
                data["_source_path"] = str(path)
                configs.append(data)
        except (yaml.YAMLError, OSError) as exc:
            print(f"{RED}Warning: could not read {path}: {exc}{RESET}", file=sys.stderr)
    return configs


def _first_kubeconfig_path() -> Optional[Path]:
    paths = _kubeconfig_paths()
    return paths[0] if paths else None


# ── Context helpers ───────────────────────────────────────────────────────────

def list_contexts(configs: list[dict]) -> list[dict]:
    """Return all context entries across all kubeconfig files."""
    contexts = []
    seen: set[str] = set()
    for cfg in configs:
        for ctx in cfg.get("contexts") or []:
            name = (ctx or {}).get("name", "")
            if name and name not in seen:
                seen.add(name)
                contexts.append(ctx)
    return contexts


def current_context(configs: list[dict]) -> Optional[str]:
    """Return the current-context from the first kubeconfig that has one."""
    for cfg in configs:
        val = cfg.get("current-context")
        if val:
            return val
    return None


def get_cluster_for_context(name: str, configs: list[dict]) -> Optional[str]:
    for cfg in configs:
        for ctx in cfg.get("contexts") or []:
            if (ctx or {}).get("name") == name:
                return (ctx.get("context") or {}).get("cluster")
    return None


def get_server_for_cluster(cluster_name: str, configs: list[dict]) -> Optional[str]:
    for cfg in configs:
        for cl in cfg.get("clusters") or []:
            if (cl or {}).get("name") == cluster_name:
                return (cl.get("cluster") or {}).get("server")
    return None


def set_context(name: str) -> None:
    """Write the new current-context into the first kubeconfig file."""
    path = _first_kubeconfig_path()
    if path is None:
        print(f"{RED}No kubeconfig file found{RESET}", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        content = f.read()
    content = re.sub(
        r"^(current-context:\s*).*$",
        lambda m: m.group(1) + name,
        content,
        flags=re.MULTILINE,
    )
    with open(path, "w") as f:
        f.write(content)


# ── Namespace helpers ─────────────────────────────────────────────────────────

def current_namespace(context_name: str, configs: list[dict]) -> str:
    for cfg in configs:
        for ctx in cfg.get("contexts") or []:
            if (ctx or {}).get("name") == context_name:
                ns = (ctx.get("context") or {}).get("namespace")
                return ns if ns else "default"
    return "default"


def list_namespaces() -> list[str]:
    """List namespaces using kubectl."""
    import subprocess

    try:
        result = subprocess.run(
            ["kubectl", "get", "namespaces", "--no-headers",
             "-o", "custom-columns=:metadata.name"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            print(f"{RED}kubectl error: {result.stderr.strip()}{RESET}", file=sys.stderr)
            return []
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]
    except FileNotFoundError:
        print(f"{RED}kubectl not found in PATH{RESET}", file=sys.stderr)
        return []
    except subprocess.TimeoutExpired:
        print(f"{RED}kubectl timed out listing namespaces{RESET}", file=sys.stderr)
        return []


def set_namespace(ns: str) -> None:
    """Set the namespace on the current context via kubectl."""
    import subprocess

    try:
        result = subprocess.run(
            ["kubectl", "config", "set-context", "--current", f"--namespace={ns}"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"{RED}kubectl error: {result.stderr.strip()}{RESET}", file=sys.stderr)
            sys.exit(1)
    except FileNotFoundError:
        print(f"{RED}kubectl not found in PATH{RESET}", file=sys.stderr)
        sys.exit(1)


# ── Interactive selector ──────────────────────────────────────────────────────

def _strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def fuzzy_select(items: list[str], prompt_text: str = "Select > ") -> Optional[str]:
    """
    Present an interactive fuzzy selector.

    Uses prompt_toolkit if available; falls back to a simple numbered menu.
    Returns the selected item (plain text, ANSI stripped) or None if cancelled.
    """
    if not items:
        return None

    plain_items = [_strip_ansi(it) for it in items]

    if HAS_PROMPT_TOOLKIT:
        completer = FuzzyWordCompleter(plain_items, WORD=True)
        style = Style.from_dict(
            {
                "prompt": "bold cyan",
                "completion-menu.completion": "bg:#1e3a5f #ffffff",
                "completion-menu.completion.current": "bg:#0066cc #ffffff bold",
            }
        )
        print(f"{CYAN}Use Tab/arrows to navigate, Enter to confirm, Ctrl-C to cancel{RESET}")
        print()
        for item in items:
            print(f"  {item}")
        print()
        try:
            answer = pt_prompt(
                HTML(f"<ansicyan><b>{prompt_text}</b></ansicyan>"),
                completer=completer,
                complete_while_typing=True,
                style=style,
            )
        except (KeyboardInterrupt, EOFError):
            return None

        answer = answer.strip()
        # Match against plain items (case-insensitive prefix/substring)
        for plain in plain_items:
            if plain.lower() == answer.lower():
                return plain
        for plain in plain_items:
            if plain.lower().startswith(answer.lower()):
                return plain
        for plain in plain_items:
            if answer.lower() in plain.lower():
                return plain
        return None
    else:
        # Numbered fallback
        print(f"\n{CYAN}{prompt_text}{RESET}")
        for idx, item in enumerate(items, 1):
            print(f"  {idx:3d}) {item}")
        print()
        while True:
            try:
                raw = input("Enter number (or 0 to cancel): ").strip()
            except (KeyboardInterrupt, EOFError):
                print()
                return None
            if raw == "0":
                return None
            try:
                idx = int(raw)
                if 1 <= idx <= len(plain_items):
                    return plain_items[idx - 1]
                print(f"{RED}Out of range — enter 1–{len(plain_items)}{RESET}")
            except ValueError:
                print(f"{RED}Please enter a number{RESET}")


# ── CLI commands ──────────────────────────────────────────────────────────────

def cmd_show_current(configs: list[dict]) -> None:
    ctx = current_context(configs)
    if ctx is None:
        print(f"{RED}No current context set{RESET}")
        sys.exit(1)
    ns = current_namespace(ctx, configs)
    cluster = get_cluster_for_context(ctx, configs)
    server = get_server_for_cluster(cluster, configs) if cluster else None
    print(f"{BOLD}Context  :{RESET} {_color(ctx, GREEN)}")
    print(f"{BOLD}Namespace:{RESET} {_color(ns, CYAN)}")
    if server:
        print(f"{BOLD}Server   :{RESET} {_color(server, YELLOW)}")


def cmd_list_contexts(configs: list[dict]) -> None:
    cur = current_context(configs)
    contexts = list_contexts(configs)
    if not contexts:
        print(f"{RED}No contexts found{RESET}")
        return
    for ctx in contexts:
        name = ctx.get("name", "")
        cluster = get_cluster_for_context(name, configs)
        server = get_server_for_cluster(cluster, configs) if cluster else None
        marker = "*" if name == cur else " "
        name_col = _color(f"{marker} {name}", GREEN if name == cur else RESET)
        server_str = _color(server or "<unknown>", CYAN)
        print(f"{name_col:<60}  {server_str}")


def cmd_switch_context(configs: list[dict]) -> None:
    cur = current_context(configs)
    contexts = list_contexts(configs)
    if not contexts:
        print(f"{RED}No contexts found in kubeconfig{RESET}", file=sys.stderr)
        sys.exit(1)

    display: list[str] = []
    for ctx in contexts:
        name = ctx.get("name", "")
        cluster = get_cluster_for_context(name, configs)
        server = get_server_for_cluster(cluster, configs) if cluster else None
        if name == cur:
            label = f"{_color('* ' + name, GREEN + BOLD):<60}  {_color(server or '<unknown>', CYAN)}"
        else:
            label = f"  {name:<58}  {_color(server or '<unknown>', CYAN)}"
        display.append(label)

    chosen = fuzzy_select(display, "Switch context > ")
    if chosen is None:
        print(f"{YELLOW}Cancelled{RESET}")
        return

    # chosen is already plain text from fuzzy_select
    chosen_name = chosen.strip().lstrip("*").strip().split()[0]
    if not chosen_name:
        print(f"{RED}Could not determine selected context{RESET}", file=sys.stderr)
        sys.exit(1)

    if chosen_name == cur:
        print(f"{YELLOW}Already on context:{RESET} {_color(chosen_name, GREEN)}")
        return

    set_context(chosen_name)
    print(f"{GREEN}Switched to context:{RESET} {BOLD}{chosen_name}{RESET}")


def cmd_switch_namespace(configs: list[dict]) -> None:
    cur_ctx = current_context(configs)
    cur_ns = current_namespace(cur_ctx or "", configs) if cur_ctx else "default"

    namespaces = list_namespaces()
    if not namespaces:
        sys.exit(1)

    display: list[str] = []
    for ns in namespaces:
        if ns == cur_ns:
            display.append(_color(f"* {ns}", GREEN + BOLD))
        else:
            display.append(f"  {ns}")

    chosen = fuzzy_select(display, "Switch namespace > ")
    if chosen is None:
        print(f"{YELLOW}Cancelled{RESET}")
        return

    chosen_ns = chosen.strip().lstrip("*").strip().split()[0]
    if not chosen_ns:
        print(f"{RED}Could not determine selected namespace{RESET}", file=sys.stderr)
        sys.exit(1)

    if chosen_ns == cur_ns:
        print(f"{YELLOW}Already in namespace:{RESET} {_color(chosen_ns, GREEN)}")
        return

    set_namespace(chosen_ns)
    print(f"{GREEN}Switched to namespace:{RESET} {BOLD}{chosen_ns}{RESET}")


# ── Argument parsing ──────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kctx-fuzzy",
        description="kubectl context and namespace switcher with built-in fuzzy search",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
commands:
  kctx          interactive context switch (default)
  kns           interactive namespace switch

examples:
  kctx-fuzzy              # switch context interactively
  kctx-fuzzy --list       # list all contexts
  kctx-fuzzy --current    # show current context/namespace
  kctx-fuzzy kns          # switch namespace
""",
    )
    parser.add_argument(
        "command",
        nargs="?",
        choices=["kctx", "kns"],
        default="kctx",
        help="subcommand: kctx (context, default) or kns (namespace)",
    )
    parser.add_argument(
        "--list", "-l",
        action="store_true",
        help="list all contexts",
    )
    parser.add_argument(
        "--current", "-c",
        action="store_true",
        help="show current context and namespace",
    )
    parser.add_argument(
        "--version", "-v",
        action="version",
        version="%(prog)s 0.1.0",
    )
    return parser


def main() -> None:
    # Allow invoking as `kns` / `kns-fuzzy` to jump straight to namespace mode
    prog_name = Path(sys.argv[0]).name
    if prog_name in ("kns", "kns-fuzzy"):
        configs = _load_kubeconfigs()
        cmd_switch_namespace(configs)
        return

    parser = build_parser()
    args = parser.parse_args()

    configs = _load_kubeconfigs()
    if not configs:
        print(f"{RED}No kubeconfig files found. Set KUBECONFIG or create ~/.kube/config{RESET}", file=sys.stderr)
        sys.exit(1)

    if args.current:
        cmd_show_current(configs)
        return

    if args.list:
        cmd_list_contexts(configs)
        return

    if args.command == "kns":
        cmd_switch_namespace(configs)
    else:
        cmd_switch_context(configs)


if __name__ == "__main__":
    main()
