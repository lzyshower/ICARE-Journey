#!/usr/bin/env python3
"""
Windows bootstrap script for https://github.com/ruvnet/ruflo

What it does:
  1. Installs missing Git and Node.js LTS via winget when possible.
  2. Clones or updates the ruvnet/ruflo repository.
  3. Installs npm dependencies for the local ruflo package and MCP bridge.
  4. Starts the local Ruflo MCP bridge on http://localhost:3001 by default.

Examples:
  python setup_ruflo_windows.py
  python setup_ruflo_windows.py --dir C:\\dev\\ruflo --mode bridge
  python setup_ruflo_windows.py --mode cli --cli-args "--help"
  python setup_ruflo_windows.py --mode init-wizard
  python setup_ruflo_windows.py --install-global-backends

Notes:
  - Requires Windows 10/11 with winget for automatic prerequisite installs.
  - If Git/Node are installed during this run but PATH does not refresh, close
    PowerShell/CMD, reopen it, and rerun the same command.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


REPO_URL = "https://github.com/ruvnet/ruflo.git"
DEFAULT_PORT = 3001


def log(message: str) -> None:
    print(f"\n=== {message} ===", flush=True)


def info(message: str) -> None:
    print(message, flush=True)


def fail(message: str, code: int = 1) -> None:
    print(f"\nERROR: {message}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def run(
    command: list[str],
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    display = " ".join(f'"{x}"' if " " in x else x for x in command)
    if cwd:
        info(f"[{cwd}]> {display}")
    else:
        info(f"> {display}")

    completed = subprocess.run(command, cwd=cwd, env=env, text=True)
    if check and completed.returncode != 0:
        fail(f"Command failed with exit code {completed.returncode}: {display}")
    return completed


def capture(command: list[str]) -> str:
    try:
        completed = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return completed.stdout.strip() if completed.returncode == 0 else ""
    except FileNotFoundError:
        return ""


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def is_windows() -> bool:
    return os.name == "nt"


def refresh_path_from_registry() -> None:
    if not is_windows():
        return
    try:
        import winreg

        parts: list[str] = []
        for root, subkey in (
            (winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
            (winreg.HKEY_CURRENT_USER, r"Environment"),
        ):
            try:
                with winreg.OpenKey(root, subkey) as key:
                    value, _ = winreg.QueryValueEx(key, "Path")
                    if value:
                        parts.append(str(value))
            except OSError:
                pass
        if parts:
            os.environ["PATH"] = ";".join(parts)
    except Exception:
        pass


def winget_available() -> bool:
    return command_exists("winget")


def winget_install(package_id: str, name: str) -> None:
    if not winget_available():
        fail(
            "winget was not found. Install 'App Installer' from Microsoft Store, "
            f"or install {name} manually and rerun this script."
        )

    log(f"Installing {name} via winget")
    run(
        [
            "winget",
            "install",
            "--id",
            package_id,
            "--exact",
            "--source",
            "winget",
            "--accept-package-agreements",
            "--accept-source-agreements",
        ]
    )
    refresh_path_from_registry()


def ensure_git(skip_install: bool) -> None:
    if command_exists("git"):
        info(capture(["git", "--version"]) or "Git found")
        return
    if skip_install:
        fail("Git was not found. Install Git for Windows or rerun without --skip-prereq-install.")
    winget_install("Git.Git", "Git for Windows")
    if not command_exists("git"):
        fail("Git was installed but is not visible in PATH. Reopen your terminal and rerun this script.")


def node_major() -> int | None:
    output = capture(["node", "--version"])
    if not output.startswith("v"):
        return None
    try:
        return int(output[1:].split(".", 1)[0])
    except ValueError:
        return None


def ensure_node(skip_install: bool) -> None:
    major = node_major()
    if major is not None and major >= 20 and command_exists("npm"):
        info(f"Node: {capture(['node', '--version'])}")
        info(f"npm:  {capture(['npm', '--version'])}")
        return

    if skip_install:
        fail("Node.js >=20 and npm were not found. Install Node.js LTS or rerun without --skip-prereq-install.")

    winget_install("OpenJS.NodeJS.LTS", "Node.js LTS")
    refresh_path_from_registry()
    major = node_major()
    if major is None or major < 20 or not command_exists("npm"):
        fail("Node.js was installed but is not visible in PATH. Reopen your terminal and rerun this script.")


def clone_or_update(repo_dir: Path, no_update: bool) -> None:
    if not repo_dir.exists():
        log(f"Cloning {REPO_URL}")
        repo_dir.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", REPO_URL, str(repo_dir)])
        return

    git_dir = repo_dir / ".git"
    if not git_dir.exists():
        fail(f"Target directory exists but is not a Git repository: {repo_dir}")

    log(f"Using existing repository: {repo_dir}")
    if not no_update:
        run(["git", "pull", "--ff-only"], cwd=repo_dir)


def npm_install_if_needed(directory: Path, force: bool) -> None:
    package_json = directory / "package.json"
    if not package_json.exists():
        fail(f"package.json not found: {package_json}")

    node_modules = directory / "node_modules"
    if node_modules.exists() and not force:
        info(f"node_modules already exists: {node_modules}")
        return

    log(f"Installing npm dependencies in {directory}")
    lock_file = directory / "package-lock.json"
    if lock_file.exists():
        run(["npm", "ci"], cwd=directory)
    else:
        run(["npm", "install"], cwd=directory)


def install_global_backends() -> None:
    log("Installing optional global MCP backends")
    packages = [
        "ruvector",
        "ruflo",
        "agentic-flow@alpha",
        "gemini-mcp-server",
        "@openai/codex",
    ]
    for package in packages:
        completed = run(["npm", "install", "-g", package], check=False)
        if completed.returncode != 0:
            info(f"WARNING: optional backend failed to install: {package}")


def wait_for_health(port: int, timeout_seconds: int = 45) -> None:
    deadline = time.time() + timeout_seconds
    url = f"http://127.0.0.1:{port}/health"
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                body = response.read().decode("utf-8", errors="replace")
                if response.status == 200:
                    info(f"Health check OK: {url}")
                    info(body[:500])
                    return
        except Exception:
            time.sleep(1)
    info(f"WARNING: health check did not respond within {timeout_seconds}s: {url}")


def start_bridge(repo_dir: Path, port: int, keep_window: bool) -> None:
    bridge_dir = repo_dir / "ruflo" / "src" / "mcp-bridge"
    env = os.environ.copy()
    env.setdefault("PORT", str(port))
    env.setdefault("MCP_GROUP_INTELLIGENCE", "true")
    env.setdefault("MCP_GROUP_AGENTS", "true")
    env.setdefault("MCP_GROUP_MEMORY", "true")
    env.setdefault("MCP_GROUP_DEVTOOLS", "true")
    env.setdefault("MCP_GROUP_SECURITY", "false")
    env.setdefault("MCP_GROUP_BROWSER", "false")
    env.setdefault("MCP_GROUP_NEURAL", "false")
    env.setdefault("MCP_GROUP_AGENTIC_FLOW", "false")
    env.setdefault("MCP_GROUP_CLAUDE_CODE", "false")
    env.setdefault("MCP_GROUP_GEMINI", "false")
    env.setdefault("MCP_GROUP_CODEX", "false")

    log(f"Starting Ruflo MCP bridge on http://localhost:{port}")
    if is_windows() and keep_window:
        command = f'title Ruflo MCP Bridge && cd /d "{bridge_dir}" && npm start'
        subprocess.Popen(["cmd", "/k", command], env=env)
        wait_for_health(port)
        info(f"Bridge is running in a new terminal window: http://localhost:{port}")
        return

    run(["npm", "start"], cwd=bridge_dir, env=env)


def run_cli(repo_dir: Path, cli_args: list[str], workspace: Path) -> None:
    ruflo_dir = repo_dir / "ruflo"
    ruflo_bin = ruflo_dir / "bin" / "ruflo.js"
    if not ruflo_bin.exists():
        fail(f"Ruflo CLI entry not found: {ruflo_bin}")

    log("Running local Ruflo CLI")
    workspace.mkdir(parents=True, exist_ok=True)
    run(["node", str(ruflo_bin), *cli_args], cwd=workspace)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bootstrap and run ruvnet/ruflo on Windows.")
    parser.add_argument("--dir", default=str(Path.cwd() / "ruflo"), help="Where to clone/use the repo.")
    parser.add_argument(
        "--workspace",
        default=str(Path.cwd()),
        help="Working directory for local Ruflo CLI/init commands. Defaults to the current directory.",
    )
    parser.add_argument(
        "--mode",
        choices=["bridge", "cli", "init-wizard", "install-only"],
        default="bridge",
        help="What to do after dependencies are installed.",
    )
    parser.add_argument("--cli-args", default="--help", help="Arguments for --mode cli, e.g. 'mcp start'.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="MCP bridge port.")
    parser.add_argument("--skip-prereq-install", action="store_true", help="Do not install Git/Node via winget.")
    parser.add_argument("--no-update", action="store_true", help="Do not git pull if repo already exists.")
    parser.add_argument("--force-npm-install", action="store_true", help="Run npm install/ci even if node_modules exists.")
    parser.add_argument(
        "--install-global-backends",
        action="store_true",
        help="Install optional global MCP backends used by the bridge. Slower but more complete.",
    )
    parser.add_argument(
        "--same-window",
        action="store_true",
        help="Run bridge in the current terminal instead of opening a new cmd window on Windows.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo_dir = Path(args.dir).expanduser().resolve()
    workspace = Path(args.workspace).expanduser().resolve()

    log("Checking prerequisites")
    ensure_git(args.skip_prereq_install)
    ensure_node(args.skip_prereq_install)

    clone_or_update(repo_dir, args.no_update)

    ruflo_dir = repo_dir / "ruflo"
    bridge_dir = ruflo_dir / "src" / "mcp-bridge"
    if not ruflo_dir.exists() or not bridge_dir.exists():
        fail(f"Unexpected repository layout. Missing {ruflo_dir} or {bridge_dir}")

    npm_install_if_needed(ruflo_dir, args.force_npm_install)
    npm_install_if_needed(bridge_dir, args.force_npm_install)

    if args.install_global_backends:
        install_global_backends()

    if args.mode == "install-only":
        log("Install complete")
        info(f"Repository: {repo_dir}")
        info(f"Run bridge later: python {Path(__file__).name} --dir {repo_dir} --mode bridge")
        return

    if args.mode == "bridge":
        start_bridge(repo_dir, args.port, keep_window=not args.same_window)
        return

    if args.mode == "init-wizard":
        run_cli(repo_dir, ["init", "wizard"], workspace)
        return

    if args.mode == "cli":
        run_cli(repo_dir, args.cli_args.split(), workspace)
        return


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        fail("Interrupted by user", code=130)
