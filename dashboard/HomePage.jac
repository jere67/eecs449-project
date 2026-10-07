"""Placeholder home page until the Portfolio, Today, and Decision pages land."""
import from models.health { Health }
import from run.health { health }

glob REPO_URL: str = "https://github.com/jere67/eecs449-project";

def:pub HomePage -> JsxElement {
    has status: Health | None = None,
        failed: bool = False;

    async can with entry {
        try {
            status = await health();
        } except Exception {
            failed = True;
        }
    }

    <main
        style={{
            "maxWidth": "640px",
            "margin": "0 auto",
            "padding": "4rem 1rem",
            "fontFamily": "system-ui, -apple-system, sans-serif",
            "color": "#1a1a1a",
            "lineHeight": "1.5"
        }}
    >
        <h1 style={{"fontSize": "2rem", "margin": "0 0 0.5rem"}}>Trading Agent</h1>
        <p style={{"fontSize": "1.125rem", "color": "#444", "margin": "0 0 2rem"}}>
            An AI investment committee that researches S&P 500 stocks every trading day and trades on paper.
        </p>
        <p
            style={{
                "display": "inline-block",
                "padding": "0.375rem 0.75rem",
                "borderRadius": "999px",
                "fontSize": "0.875rem",
                "backgroundColor": "#fdecea" if failed else "#eef6ee",
                "color": "#8a1c12" if failed else "#1e5b25",
                "margin": "0 0 2rem"
            }}
        >
            {"Server unreachable" if failed else (
                f"Server {status.status}, checked {status.checked_at[11:16]} UTC"
                if status else "Checking server..."
            )}
        </p>
        <p style={{"margin": "0 0 3rem"}}>
            The dashboard is under construction.
            {" "}
            <a href={REPO_URL} style={{"color": "#0b57d0"}}>Follow progress on GitHub</a>.
        </p>
        <footer
            style={{
                "borderTop": "1px solid #e5e5e5",
                "paddingTop": "1rem",
                "fontSize": "0.8125rem",
                "color": "#666"
            }}
        >
            An educational student project using simulated money.
            Nothing on this site is investment advice, and past simulated performance does not predict future results.
        </footer>
    </main>
}
