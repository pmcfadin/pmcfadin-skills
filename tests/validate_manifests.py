#!/usr/bin/env python3
"""Check the repo's manifests and skills before publishing.

A broken manifest fails at install time on someone else's machine, which is the
worst place to find out. This runs in CI and locally with no dependencies.

Usage: python3 tests/validate_manifests.py
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors = []


def err(msg):
    errors.append(msg)


def load_json(rel):
    p = ROOT / rel
    if not p.exists():
        err(f"missing {rel}")
        return None
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        err(f"{rel}: invalid JSON: {e}")
        return None


def frontmatter(path):
    """Parse the YAML frontmatter block without a yaml dependency."""
    text = path.read_text()
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end == -1:
        return None
    out, key = {}, None
    for line in text[4:end].splitlines():
        if line[:1] not in (" ", "\t") and ":" in line:
            key, _, val = line.partition(":")
            key = key.strip()
            out[key] = val.strip()
        elif key and line.strip():
            out[key] += " " + line.strip()
    return out


claude_mp = load_json(".claude-plugin/marketplace.json")
codex_mp = load_json(".agents/plugins/marketplace.json")

claude_names, codex_names = set(), set()

if claude_mp:
    for p in claude_mp.get("plugins", []):
        claude_names.add(p.get("name"))
        src = ROOT / p.get("source", "")
        if not src.is_dir():
            err(f"claude marketplace: source not found for {p.get('name')}: {p.get('source')}")

if codex_mp:
    for p in codex_mp.get("plugins", []):
        codex_names.add(p.get("name"))
        path = (p.get("source") or {}).get("path", "")
        if not (ROOT / path).is_dir():
            err(f"codex marketplace: path not found for {p.get('name')}: {path}")

if claude_names != codex_names:
    err(
        "the two marketplaces list different plugins -- an install works on one "
        f"platform and not the other. claude={sorted(claude_names)} codex={sorted(codex_names)}"
    )

for plugin_dir in sorted((ROOT / "plugins").iterdir()):
    if not plugin_dir.is_dir():
        continue
    name = plugin_dir.name
    rel = plugin_dir.relative_to(ROOT)

    if name not in claude_names:
        err(f"plugins/{name} exists but is not listed in .claude-plugin/marketplace.json")
    if name not in codex_names:
        err(f"plugins/{name} exists but is not listed in .agents/plugins/marketplace.json")

    versions = {}
    for mf in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json"):
        data = load_json(rel / mf)
        if data is None:
            continue
        if data.get("name") != name:
            err(f"{rel}/{mf}: name is {data.get('name')!r}, expected {name!r}")
        for field in ("description", "version", "license", "repository"):
            if not data.get(field):
                err(f"{rel}/{mf}: missing {field}")
        versions[mf] = data.get("version")
    if len(set(versions.values())) > 1:
        err(f"{rel}: plugin.json versions disagree: {versions}")

    skills = sorted((plugin_dir / "skills").glob("*/SKILL.md"))
    if not skills:
        err(f"{rel}: no skills/*/SKILL.md found")
    for sk in skills:
        srel = sk.relative_to(ROOT)
        fm = frontmatter(sk)
        if fm is None:
            err(f"{srel}: no YAML frontmatter block")
            continue
        if fm.get("name") != sk.parent.name:
            err(f"{srel}: frontmatter name {fm.get('name')!r} != directory {sk.parent.name!r}")
        desc = fm.get("description", "")
        if len(desc) < 40:
            err(f"{srel}: description is too short to trigger reliably ({len(desc)} chars)")
        lines = len(sk.read_text().splitlines())
        if lines > 500:
            err(f"{srel}: {lines} lines exceeds the 500-line SKILL.md guideline")

    for script in plugin_dir.rglob("scripts/*.py"):
        try:
            compile(script.read_text(), str(script), "exec")
        except SyntaxError as e:
            err(f"{script.relative_to(ROOT)}: syntax error: {e}")

if errors:
    print(f"FAIL ({len(errors)} problem(s)):")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print("OK: manifests, skill frontmatter, and scripts all valid")
