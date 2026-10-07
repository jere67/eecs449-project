"""Endpoint smoke tests: every declared endpoint is served, and health answers."""
import re;
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent;
glob SKIP_DIRS: set[str] = {".git", ".jac", "dist", "node_modules", "tests"};
glob FUNCTION_DECL: re.Pattern[str] = re.compile(r"def:(?:pub|priv)\s+(\w+)([^{;]*)");
glob WALKER_DECL: re.Pattern[str] = re.compile(r"walker:(?:pub|priv)\s+(\w+)");

"""Names of the functions and walkers marked :pub or :priv in the source, skipping client components."""
def declared_endpoints -> tuple[set[str], set[str]] {
    functions: set[str] = set();
    walkers: set[str] = set();
    for path in PROJECT_ROOT.rglob("*.jac") {
        if SKIP_DIRS & set(path.relative_to(PROJECT_ROOT).parts) {
            continue;
        }
        source = path.read_text();
        for found in FUNCTION_DECL.finditer(source) {
            if "JsxElement" not in found.group(2) {
                functions.add(found.group(1));
            }
        }
        for found in WALKER_DECL.finditer(source) {
            walkers.add(found.group(1));
        }
    }
    return (functions, walkers);
}

def start_client -> JacTestClient {
    return JacTestClient.from_file(
        str(PROJECT_ROOT / "main.jac"), base_path=tempfile.mkdtemp()
    );
}

test "endpoint discovery finds the health endpoint" {
    (functions, _) = declared_endpoints();
    assert "health" in functions;
    assert "HomePage" not in functions;
}

test "every declared endpoint is served" {
    (functions, walkers) = declared_endpoints();
    client = start_client();
    try {
        served_functions = set(client.get("/functions").json()["data"]["functions"]);
        served_walkers = set(client.get("/walkers").json()["data"]["walkers"]);
    } finally {
        client.close();
    }
    missing = sorted(functions - served_functions) + sorted(walkers - served_walkers);
    assert not missing, f"Not served: {missing}. Import each one by name in main.jac (TDD §3, rule 7).";
}

test "health answers ok with a UTC timestamp" {
    client = start_client();
    try {
        resp = client.post("/function/health", json={});
    } finally {
        client.close();
    }
    assert resp.status_code == 200;
    result = resp.json()["data"]["result"];
    assert result["status"] == "ok";
    assert result["checked_at"].endswith("+00:00");
}
