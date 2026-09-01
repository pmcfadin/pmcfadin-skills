# pmcfadin-skills

Agent skills by [Patrick McFadin](https://github.com/pmcfadin), packaged as
plugins for both Claude Code and Codex.

## Plugins

| Plugin | What it does |
|---|---|
| [github-coord](plugins/github-coord) | Lets a fleet of coding agents ask each other questions through GitHub issues — workers escalate ambiguous specs and blockers as issue comments with `coord:*` labels; the orchestrator sweeps, triages, and answers. |
| [tmux-lanes](plugins/tmux-lanes) | Lets a coordinating agent run real, interactive Claude Code workers itself, one per detached tmux session and git worktree — a per-lane `Stop` hook tells the lead when a worker stops talking, and a lane isn't torn down until its work is merged. |

---

# Install

Pick the section for your agent. All three approaches install the same skill
files; they differ only in who manages the copy on disk.

Plugins install one at a time — the examples below use `github-coord`; substitute
`tmux-lanes` (or run both commands) for the other.

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

cp -R plugins/tmux-lanes/skills/*   ~/.claude/skills/    # and/or this one
```

That gives you `github-coord-lead/` and `github-coord-worker/`, each carrying its
own `references/` and `scripts/coord.py`, or `tmux-lanes/` with its
`scripts/tmux-lane.sh`. Copying preserves the executable bit; if you fetch the
script some other way, `chmod +x` it — it re-executes itself to run each lane's
pane sampler. The tradeoff: no `plugin update`, so you're re-copying by hand to
get fixes.

**Don't do this *and* install the plugin.** Two registered copies of the same
skill can diverge, and the stale one may be the one that wins. Pick one.

## Requirements

Shared:

- **`gh`**, the [GitHub CLI](https://cli.github.com/), authenticated with `repo`
  scope. Check with `gh auth status`.

`github-coord` also wants **Python 3.8+** for `scripts/coord.py` — standard
library only, nothing to `pip install`. Both its skills degrade rather than fail
if the script can't be found: the protocol is plain `gh` calls, and the script is
an optimization over doing them by hand.

`tmux-lanes` needs **`tmux`** and the **`claude` CLI** on the machine running the
lanes. It autodetects `~/.local/bin/claude`; override with `TMUX_LANE_CLAUDE` if
yours lives elsewhere. `gh` is only needed for `answer`, which logs a decision on
the issue before delivering it.

## Verify the install

The real test is whether an agent picks the skill up. For `github-coord`, ask your
orchestrator something like *"check whether any agents are blocked on epic #12"* —
it should announce `github-coord-lead` and start sweeping for
`coord:needs-attention` rather than reading issues one at a time. For
`tmux-lanes`, ask it to *"run issues #12 and #14 in parallel yourself"* — it should
announce `tmux-lanes` and start lanes rather than telling you to open two windows.

`tmux-lanes` needs no repo-side setup. `github-coord` does: workers can only add
labels that already exist, so define all three in the repo you're coordinating in:

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
rm -rf ~/.claude/skills/tmux-lanes
```

`tmux-lanes` also leaves bookkeeping in `~/.claude/tmux-lane/`. Reap your lanes
before removing it — that directory is how `reap` finds each lane's worktree, and
`rm -rf` on it while lanes are live orphans both the tmux sessions and the check
that stops you destroying unmerged work.

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
claude plugin validate plugins/tmux-lanes
```

`validate_manifests.py` also checks that both marketplaces list the same plugins
and that the two `plugin.json` versions agree — otherwise an install succeeds on
one platform and silently fails on the other. It compiles every `scripts/*.py`,
runs `bash -n` over every `scripts/*.sh`, and fails a shell script that has lost
its executable bit.

To work on a skill against a live agent without publishing, point the manual
install at a symlink so your edits take effect immediately:

```sh
ln -s "$PWD/plugins/github-coord/skills/github-coord-lead" ~/.claude/skills/
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
