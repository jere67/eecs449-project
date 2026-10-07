"""Service health, returned to the dashboard."""
obj Health {
    has status: str,
        checked_at: str;
}

sem Health.status = "'ok' when the server is up and answering requests.";
sem Health.checked_at = "Server time of the check, ISO 8601 in UTC.";
