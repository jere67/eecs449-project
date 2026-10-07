"""run.public through a real server: granted team-graph nodes are readable by everyone else."""
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "public_app.jac");
glob PUBLIC_VIEW: list[str] = ["portfolio:team", "run:2026-10-06", "coverage:AAPL"];

test "published nodes are readable anonymously and by other users, unpublished ones are not" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        client.register_user("writer", "writer-password-1");
        assert client.post("/function/seed_team_graph", json={}).ok;
        writer_view = client.post("/function/read_team_graph", json={}).json()["data"]["result"];

        client.clear_auth();
        anonymous_view = client.post("/function/read_team_graph", json={}).json()["data"]["result"];

        client.register_user("reader", "reader-password-1");
        reader_view = client.post("/function/read_team_graph", json={}).json()["data"]["result"];
    } finally {
        client.close();
    }
    assert writer_view == PUBLIC_VIEW + ["coverage:PRIVATE"];
    assert anonymous_view == PUBLIC_VIEW;
    assert reader_view == PUBLIC_VIEW;
}

test "anonymous readers receive stored research with its typed report embedded" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        client.register_user("writer", "writer-password-1");
        assert client.post("/function/seed_team_graph", json={}).ok;
        client.clear_auth();
        records = client.post("/function/read_research", json={}).json()["data"]["result"];
    } finally {
        client.close();
    }
    assert len(records) == 1;
    assert records[0]["domain"] == "fundamentals";
    assert records[0]["body"]["view"] == "BUY";
    assert records[0]["body"]["evidence"][0]["source_url"] == "https://www.sec.gov/x";
}
