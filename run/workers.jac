"""The thread pool the run's network-bound work shares: collectors, research sub-agents,
specialist samples, and the Arbiter.

Collectors and model calls wait on the network, not the CPU. `flow`'s pool has cpu + 4
threads, which held the first research exit run to about 3.5 model requests a minute against
the limiter's 18 (docs/runs/2026-10-15-research-exit-run.md) and would hold a 2-vCPU server
to half that, so the run has its own pool, sized to keep the limiter busy while slow requests
run. The limiter and each source's token bucket still set the pace.

A task on this pool must never wait on another task on it: with every worker busy, the inner
task would never start. Callers submit flat batches and wait on the caller's thread.
Workers lose the request's graph context, so no task touches the graph (TDD §3, rule 6).
"""
import from concurrent.futures { ThreadPoolExecutor }

glob NETWORK_WORKERS: int = 32;
glob NETWORK: ThreadPoolExecutor = ThreadPoolExecutor(max_workers=NETWORK_WORKERS, thread_name_prefix="network");
