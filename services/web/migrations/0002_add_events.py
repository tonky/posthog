# Generated PostHog Events Schema Migration
class Migration:
    operations = [
        "CREATE TABLE posthog_event (id UUID PRIMARY KEY, event VARCHAR(200), team_id INT REFERENCES posthog_team(id), timestamp TIMESTAMPTZ);",
        "CREATE INDEX idx_event_team_time ON posthog_event(team_id, timestamp);",
    ]
