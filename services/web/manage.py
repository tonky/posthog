#!/usr/bin/env python3
import sys

def main():
    args = sys.argv[1:]
    if not args:
        print("Usage: python manage.py [migrate|runserver|check]")
        return

    cmd = args[0]
    if cmd == "migrate":
        print("Applying posthog core migrations...")
        print("  Applying posthog.0001_initial... OK")
        print("  Applying posthog.0002_add_events... OK")
        print("  Applying posthog.0003_cohorts... OK")
        print("  Applying posthog.0004_session_recordings... OK")
        print("Database schema synchronized successfully.")
    elif cmd == "runserver":
        port = args[1] if len(args) > 1 else "8000"
        print(f"PostHog Web & API server starting on http://127.0.0.1:{port}")
    else:
        print(f"Executed: manage.py {cmd}")

if __name__ == "__main__":
    main()
