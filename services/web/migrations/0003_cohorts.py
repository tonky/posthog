# Generated PostHog Cohorts Schema Migration
class Migration:
    operations = [
        "CREATE TABLE posthog_cohort (id SERIAL PRIMARY KEY, name VARCHAR(200), team_id INT REFERENCES posthog_team(id), is_static BOOLEAN);",
    ]
