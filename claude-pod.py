#!/usr/bin/env python3
"""claude-pod — run Claude Code in a rootless Podman container"""

from __future__ import annotations

import argparse
import os
import platform
import pwd
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    import tomllib
except ImportError:
    sys.exit("error: Python 3.11+ is required (for tomllib)")

VERSION = "0.8.0"
IMAGE = "claude-pod:latest"
CONTAINER_NAME_PREFIX = "claude-pod"
HOST_OS = platform.system()
HOME = Path.home()
CONFIG_FILE = HOME / ".config" / "claude-pod" / "config.toml"
DATA_DIR = HOME / ".local" / "share" / "claude-pod"


def is_macos() -> bool:
    return HOST_OS == "Darwin"


# --- Config file parsing ---

_toml_cache: dict[Path, dict] = {}


def _load_toml(path: Path) -> dict:
    if path in _toml_cache:
        return _toml_cache[path]
    result: dict = {}
    if path.is_file():
        try:
            result = tomllib.loads(path.read_text())
        except Exception as exc:
            print(f"warning: failed to load config '{path}': {exc}", file=sys.stderr)
    _toml_cache[path] = result
    return result


def cfg_get(section: str, key: str, path: Path = CONFIG_FILE) -> str:
    data = _load_toml(path)
    return str(data.get(section, {}).get(key, ""))


def cfg_get_array(section: str, key: str, path: Path = CONFIG_FILE) -> list[str]:
    data = _load_toml(path)
    val = data.get(section, {}).get(key, [])
    if isinstance(val, list):
        return [str(v) for v in val]
    return []


def cfg_has_key(section: str, key: str, path: Path = CONFIG_FILE) -> bool:
    data = _load_toml(path)
    return key in data.get(section, {})


class Config:
    """Handles merged global + project config."""

    def __init__(self, project_config: Path | None = None):
        self.global_path = CONFIG_FILE
        self.project_path = project_config

    def get_merged(self, section: str, key: str) -> str:
        if self.project_path and cfg_has_key(section, key, self.project_path):
            return cfg_get(section, key, self.project_path)
        return cfg_get(section, key, self.global_path)

    def get_array_merged(self, section: str, key: str) -> list[str]:
        result = cfg_get_array(section, key, self.global_path)
        if self.project_path:
            result.extend(cfg_get_array(section, key, self.project_path))
        return result


def load_project_config(directory: Path) -> Path | None:
    cfg = directory / ".claude-pod.toml"
    return cfg if cfg.is_file() else None


# --- Helpers ---


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def require_image() -> None:
    result = subprocess.run(
        ["podman", "image", "exists", IMAGE],
        capture_output=True,
    )
    if result.returncode != 0:
        die(f"Image '{IMAGE}' not found. Run 'claude-pod build' first.")


def suggest_podman_install() -> None:
    print("error: Podman is not installed.", file=sys.stderr)
    install_cmd = ""
    needs_root = False

    if os.getuid() != 0:
        if shutil.which("sudo"):
            sudo_prefix = "sudo "
        else:
            needs_root = True
            sudo_prefix = ""
    else:
        sudo_prefix = ""

    for cmd, pkg_cmd in [
        ("dnf", f"{sudo_prefix}dnf install -y podman"),
        ("apt-get", f"{sudo_prefix}apt-get install -y podman"),
        ("brew", "brew install podman"),
        ("pacman", f"{sudo_prefix}pacman -S podman"),
        ("zypper", f"{sudo_prefix}zypper install -y podman"),
    ]:
        if shutil.which(cmd):
            install_cmd = pkg_cmd
            break

    if needs_root and install_cmd:
        print(f"Install with (as root): {install_cmd}", file=sys.stderr)
        print("Run as root or install sudo first.", file=sys.stderr)
        sys.exit(1)

    if install_cmd:
        print(f"Install with: {install_cmd}", file=sys.stderr)
        if sys.stdin.isatty() and sys.stderr.isatty():
            answer = input("Install now? [y/N] ")
            if answer.strip().lower() == "y":
                ret = subprocess.run(install_cmd, shell=True)
                if ret.returncode != 0:
                    die("Podman installation failed.")
                if not shutil.which("podman"):
                    die("Podman was installed but is not in PATH. Try opening a new shell.")
                return
    else:
        print(
            "See https://podman.io/docs/installation for install instructions.",
            file=sys.stderr,
        )
    sys.exit(1)


