#!/usr/bin/env python3
"""Eval script for the Software Factory.

Runs each eval dimension and outputs JSON to stdout.

Output format:
    {"results": [{"name": str, "score": float, "weight": float, "passed": bool, "details": str}, ...]}
"""

import ast
import json
import re
import subprocess
import sys
from pathlib import Path

SKIP_DIRS = {
    "tests", "test", ".venv", "venv", "node_modules", "__pycache__",
    ".git", ".factory", "eval", "dist", "build", ".mypy_cache",
}


def eval_tests() -> dict:
    """Run the project test suite."""
    try:
        result = subprocess.run(
            ["bash", "test_python.sh"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        passed = result.returncode == 0
        output = result.stdout + result.stderr
        if passed:
            score = 1.0
        else:
            total = failed = 0
            for line in output.splitlines():
                if "passed" in line and "failed" in line:
                    parts = line.split()
                    for i, p in enumerate(parts):
                        if p == "passed," and i > 0:
                            total += int(parts[i - 1])
                        if p == "failed" and i > 0:
                            failed += int(parts[i - 1])
                            total += failed
            if total > 0:
                score = max(0.0, (total - failed) / total)
            else:
                score = 0.0
        return {
            "name": "tests",
            "score": score,
            "weight": 0.35,
            "passed": passed,
            "details": output.strip()[-500:],
        }
    except subprocess.TimeoutExpired:
        return {
            "name": "tests",
            "score": 0.0,
            "weight": 0.35,
            "passed": False,
            "details": "Timed out after 120s",
        }


def eval_lint() -> dict:
    """Run ruff linter on Python source."""
    try:
        result = subprocess.run(
            ["ruff", "check", "claude-pod.py"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        passed = result.returncode == 0
        if passed:
            score = 1.0
        else:
            error_lines = [
                ln for ln in (result.stdout + result.stderr).splitlines()
                if ln.strip() and not ln.startswith("Found")
            ]
            score = max(0.0, 1.0 - len(error_lines) * 0.05)
        return {
            "name": "lint",
            "score": score,
            "weight": 0.25,
            "passed": passed,
            "details": (result.stdout or result.stderr).strip()[-500:],
        }
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return {
            "name": "lint",
            "score": 0.0,
            "weight": 0.25,
            "passed": False,
            "details": str(e)[:500],
        }


def eval_syntax_check() -> dict:
    """Verify Python code has no syntax errors."""
    try:
        result = subprocess.run(
            ["python3", "-m", "py_compile", "claude-pod.py"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        passed = result.returncode == 0
        return {
            "name": "syntax_check",
            "score": 1.0 if passed else 0.0,
            "weight": 0.15,
            "passed": passed,
            "details": (result.stdout or result.stderr).strip()[-500:] or "OK",
        }
    except subprocess.TimeoutExpired:
        return {
            "name": "syntax_check",
            "score": 0.0,
            "weight": 0.15,
            "passed": False,
            "details": "Timed out after 30s",
        }


def eval_observability() -> dict:
    """Analyze logging coverage, structured logging, and request tracing."""
    log_pats = [
        r"\blogger\.\w+\(",
        r"\blogging\.\w+\(",
        r"\blog\.\w+\(",
        r"\bconsole\.\w+\(",
        r"\bprint\(",
    ]
    struct_pats = [r"\bstructlog\b", r"\bpino\b", r"\bwinston\b",
                   r"\bslog\.\w+\(", r"\btracing::"]
    trace_pats = [r"request.id|req.id|trace.id", r"\bcontextvars\b|ContextVar",
                  r"\bopentelemetry\b", r"trace.context|TraceContext|span"]

    sources = [f for f in Path(".").rglob("*.py")
               if not any(p in f.parts for p in SKIP_DIRS)]
    total_fn = logged_fn = total_log = 0
    has_struct = has_trace = False

    for src in sources:
        try:
            code = src.read_text(errors="replace")
        except OSError:
            continue
        try:
            tree = ast.parse(code)
        except SyntaxError:
            continue
        lines = code.splitlines()
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.name.startswith("__"):
                    continue
                total_fn += 1
                start = node.lineno - 1
                end = node.end_lineno or start + 1
                body = "\n".join(lines[start:end])
                for pat in log_pats:
                    if re.search(pat, body):
                        logged_fn += 1
                        break
        for pat in log_pats:
            total_log += len(re.findall(pat, code))
        for pat in struct_pats:
            if re.search(pat, code):
                has_struct = True
        for pat in trace_pats:
            if re.search(pat, code, re.IGNORECASE):
                has_trace = True

    if total_fn == 0:
        return {"name": "observability", "score": 0.0, "weight": 0.1,
                "passed": True, "details": "No functions found to analyze"}

    cov = logged_fn / total_fn
    density = min(1.0, total_log / max(total_fn, 1))
    score = 0.40 * cov + 0.25 * float(has_struct) + 0.20 * float(has_trace) + 0.15 * density

    details = (f"coverage={cov:.0%} ({logged_fn}/{total_fn}), "
               f"structured={'yes' if has_struct else 'no'}, "
               f"tracing={'yes' if has_trace else 'no'}, "
               f"density={density:.0%}")

    return {"name": "observability", "score": round(score, 3), "weight": 0.1,
            "passed": score >= 0.3, "details": details}


def eval_guard_patterns() -> dict:
    """Check for security anti-patterns."""
    sources = [f for f in Path(".").rglob("*.py")
               if not any(p in f.parts for p in SKIP_DIRS)]

    patterns = [
        (r"subprocess\..*shell\s*=\s*True", "shell=True in subprocess"),
        (r"eval\s*\(", "eval() usage"),
        (r"exec\s*\(", "exec() usage"),
        (r"__import__\s*\(", "__import__() usage"),
        (r"pickle\.loads?\(", "pickle deserialization"),
        (r"os\.system\s*\(", "os.system() usage"),
    ]

    violations = []
    for src in sources:
        try:
            code = src.read_text(errors="replace")
        except OSError:
            continue
        for pat, desc in patterns:
            matches = list(re.finditer(pat, code))
            for m in matches:
                line_num = code[:m.start()].count("\n") + 1
                violations.append(f"{src}:{line_num}: {desc}")

    score = max(0.0, 1.0 - len(violations) * 0.15)
    return {
        "name": "guard_patterns",
        "score": round(score, 3),
        "weight": 0.075,
        "passed": len(violations) == 0,
        "details": "; ".join(violations[:10]) if violations else "No violations found",
    }


def eval_capability_surface() -> dict:
    """Measure CLI commands, flags, and features."""
    try:
        code = Path("claude-pod.py").read_text(errors="replace")
    except OSError:
        return {"name": "capability_surface", "score": 0.0, "weight": 0.075,
                "passed": True, "details": "Could not read claude-pod.py"}

    subcommands = set(re.findall(r'subcommands\s*=\s*\{([^}]+)\}', code, re.DOTALL))
    cmd_count = len(re.findall(r'"(\w+)":\s*\{', "".join(subcommands))) if subcommands else 0
    if cmd_count == 0:
        cmd_count = len(re.findall(r'def\s+cmd_(\w+)', code))

    flags = re.findall(r'["\']--[\w-]+["\']', code)
    unique_flags = len(set(flags))

    tree = ast.parse(code)
    functions = [n for n in ast.walk(tree)
                 if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                 and not n.name.startswith("_")]
    func_count = len(functions)

    has_help = bool(re.search(r'--help|usage|help_text|USAGE', code))

    base = min(1.0, cmd_count / 8)
    flag_score = min(1.0, unique_flags / 20)
    func_score = min(1.0, func_count / 30)
    score = 0.3 * base + 0.3 * flag_score + 0.3 * func_score + 0.1 * float(has_help)

    details = f"commands={cmd_count}, flags={unique_flags}, functions={func_count}, help={'yes' if has_help else 'no'}"
    return {
        "name": "capability_surface",
        "score": round(score, 3),
        "weight": 0.075,
        "passed": True,
        "details": details,
    }


EVALS = [eval_tests, eval_lint, eval_syntax_check, eval_observability,
         eval_guard_patterns, eval_capability_surface]


def main() -> None:
    results = [fn() for fn in EVALS]
    output = {"results": results}
    json.dump(output, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
