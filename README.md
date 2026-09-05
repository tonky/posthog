# PostHog Monorepo

PostHog is the open-source Product OS: analytics, session replay, feature flags, A/B testing, surveys, and data pipelines.

## Development (Upstream Setup)

### Prerequisites
- Docker & Docker Compose
- Python 3.11+
- Rust 1.80+
- Node.js & pnpm

### Starting Background Services
```bash
docker compose -f docker-compose.dev.yml up -d
```
*Note: Requires ~14 GB RAM and takes ~45-60 seconds to boot.*

### Running Migrations
```bash
python services/web/manage.py migrate
```

### Running Tests
```bash
python services/web/manage.py test
cargo test --manifest-path services/capture/Cargo.toml
```