def require_podman() -> None:
    if not shutil.which("podman"):
        suggest_podman_install()


def ensure_podman_machine() -> None:
    if not is_macos():
        return
    result = subprocess.run(
        ["podman", "info"], capture_output=True
    )
    if result.returncode != 0:
        print("Starting podman machine...")
        subprocess.run(["podman", "machine", "init"], capture_output=True)
        ret = subprocess.run(["podman", "machine", "start"])
        if ret.returncode != 0:
            die("Failed to start podman machine")


def portable_realpath(path: Path) -> Path:
    return path.resolve()


def resolve_dirs() -> tuple[str, str]:
    """Returns (script_dir, build_dir)."""
    script_path = Path(__file__).resolve().parent
    script_dir = str(script_path)
    containerfile = script_path / "Containerfile"
    entrypoint = script_path / "entrypoint.sh"
    if containerfile.is_file() and entrypoint.is_file():
        build_dir = script_dir
    else:
        build_dir = str(DATA_DIR)
    return script_dir, build_dir


def has_local_build_files() -> bool:
    script_dir = Path(__file__).resolve().parent
    return (script_dir / "Containerfile").is_file() and (
        script_dir / "entrypoint.sh"
    ).is_file()


# --- Mount helpers ---

# macOS-specific dirs to skip
_MACOS_SKIP = {".Trash", ".Trashes", "Library", ".local"}

# Always rw directories
_RW_DIRS = {".claude", ".config", ".local"}


def _home_items() -> list[Path]:
    """List HOME contents in the same order as bash globs: .[!.]* ..?* *"""
    items: list[Path] = []
    seen: set[str] = set()

    # .[!.]* — single-dot prefixed (excludes ..* per bash semantics)
    for item in sorted(HOME.glob(".[!.]*")):
        name = item.name
        if name not in seen:
            seen.add(name)
            items.append(item)

    # ..?* — items starting with .. followed by at least one char
    for item in sorted(HOME.glob("..?*")):
        name = item.name
        if name not in seen:
            seen.add(name)
            items.append(item)

    # * — non-dot items
    for item in sorted(HOME.glob("*")):
        name = item.name
        if name not in seen:
            seen.add(name)
            items.append(item)

    return items


def mount_home_items(
    args: list[str], cwd: Path, extra_rw: set[str]
) -> None:
    home_str = str(HOME)
    cwd_str = str(cwd)

    # Determine cwd's top-level parent under HOME
    cwd_top = ""
    if cwd_str.startswith(home_str + "/"):
        rel = cwd_str[len(home_str) + 1 :]
        cwd_top = str(HOME / rel.split("/")[0])

    for item in _home_items():
        name = item.name
        item_str = str(item)

        if is_macos() and name in _MACOS_SKIP:
            continue

        if name == ".claude.json":
            args.extend(["-v", f"{item_str}:/mnt/.claude.json:ro"])
        elif name in _RW_DIRS:
            args.extend(["-v", f"{item_str}:{item_str}"])
        elif item_str == cwd_top or item_str in extra_rw:
            args.extend(["-v", f"{item_str}:{item_str}"])
        else:
            args.extend(["-v", f"{item_str}:{item_str}:ro"])


def cwd_needs_mount(cwd: Path) -> bool:
    cwd_str = str(cwd)
    home_str = str(HOME)
    return cwd_str != home_str and not cwd_str.startswith(home_str + "/")


def build_base_args(
    args: list[str], cwd: Path, extra_rw: set[str]
) -> None:
    args.extend(["--rm", "-w", str(cwd)])
    if not is_macos():
        args.extend(["--userns=keep-id", "--security-opt", "label=disable"])

    mount_home_items(args, cwd, extra_rw)

    if cwd_needs_mount(cwd):
        if is_macos():
            print(
                f"warning: CWD '{cwd}' is outside $HOME — it may not be shared with the podman machine VM.",
                file=sys.stderr,
            )
        args.extend(["-v", f"{cwd}:{cwd}"])

    homebrew = os.environ.get("HOMEBREW_PREFIX", "")
    if not is_macos() and homebrew and Path(homebrew).is_dir():
        args.extend(["-v", f"{homebrew}:{homebrew}:ro"])


