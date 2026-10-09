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

To record collector fixtures, export the source's API key and `COLLECTOR_RECORD_DIR=/some/dir`, then run the collector once.
Each live response is saved as `<dir>/<source>/<dataset>-<hash>.json`, with API keys sent as query parameters left out.
Trim large bodies to what the test needs, commit the files under `tests/fixtures/<source>/`, and replay them with `FakeSource` from `tests/fakes/source_server.jac`, pointing the source's base-URL variable (such as `FINNHUB_BASE_URL`) at it.

## Writing Jac

We pin Jac 0.37.12, and much of the Jac website still describes 0.34.
Trust the guides bundled with the compiler (`jac guide`, starting with `jac guide jac-essentials`) over the website.
Read the implementation rules in [TDD §3](docs/TDD.md#jac-implementation-rules) before writing agent, endpoint, or concurrency code.
The ones that bite most often:

- Every endpoint must be imported by name in `main.jac`, or it returns 404 or 405.
  Mark endpoints `def:pub` or `def:priv` (`walker:pub` or `walker:priv`) explicitly; `tests/endpoints_tests.jac` fails for any marked endpoint the server does not serve.
- Never name a file `test_*.jac`; use `module_tests.jac` or a `module.test.jac` annex.
- Import project modules from the project root (`import from analysis.consensus { ... }`), never with `..`.
  This applies to client components too: a `..` import passes `jac check` but breaks `jac build`.
- Run `jac check .`, not `jac check main.jac`; checking one file does not check the modules it imports.
- Never touch the graph inside `flow`; write to it after `wait`.
- Call models through a role instance in `agents/models.jac` (`by research_llm(...)`), never the builtin `llm`, which skips the rate limiter.
  A test fails if any module uses the builtin.
  Add a new instance for a new role rather than sharing one, since call params leak between concurrent calls on one instance.
- Fetch data through `SourceClient` in `research/collector.jac`, never with a bare HTTP call, so every request is cached, rate limited, retried, and counted against the run's budget.
  Limits, budgets, cache lifetimes, and freshness limits live in `research/sources.jac`; bump `SOURCES_VERSION` when you change them.
  Collectors return values and never touch the graph; a test fails if a module in `research/` does.

## Secrets

Never commit keys, tokens, or account IDs.
Copy `.env.example` to `.env` and fill in your keys; `.env` is gitignored.
`jac run` and `jac test` do not read `.env`, so export it into your shell with `set -a && source .env && set +a`.
With direnv, `echo dotenv > .envrc && direnv allow` does that whenever you enter the repo.
Share keys through a password manager, not in chat.

## Docs

Put each sentence of a long Markdown document on its own line, so diffs stay readable.
