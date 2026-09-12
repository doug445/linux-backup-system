# Rulesets

The branch and tag protection for this repository, as JSON rather than as
settings someone clicked once and cannot reproduce.

Apply or re-apply:

```bash
gh api --method POST repos/doug445/linux-backup-system/rulesets --input .github/rulesets/branch-main.json
gh api --method POST repos/doug445/linux-backup-system/rulesets --input .github/rulesets/tags-release.json
```

List what is live, and read one back:

```bash
gh api repos/doug445/linux-backup-system/rulesets --jq '.[] | "\(.id)  \(.name)  [\(.target)]  \(.enforcement)"'
gh api repos/doug445/linux-backup-system/rulesets/RULESET_ID --jq '.rules'
```

## What is enforced

**`branch-main.json`** — the default branch:

| Rule | Effect |
|---|---|
| `deletion` | `main` cannot be deleted |
| `non_fast_forward` | no force-pushing `main`; history cannot be rewritten |
| `required_status_checks` | a pull request merges into `main` only when the five CI jobs in `lint.yml` have passed: `bash -n + shellcheck (warning severity)`, `ruff + compile (python tools)`, `SPDX header in every script`, `tests (ubuntu-latest)`, `tests (ubuntu-24.04-arm)`. Not strict (the branch need not be up to date), and not enforced on branch creation |

The status-check rule exists for contributors: this project asks for setup
patches, and a patch that does not pass what CI runs must not merge. The
contexts are the job `name:` values in `.github/workflows/lint.yml` — rename a
job there and rename it here in the same commit, or every pull request waits
for a check that never runs.

**`tags-release.json`** — every tag matching `v*`:

| Rule | Effect |
|---|---|
| `deletion` | a published version tag cannot be removed |
| `update` | a version tag cannot be moved to another commit |
| `non_fast_forward` | no force-pushing a tag over an existing one |

Creating *new* `v*` tags is unaffected — that is the `creation` rule, which is
deliberately not enabled.

## What is deliberately not enforced

This is a small repository with direct pushes to `main`. Rules that assume a
pull-request workflow would break it for no gain:

- **`pull_request`** — would forbid pushing to `main` at all. Contributors
  arrive by pull request anyway; the maintainer pushes directly.
- **`required_signatures`** — commits here are not GPG-signed, so this would
  reject every push, including your own.
- **`required_linear_history`** — would block merge commits. Dependabot's grouped
  pull request merges cleanly by squash, but this rule turns an ordinary "Merge"
  click into a confusing failure.

## Bypass, and getting unstuck

`bypass_actors` names the repository admin role (`actor_id` 5) with
`bypass_mode: always`. That is what lets the maintainer push straight to
`main` past the status-check rule; GitHub reports it on every such push as
`Bypassed rule violations for refs/heads/main`. It also means `deletion` and
`non_fast_forward` do not bind the admin — the tag ruleset has no bypass and
does bind everyone.

Nothing is locked: as an admin you can set a ruleset to `disabled`, do the
thing, and set it back.

Send the **whole** ruleset body, not just the changed field — `PUT` replaces the
ruleset, so a partial update silently drops the rules:

```bash
ID=$(gh api repos/doug445/linux-backup-system/rulesets --jq '.[] | select(.name=="release tags") | .id')

jq '.enforcement = "disabled"' .github/rulesets/tags-release.json > /tmp/off.json
gh api --method PUT "repos/doug445/linux-backup-system/rulesets/$ID" --input /tmp/off.json

# ... do the thing ...

gh api --method PUT "repos/doug445/linux-backup-system/rulesets/$ID" --input .github/rulesets/tags-release.json
```

Confirm the rules survived, every time:

```bash
gh api "repos/doug445/linux-backup-system/rulesets/$ID" --jq '.enforcement, (.rules|map(.type))'
```

## Status

**Applied to this repository on 2026-09-12**, the day it went public, with the
two `POST` commands above. The rule bodies are the ones live on the sibling
repositories (LinuxLocker, AsahiLocker, Panoptes), where the behaviour was
tested on 2026-08-23: pushing a new `v*` tag succeeded, deleting it was
rejected with `GH013: Repository rule violations found`, and an ordinary
fast-forward push to `main` was unaffected.