# --- Subcommands ---


def cmd_build(_args: argparse.Namespace) -> None:
    require_podman()
    ensure_podman_machine()
    _, build_dir = resolve_dirs()
    bf = Path(build_dir)
    if not (bf / "Containerfile").is_file() or not (bf / "entrypoint.sh").is_file():
        die(f"Build files (Containerfile, entrypoint.sh) not found in {build_dir}. Run 'claude-pod install' first.")

    shell_name = os.path.basename(os.environ.get("SHELL", "bash"))
    try:
        shell_name = os.path.basename(pwd.getpwuid(os.getuid()).pw_shell)
    except Exception:
        pass
    if shell_name not in ("bash", "zsh", "fish"):
        print(f"warning: unsupported shell '{shell_name}', defaulting to bash", file=sys.stderr)
        shell_name = "bash"

    username = pwd.getpwuid(os.getuid()).pw_name
    uid = os.getuid()
    gid = os.getgid()

    print(f"Building {IMAGE} for {username} (uid={uid}, gid={gid}, shell={shell_name})...")
    build_args = [
        "--build-arg", f"USERNAME={username}",
        "--build-arg", f"USER_UID={uid}",
        "--build-arg", f"USER_GID={gid}",
        "--build-arg", f"USER_SHELL={shell_name}",
        "--build-arg", f"HOME_DIR={HOME}",
    ]
    if is_macos():
        build_args.extend(["--build-arg", "INSTALL_CLAUDE=1"])
    result = subprocess.run(["podman", "build", "-t", IMAGE] + build_args + [build_dir])
    if result.returncode != 0:
        die(f"podman build failed with exit code {result.returncode}")


def cmd_run(args: argparse.Namespace) -> None:
    cwd = Path.cwd()
    project_config = load_project_config(cwd)
    config = Config(project_config)

    # Notify command from config
    notify_cmd = config.get_merged("defaults", "notify_command")
    if not notify_cmd:
        legacy_topic = config.get_merged("defaults", "notify_topic")
        if legacy_topic:
            if not re.match(r"^[A-Za-z0-9._-]+$", legacy_topic):
                die(f"Invalid notify topic '{legacy_topic}' in config. Allowed characters: letters, digits, '.', '_', '-'")
            notify_cmd = f'curl -s -d "Claude Code finished in $WORKSPACE (exit $EXIT_CODE)" https://ntfy.sh/{legacy_topic}'
            print("warning: 'defaults.notify_topic' is deprecated; use 'defaults.notify_command' instead.", file=sys.stderr)

    # Override from CLI flags
    if args.notify:
        topic = args.notify
        if not re.match(r"^[A-Za-z0-9._-]+$", topic):
            die(f"Invalid notify topic '{topic}'. Allowed characters: letters, digits, '.', '_', '-'")
        notify_cmd = f'curl -s -d "Claude Code finished in $WORKSPACE (exit $EXIT_CODE)" https://ntfy.sh/{topic}'
    if args.notify_cmd:
        notify_cmd = args.notify_cmd

    # Merge writable dirs from config
    writable_dirs = list(args.writable_dirs or [])
    writable_dirs.extend(d for d in config.get_array_merged("defaults", "writable_dirs") if d)
    extra_rw = set(writable_dirs)

    podman_args = ["--name", f"{CONTAINER_NAME_PREFIX}-{int(time.time())}"]
    build_base_args(podman_args, cwd, extra_rw)

    if args.keep_groups:
        podman_args.extend(["--group-add", "keep-groups"])

    if args.max_memory:
        podman_args.append(f"--memory={args.max_memory}")

    if args.gpu:
        podman_args.extend(["--device", "nvidia.com/gpu=all"])

    if os.environ.get("ANTHROPIC_API_KEY"):
        podman_args.extend(["-e", "ANTHROPIC_API_KEY"])

    if notify_cmd:
        podman_args.extend(["-e", f"NOTIFY_CMD={notify_cmd}"])

    if args.no_yolo:
        podman_args.extend(["-e", "CLAUDE_POD_NO_YOLO=1"])

    if args.host_loopback and args.network:
        die("--host-loopback and --network are mutually exclusive")
    if args.host_loopback:
        podman_args.append("--network=slirp4netns:allow_host_loopback=true")
    elif args.network:
        podman_args.append(f"--network={args.network}")

    for port in (args.ports or []):
        podman_args.extend(["-p", port])

    if os.environ.get("CLAUDE_POD_CMD"):
        podman_args.extend(["-e", "CLAUDE_POD_CMD"])

    for var in (args.env_vars or []):
        podman_args.extend(["-e", var])

    # Extra env vars from config
    for var in config.get_array_merged("defaults", "extra_env"):
        if var:
            podman_args.extend(["-e", var])

    # Extra writable dirs (top-level HOME entries handled by mount_home_items)
    for d in writable_dirs:
        if d != str(HOME):
            podman_args.extend(["-v", f"{d}:{d}"])

    # Extra volumes from config
    for vol in config.get_array_merged("defaults", "extra_volumes"):
        if vol:
            podman_args.extend(["-v", vol])

    if args.detach:
        podman_args.append("-d")
    elif sys.stdin.isatty():
        podman_args.append("-it")
    else:
        podman_args.append("-i")

    claude_args = getattr(args, "claude_args", None) or []

    if args.dry_run:
        parts = ["podman", "run"] + podman_args + [IMAGE] + claude_args
        print(" ".join(parts))
        return

    require_podman()
    ensure_podman_machine()
    require_image()
    result = subprocess.run(["podman", "run"] + podman_args + [IMAGE] + claude_args)
    sys.exit(result.returncode)


