package schema

// System technologies for components and runtime environments
#Technology: {
	Go:         "go"
	Rust:       "rust"
	TypeScript: "typescript"
	Python:     "python"
	Docker:     "docker"
	Infra:      "infra"
	Postgres:   "postgres"
	Redis:      "redis"
	ClickHouse: "clickhouse"
	Kafka:      "kafka"
}

// Communication & architectural protocols for component relationships
#Protocol: {
	Sql:   "sql"
	Http:  "http"
	Grpc:  "grpc"
	Tcp:   "tcp"
	Kafka: "kafka"
	Ipc:   "ipc"
	Redis: "redis"
}

// Service transport mode
#ServiceTransport: {
	Socket:   "socket"
	Loopback: "loopback"
}
#ServiceTransportMode: #ServiceTransport.Socket | #ServiceTransport.Loopback

// Service deployment topology / placement
#ServicePlacement: {
	Shared:   "shared"
	Isolated: "isolated"
}
#ServicePlacementMode: #ServicePlacement.Shared | #ServicePlacement.Isolated

// External runner computing tiers
#RunnerTier: {
	Standard:   "standard"
	Large4Cpu:  "large-4cpu"
	Large8Cpu:  "large-8cpu"
	Large16Cpu: "large-16cpu"
	Gpu:        "gpu"
}
#RunnerTierMode: #RunnerTier.Standard | #RunnerTier.Large4Cpu | #RunnerTier.Large8Cpu |
	#RunnerTier.Large16Cpu | #RunnerTier.Gpu

// Runner target execution environment
#RunnerTarget: {
	Local:        "local"
	GithubRunner: "github-runner"
	RemoteWorker: "remote-worker"
}
#RunnerTargetMode: #RunnerTarget.Local | #RunnerTarget.GithubRunner | #RunnerTarget.RemoteWorker

// Runner platform architectures
#Platform: {
	LinuxAmd64:  "linux/amd64"
	LinuxArm64:  "linux/arm64"
	DarwinArm64: "darwin/arm64"
	DarwinAmd64: "darwin/amd64"
}
#PlatformMode: #Platform.LinuxAmd64 | #Platform.LinuxArm64 | #Platform.DarwinArm64 | #Platform.DarwinAmd64

// Runner allocation kinds
#RunnerKind: {
	Internal: "internal"
	External: "external"
	Auto:     "auto"
}
#RunnerKindMode: #RunnerKind.Internal | #RunnerKind.External | #RunnerKind.Auto

// Service process restart policies
#RestartPolicy: {
	Always:    "always"
	OnFailure: "on_failure"
	Never:     "never"
}
#RestartPolicyMode: #RestartPolicy.Always | #RestartPolicy.OnFailure | #RestartPolicy.Never

// Database schema migration engines
#MigrationEngine: {
	Django:     "django"
	ClickHouse: "clickhouse"
	Sqlx:       "sqlx"
	Flyway:     "flyway"
	Alembic:    "alembic"
	Prisma:     "prisma"
}
#MigrationEngineMode: #MigrationEngine.Django | #MigrationEngine.ClickHouse |
	#MigrationEngine.Sqlx | #MigrationEngine.Flyway | #MigrationEngine.Alembic | #MigrationEngine.Prisma

// GitHub Actions Problem Matcher presets
#ProblemMatcher: {
	Cargo:      "cargo"
	Mypy:       "mypy"
	Ruff:       "ruff"
	Oxlint:     "oxlint"
	Eslint:     "eslint"
	Stylelint:  "stylelint"
	Actionlint: "actionlint"
	Shellcheck: "shellcheck"
	Go:         "go"
	Vitest:     "vitest"
}
#ProblemMatcherMode: #ProblemMatcher.Cargo | #ProblemMatcher.Mypy | #ProblemMatcher.Ruff |
	#ProblemMatcher.Oxlint | #ProblemMatcher.Eslint | #ProblemMatcher.Stylelint |
	#ProblemMatcher.Actionlint | #ProblemMatcher.Shellcheck | #ProblemMatcher.Go | #ProblemMatcher.Vitest

// Multi-level test and blast radius scoping selectors
#ScopingSelector: {
	PythonSnob:    "python-snob"
	JestRelated:   "jest-related"
	VitestRelated: "vitest-related"
	GoDeps:        "go-deps"
	CargoMetadata: "cargo-metadata"
	Glob:          "glob"
}
#ScopingSelectorMode: #ScopingSelector.PythonSnob | #ScopingSelector.JestRelated |
	#ScopingSelector.VitestRelated | #ScopingSelector.GoDeps | #ScopingSelector.CargoMetadata |
	#ScopingSelector.Glob

// Pipeline task phase categories
#TaskPhase: {
	Lint:      "lint"
	Fmt:       "fmt"
	Typecheck: "typecheck"
	Audit:     "audit"
	Build:     "build"
	Test:      "test"
	Codegen:   "codegen"
	Contract:  "contract"
	Migration: "migration"
}
#TaskPhaseMode: #TaskPhase.Lint | #TaskPhase.Fmt | #TaskPhase.Typecheck | #TaskPhase.Audit |
	#TaskPhase.Build | #TaskPhase.Test | #TaskPhase.Codegen | #TaskPhase.Contract | #TaskPhase.Migration

// Verification test execution categories
#TestType: {
	Unit:        "unit"
	Integration: "integration"
	E2E:         "e2e"
	Smoke:       "smoke"
	Benchmark:   "benchmark"
}
#TestTypeMode: #TestType.Unit | #TestType.Integration | #TestType.E2E | #TestType.Smoke | #TestType.Benchmark
