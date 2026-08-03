# pmcfadin-skills

Agent skills by [Patrick McFadin](https://github.com/pmcfadin), packaged as
plugins for both Claude Code and Codex.

## Plugins

| Plugin | What it does |
|---|---|
| [github-coord](plugins/github-coord) | Lets a fleet of coding agents ask each other questions through GitHub issues — workers escalate ambiguous specs and blockers as issue comments with `coord:*` labels; the orchestrator sweeps, triages, and answers. |

## Install

**Claude Code**

```
/plugin marketplace add pmcfadin/pmcfadin-skills
/plugin install github-coord@pmcfadin-skills
```

**Codex**

```sh
codex plugin marketplace add pmcfadin/pmcfadin-skills
codex plugin add github-coord@pmcfadin-skills
```

**Manual** — skills are plain directories with a `SKILL.md`, so any agent that
reads that format can use them:

```sh
git clone https://github.com/pmcfadin/pmcfadin-skills
cp -R pmcfadin-skills/plugins/github-coord/skills/* ~/.claude/skills/   # or ~/.codex/skills/
```

## Layout

One repo serves both platforms from the same skill files:

```
.claude-plugin/marketplace.json    Claude Code marketplace manifest
.agents/plugins/marketplace.json   Codex marketplace manifest
plugins/<plugin>/
  .claude-plugin/plugin.json       Claude Code plugin manifest
  .codex-plugin/plugin.json        Codex plugin manifest
  skills/<skill>/SKILL.md          the actual skill — read by both
tests/                             run with `python3 -m unittest discover tests`
```

## Development

```sh
python3 -m unittest discover -s tests -v   # unit tests for scripts/coord.py
python3 tests/validate_manifests.py        # manifest + skill frontmatter checks
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