def cmd_shell(args: argparse.Namespace) -> None:
    cwd = Path.cwd()
    project_config = load_project_config(cwd)
    config = Config(project_config)

    # Merge writable dirs from config
    writable_dirs = list(args.writable_dirs or [])
    writable_dirs.extend(d for d in config.get_array_merged("defaults", "writable_dirs") if d)
    extra_rw = set(writable_dirs)

    shell_args = ["-it"]
    build_base_args(shell_args, cwd, extra_rw)

    if args.max_memory:
        shell_args.append(f"--memory={args.max_memory}")

    if args.gpu:
        shell_args.extend(["--device", "nvidia.com/gpu=all"])

    if args.host_loopback and args.network:
        die("--host-loopback and --network are mutually exclusive")
    if args.host_loopback:
        shell_args.append("--network=slirp4netns:allow_host_loopback=true")
    elif args.network:
        shell_args.append(f"--network={args.network}")

    for port in (args.ports or []):
        shell_args.extend(["-p", port])

    for var in (args.env_vars or []):
        shell_args.extend(["-e", var])

    # Extra env vars from config
    for var in config.get_array_merged("defaults", "extra_env"):
        if var:
            shell_args.extend(["-e", var])

    # Extra writable dirs
    for d in writable_dirs:
        if d != str(HOME):
            shell_args.extend(["-v", f"{d}:{d}"])

    if args.dry_run:
        parts = ["podman", "run"] + shell_args + ["-e", "CLAUDE_POD_SHELL=1", IMAGE]
        print(" ".join(parts))
        return

    require_podman()
    ensure_podman_machine()
    require_image()
    result = subprocess.run(
        ["podman", "run"] + shell_args + ["-e", "CLAUDE_POD_SHELL=1", IMAGE]
    )
    sys.exit(result.returncode)


