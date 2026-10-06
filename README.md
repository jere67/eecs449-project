# Trading Agent

A Jac multi-agent system that screens the S&P 500 every trading day, researches a shortlist from free data sources, decides through a stochastic consensus of specialist agents, and trades on Alpaca paper accounts.
Every report, vote, decision, risk check, and order is logged and shown on a public dashboard.

EECS 449, Fall 2026.
An educational project using simulated money; nothing here is investment advice.

## Documents

- [Technical design document](docs/TDD.md): architecture, data sources, agents, risk controls, and the build plan.
- [Requirements](docs/requirements.md): what the system must do, and the open knowledge gaps.
- [Contributing](CONTRIBUTING.md): how we branch, commit, review, and write Jac.

Work is tracked in [issues](https://github.com/jere67/eecs449-project/issues), grouped into one milestone per build phase.

## Quickstart

Install Jac 0.37.12, the version this project pins:

```bash
curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash -s -- --version 0.37.12
jac --version
```

Then, from the repo root:

```bash
cp .envrc.example .envrc   # fill in keys, then `direnv allow` (or export them yourself)
jac install                # Python and npm dependencies
jac run                    # serves the app with hot reload at http://localhost:8000
```

`GET /healthz` and `POST /function/health` answer once the server is up, and `/docs` lists every endpoint.

## Checks

```bash
jac check .   # type-check and lint the whole project
jac test      # every test, colocated and in tests/
jac build     # the production bundle, dist/trading-agent.jab
```

`jac check .` prints "may be undefined" warnings for JSX tags and "never used" warnings for component state setters.
These are false positives from checking client modules in isolation in Jac 0.37.12; the same warnings appear in a fresh `jac create` scaffold.

## Layout

The layout follows [TDD §3](docs/TDD.md#repository-layout).
Module paths that declare node types are frozen once data is stored, because moving them strands stored rows.

```
main.jac        server entry; imports every endpoint by name
models/         node, edge, obj, and enum definitions; no server-only imports
agents/         role model instances, Orchestrator, research sub-agents, specialists, Arbiter
research/       data collectors and the S&P 500 screener
analysis/       indicators and the consensus engine
action/         sizing, risk gate, executor
run/            daily run walker, Run Guard, scheduled jobs, health
dashboard/      client pages and components
assets/         static files served at /static/assets/
tests/          integration and smoke tests, fixtures, fakes
docs/           design documents and spike findings
```

Folders appear as their first module lands.
