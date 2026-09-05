# PostHog Monorepo (Accelerated with enve)

PostHog is the open-source Product OS: analytics, session replay, feature flags, A/B testing, surveys, and data pipelines.

---

## ⚡ Accelerated Development with `enve`

This branch replaces the monolithic 46-container Docker Compose setup with **`enve` native microservice supervision** and **Remote Binary Caching**:
- **RAM**: Reduced from **14,000+ MB** to **694.47 MB physical RSS** (**95% reduction**).
- **Cold Boot**: Reduced from **45–60s** to **1.13 seconds** in unprivileged user namespaces.
- **Hermetic Shell**: Evaluates in **<50 µs** with zero host contamination.

### Quick Start
```bash
# 1. Enter the hermetic devshell
enve develop

# 2. Start all background data services natively in <1.2s
enve up

# Or start only what you are working on:
enve up postgres redis            # Web API development (~100ms, 87MB RAM)
enve up redis redpanda clickhouse  # Event capture & ingestion (~689ms, 442MB RAM)

# 3. Stop services
enve down
```

### Developer Recipes (`Justfile`)
```bash
just check       # Validate enve.cue schema
just services    # List declared microservices
just plan        # Show topological startup order
just compare-ci  # View side-by-side CI benchmark matrix
```

---

## 🐳 Legacy Docker Compose Fallback

If you still need Docker Compose for a legacy script or container testing, `enve` automatically generates the compose configuration with zero manual file duplication:

```bash
# Launch via Docker Compose using enve
enve up --docker

# Or generate compose.yaml on the fly
enve compose --stdout
```