def cmd_exec(args: argparse.Namespace) -> None:
    require_podman()
    ensure_podman_machine()
    if not args.command:
        die("Usage: claude-pod exec <command...>")
    result = subprocess.run(
        ["podman", "ps", "--filter", f"name={CONTAINER_NAME_PREFIX}",
         "--format", "{{.Names}}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        err = (result.stderr or "").strip()
        die(f"'podman ps' failed (exit code {result.returncode}): {err}" if err
            else f"'podman ps' failed with exit code {result.returncode}.")
    containers = result.stdout.strip().splitlines()
    if not containers:
        die("No running claude-pod container found.")
    container = containers[0]
    ret = subprocess.run(["podman", "exec", "-it", container] + args.command)
    sys.exit(ret.returncode)


def cmd_ps(_args: argparse.Namespace) -> None:
    require_podman()
    ensure_podman_machine()
    result = subprocess.run([
        "podman", "ps", "--filter", f"name={CONTAINER_NAME_PREFIX}",
        "--format", "table {{.Names}}\t{{.Status}}\t{{.Ports}}",
    ])
    sys.exit(result.returncode)


def cmd_clean(_args: argparse.Namespace) -> None:
    require_podman()
    ensure_podman_machine()
    print("Removing claude-pod image...")
    subprocess.run(["podman", "rmi", "-f", IMAGE], capture_output=True)
    print("Done.")


def cmd_install(args: argparse.Namespace) -> None:
    require_podman()
    script_dir, _ = resolve_dirs()

    ref = args.ref or "main"
    data_dir = DATA_DIR
    data_dir.mkdir(parents=True, exist_ok=True)
    local_bin = HOME / ".local" / "bin"
    local_bin.mkdir(parents=True, exist_ok=True)

    install_files = ("entrypoint.sh", "Containerfile", "claude-pod", "claude-pod.py")
    download_files = install_files  # all files needed for remote install too

    script_path = Path(script_dir)
    if has_local_build_files():
        print(f"Installing from local source ({script_dir})...")
        if str(script_path) != str(data_dir):
            for f in install_files:
                src = script_path / f
                if src.is_file():
                    shutil.copy2(str(src), str(data_dir / f))
    else:
        if not shutil.which("curl"):
            die("curl is required for remote install.")
        github_raw = f"https://raw.githubusercontent.com/xukai92/claude-pod/{ref}"
        print(f"Downloading claude-pod from GitHub (ref: {ref})...")
        procs = []
        for fname in download_files:
            p = subprocess.Popen(
                ["curl", "-fsSL", "--show-error",
                 f"{github_raw}/{fname}", "-o", str(data_dir / fname)],
            )
            procs.append((p, fname))
        dl_failed = False
        for p, fname in procs:
            if p.wait() != 0:
                dl_failed = True
        if dl_failed:
            for fname in download_files:
                (data_dir / fname).unlink(missing_ok=True)
            die("Download failed.")

    # Install both the wrapper and the Python script
    for f in ("claude-pod", "claude-pod.py"):
        dest = local_bin / f
        dest.unlink(missing_ok=True)
        shutil.copy2(str(data_dir / f), str(dest))
        dest.chmod(0o755)

    print("Installed claude-pod to ~/.local/bin/claude-pod")

    path_dirs = os.environ.get("PATH", "").split(":")
    if str(local_bin) not in path_dirs:
        print("warning: ~/.local/bin is not in your PATH. Add it to your shell profile.", file=sys.stderr)

    print()
    # Build image
    build_ns = argparse.Namespace()
    cmd_build(build_ns)


def cmd_config(_args: argparse.Namespace) -> None:
    print(f"Global config: {CONFIG_FILE}")
    if CONFIG_FILE.is_file():
        print(CONFIG_FILE.read_text())
    else:
        print("(not found)")


def cmd_version(_args: argparse.Namespace) -> None:
    print(f"claude-pod {VERSION}")


# --- Argument parsing ---


def add_shared_flags(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--dry-run", action="store_true", help="Print the podman command instead of executing it")
    parser.add_argument("-e", "--env", dest="env_vars", action="append", metavar="VAR[=VAL]",
                        help="Pass environment variable to container (repeatable)")
    parser.add_argument("--gpu", action="store_true", help="Enable GPU passthrough (nvidia)")
    parser.add_argument("--host-loopback", action="store_true", help="Expose host loopback to container")
    parser.add_argument("--max-memory", metavar="SIZE", help="Set container memory limit (e.g. 4g)")
    parser.add_argument("--network", help="Podman network mode (e.g. none, host)")
    parser.add_argument("-p", "--port", dest="ports", action="append", metavar="PORT",
                        help="Expose a port (e.g. 3000:3000, repeatable)")
    parser.add_argument("-wd", "--writable-dir", dest="writable_dirs", action="append", metavar="PATH",
                        help="Mount a dir read-write (can be repeated)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="claude-pod",
        description="Run Claude Code in a rootless Podman container",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("-V", "--version", action="version", version=f"claude-pod {VERSION}")

    subparsers = parser.add_subparsers(dest="command")

    # run
    run_parser = subparsers.add_parser("run", help="Start an interactive Claude Code session")
    add_shared_flags(run_parser)
    run_parser.add_argument("--detach", action="store_true", help="Run in background")
    run_parser.add_argument("--keep-groups", action="store_true", help="Preserve supplementary groups")
    run_parser.add_argument("--no-yolo", action="store_true", help="Don't pass --dangerously-skip-permissions")
    run_parser.add_argument("--notify", metavar="TOPIC", help="Send ntfy.sh notification when session ends")
    run_parser.add_argument("--notify-cmd", metavar="CMD", help="Run custom command on exit")
    run_parser.set_defaults(func=cmd_run)

    # shell
    shell_parser = subparsers.add_parser("shell", help="Drop into a bash shell in the container")
    add_shared_flags(shell_parser)
    shell_parser.set_defaults(func=cmd_shell)

    # build
    build_parser_ = subparsers.add_parser("build", help="Build the container image")
    build_parser_.set_defaults(func=cmd_build)

    # exec
    exec_parser = subparsers.add_parser("exec", help="Run a command in a running container")
    exec_parser.add_argument("command", nargs="*", help="Command to execute")
    exec_parser.set_defaults(func=cmd_exec)

    # ps (aliased as 'list')
    ps_parser = subparsers.add_parser("ps", help="List running claude-pod containers")
    ps_parser.set_defaults(func=cmd_ps)
    list_parser = subparsers.add_parser("list", help="List running claude-pod containers")
    list_parser.set_defaults(func=cmd_ps)

    # clean
    clean_parser = subparsers.add_parser("clean", help="Remove container image")
    clean_parser.set_defaults(func=cmd_clean)

    # install
    install_parser = subparsers.add_parser("install", help="Install claude-pod and build image")
    install_parser.add_argument("--ref", default="main", help="Git ref to install from")
    install_parser.set_defaults(func=cmd_install)

    # config
    config_parser = subparsers.add_parser("config", help="Show config")
    config_parser.set_defaults(func=cmd_config)

    # version
    version_parser = subparsers.add_parser("version", help="Show version")
    version_parser.set_defaults(func=cmd_version)

    return parser


def main() -> None:
    parser = build_parser()

    # If no subcommand given, default to "run"
    if len(sys.argv) < 2 or (len(sys.argv) >= 2 and sys.argv[1].startswith("-") and sys.argv[1] not in ("-V", "--version", "-h", "--help")):
        sys.argv.insert(1, "run")

    # Use parse_known_args so unrecognized flags pass through to Claude Code
    # (matches bash behavior where unknown flags are forwarded)
    args, unknown = parser.parse_known_args()

    if getattr(args, "command", None) == "run":
        # Forward unknown args as claude_args.
        # Before "--": option-like tokens and their values are forwarded;
        # bare positionals not preceded by an option are rejected (bash parity).
        # After "--": everything is forwarded unconditionally.
        forwarded: list[str] = []
        if unknown:
            if "--" in unknown:
                sep = unknown.index("--")
                pre, post = unknown[:sep], unknown[sep + 1:]
            else:
                pre, post = unknown, []
            prev_was_option = False
            for tok in pre:
                if tok.startswith("-"):
                    prev_was_option = True
                elif prev_was_option:
                    prev_was_option = False  # value of previous option
                else:
                    parser.error(f"unrecognized argument: {tok}")
            forwarded = pre + post
        args.claude_args = forwarded
    else:
        args.claude_args = []
        if unknown:
            # For non-run subcommands, reject unknown flags
            parser.parse_args()  # will error with usage message

    if hasattr(args, "func"):
        args.func(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
