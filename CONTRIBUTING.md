# Contributing

The [TDD](docs/TDD.md) and the [requirements](docs/requirements.md) are the source of truth for what we build.
If your change contradicts either one, update the document in the same PR or raise it in the issue first.

## Picking up work

- Issues are grouped by milestone (one per build phase) and labeled by area (`area: research`, `area: action`, ...).
- Assign yourself before you start, so two people don't take the same issue.
- Issues labeled `team decision` or `needs credentials` are blocked on the team, not on code.

## Branches and pull requests

- Branch from `main` as `<your-name>/<short-topic>`, for example `jeremymoon/screener`.
- Keep each PR to one issue, and put `Closes #<n>` in its description.
- `main` needs one approving review and all conversations resolved before merging.
- When your work builds on a PR that is still open, make it a stacked PR with [`gh stack`](https://gh.io/stacks) (`gh extension install github/gh-stack`):
  - `gh stack init <branch>` starts a stack on `main`; `gh stack add <branch>` adds the next layer on top.
  - `gh stack submit` pushes every branch and opens or updates the PRs, each based on the layer below.
  - After changing a lower branch, `gh stack rebase` cascades the change upward and `gh stack push` pushes the stack.
  - `gh stack sync` pulls in changes teammates pushed and keeps the stack on GitHub in step.
  - Each PR in a stack still needs its own approval.
    `gh stack merge` (or the stack merge on GitHub) lands the approved PRs together in one all-or-nothing merge.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>[optional scope]: <description>`.

| Type | Use for |
| --- | --- |
| `feat` | A new feature |
| `fix` | A bug fix |
| `refactor` | A code change that neither fixes a bug nor adds a feature |
| `test` | Adding or fixing tests |
| `docs` | Documentation only |
| `ci` | CI configuration |
| `chore` | Tooling, dependencies, and maintenance |
| `perf` | A performance improvement |
| `style` | Formatting only |

Make small, logical commits as you go rather than one commit per PR.

## Before you push

```bash
jac check .      # type-check and lint the whole project
jac test         # run every test
jac run --dev    # serve the app locally when your change touches it
```

Tests never call a real model, broker, or data provider.
Use `MockLLM` for agents and recorded fixtures for collectors, so CI stays free and deterministic.

## Writing Jac

We pin Jac 0.37.12, and much of the Jac website still describes 0.34.
Trust the guides bundled with the compiler (`jac guide`, starting with `jac guide jac-essentials`) over the website.
Read the implementation rules in [TDD §3](docs/TDD.md#jac-implementation-rules) before writing agent, endpoint, or concurrency code.
The ones that bite most often:

- Every `def:pub` function and walker must be imported by `main.jac`, or its endpoint returns 404 or 405.
- Never name a file `test_*.jac`; use `module_tests.jac` or a `module.test.jac` annex.
- Import server modules from the project root (`import from analysis.consensus { ... }`), never with `..`.
- Never touch the graph inside `flow`; write to it after `wait`.
- Give each agent role its own model instance.

## Secrets

Never commit keys, tokens, or account IDs.
`jac run` does not read `.env`, so export variables in your shell (direnv works well).
Share keys through a password manager, not in chat.

## Docs

Put each sentence of a long Markdown document on its own line, so diffs stay readable.
