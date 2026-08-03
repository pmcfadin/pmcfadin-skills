# pmcfadin-skills

Agent skills by [Patrick McFadin](https://github.com/pmcfadin), packaged as
plugins for both Claude Code and Codex.

## Plugins

| Plugin | What it does |
|---|---|
| [github-coord](plugins/github-coord) | Lets a fleet of coding agents ask each other questions through GitHub issues — workers escalate ambiguous specs and blockers as issue comments with `coord:*` labels; the orchestrator sweeps, triages, and answers. |

---

# Install

Pick the section for your agent. All three approaches install the same skill
files; they differ only in who manages the copy on disk.

## Claude Code

Inside a session, using slash commands:

```
/plugin marketplace add pmcfadin/pmcfadin-skills
/plugin install github-coord@pmcfadin-skills
```

Or from your shell, which is handy for scripting a new machine:

```sh
claude plugin marketplace add pmcfadin/pmcfadin-skills
claude plugin install github-coord@pmcfadin-skills
```

Either way you should see:

```
✔ Successfully added marketplace: pmcfadin-skills (declared in user settings)
✔ Successfully installed plugin: github-coord@pmcfadin-skills (scope: user)
```

Confirm it registered, and see what it costs you in context:

```sh
claude plugin list
claude plugin details github-coord@pmcfadin-skills
```

Restart the session to load it. The skills then trigger on their own when a task
matches — you don't invoke them by name.

## Codex

```sh
codex plugin marketplace add pmcfadin/pmcfadin-skills
codex plugin add github-coord@pmcfadin-skills
```

Note it's `plugin add`, not `plugin install`. Expect:

```
Added marketplace `pmcfadin-skills` from https://github.com/pmcfadin/pmcfadin-skills.git.
Added plugin `github-coord` from marketplace `pmcfadin-skills`.
```

Confirm:

```sh
codex plugin list | grep github-coord
# github-coord@pmcfadin-skills  installed, enabled  0.1.0  ...
```

## Manual

Skills are plain directories containing a `SKILL.md`, so any agent that reads
that format can use them — Claude Code, Codex, or something else. Copy them in
directly:

```sh
git clone https://github.com/pmcfadin/pmcfadin-skills
cd pmcfadin-skills

cp -R plugins/github-coord/skills/* ~/.claude/skills/    # Claude Code
cp -R plugins/github-coord/skills/* ~/.codex/skills/     # Codex
```

That gives you `github-coord-lead/` and `github-coord-worker/`, each carrying its
own `references/` and `scripts/coord.py`. The tradeoff: no `plugin update`, so
you're re-copying by hand to get fixes.

**Don't do this *and* install the plugin.** Two registered copies of the same
skill can diverge, and the stale one may be the one that wins. Pick one.

## Requirements

- **`gh`**, the [GitHub CLI](https://cli.github.com/), authenticated with `repo`
  scope. Check with `gh auth status`.
- **Python 3.8+** for `scripts/coord.py` — standard library only, nothing to
  `pip install`.

Both skills degrade rather than fail if `coord.py` can't be found: the protocol
is plain `gh` calls, and the script is an optimization over doing them by hand.

## Verify the install

The real test is whether an agent picks the skill up. Ask your orchestrator
something like *"check whether any agents are blocked on epic #12"* — it should
announce `github-coord-lead` and start sweeping for `coord:needs-attention`
rather than reading issues one at a time.

Before that, one repo-side setup step is needed. Workers can only add labels that
already exist, so define all three in the repo you're coordinating in:

```sh
R=owner/name
gh label create "coord:needs-attention" --repo $R --color D93F0B \
  --description "Unresolved agent request awaiting the orchestrator"
gh label create "coord:blocked" --repo $R --color B60205 \
  --description "Issue cannot make dependency-safe progress"
gh label create "coord:follow-up-proposed" --repo $R --color 0E8A16 \
  --description "Proposed follow-up issue awaiting disposition"
```

## Update

```sh
claude plugin marketplace update pmcfadin-skills   # refresh the catalog
claude plugin update github-coord@pmcfadin-skills  # restart required to apply

codex plugin marketplace upgrade                   # refresh Git snapshots
```

## Uninstall

```sh
claude plugin uninstall github-coord@pmcfadin-skills
claude plugin marketplace remove pmcfadin-skills

codex plugin remove github-coord@pmcfadin-skills
codex plugin marketplace remove pmcfadin-skills

rm -rf ~/.claude/skills/github-coord-{lead,worker}   # if you installed manually
```

---

## Repo layout

One repo serves both platforms from the same skill files — only the manifests
differ:

```
.claude-plugin/marketplace.json    Claude Code marketplace
.agents/plugins/marketplace.json   Codex marketplace
plugins/<plugin>/
  .claude-plugin/plugin.json       Claude Code plugin manifest
  .codex-plugin/plugin.json        Codex plugin manifest
  skills/<skill>/
    SKILL.md                       the skill itself — read by both platforms
    references/                    detail loaded only when needed
    scripts/                       helpers the skill shells out to
tests/
```

## Development

```sh
python3 tests/validate_manifests.py         # manifests, frontmatter, script syntax
python3 -m unittest discover -s tests -v    # unit tests for coord.py
claude plugin validate .                    # official marketplace manifest check
claude plugin validate plugins/github-coord # official plugin manifest check
```

`validate_manifests.py` also checks that both marketplaces list the same plugins
and that the two `plugin.json` versions agree — otherwise an install succeeds on
one platform and silently fails on the other.

To work on a skill against a live agent without publishing, point the manual
install at a symlink so your edits take effect immediately:

```sh
ln -s "$PWD/plugins/github-coord/skills/github-coord-lead" ~/.claude/skills/
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
