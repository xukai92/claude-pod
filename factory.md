# Factory Configuration

## Goal

A Podman wrapper CLI for running Claude Code in rootless container sandboxes with secure host-mount management.

## Scope

### Modifiable

- claude-pod.py
- claude-pod
- entrypoint.sh
- Containerfile
- test_python.sh
- tests/**/*
- fixtures/**/*
- eval/**/*
- factory.md

### Read-only

- README.md
- CLAUDE.md
- .github/**/*

## Guards

- Do not delete or overwrite existing tests
- Do not modify files outside the declared scope
- Do not introduce secrets or credentials into the repository
- Do not modify eval/score.py or .factory/

## Eval

### Command

```bash
python3 eval/score.py
```

### Threshold

0.5

## Target Branch

main

## Smoke Test

```bash
python3 claude-pod.py --help
```

## Constraints

- Prefer small, incremental changes over large rewrites
- Each change should be accompanied by at least one test
- Follow the existing code style and conventions
- Bump VERSION in claude-pod for user-facing changes
