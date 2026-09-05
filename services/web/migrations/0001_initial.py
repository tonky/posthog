# Generated PostHog Initial Migration
class Migration:
    operations = [
        "CREATE TABLE posthog_team (id SERIAL PRIMARY KEY, name VARCHAR(200));",
        "CREATE TABLE posthog_user (id SERIAL PRIMARY KEY, email VARCHAR(255) UNIQUE);",
    ]
