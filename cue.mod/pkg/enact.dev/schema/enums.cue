package schema

// System technologies for components and runtime environments
#Technology: {
	Go:         "go"
	Rust:       "rust"
	TypeScript: "typescript"
	JavaScript: "javascript"
	Python:     "python"
	Cue:        "cue"
	Docker:     "docker"
	Infra:      "infra"
	Postgres:   "postgres"
	Redis:      "redis"
	ClickHouse: "clickhouse"
	Kafka:      "kafka"
	Protobuf:   "protobuf"
	Yaml:       "yaml"
	Playwright: "playwright"
	// Scripts and checks of no package ecosystem: no toolchain install.
	Shell: "shell"
}

// Strongly typed disjunction of supported component technologies
#TechnologyMode: #Technology.Go | #Technology.Rust | #Technology.TypeScript |
	#Technology.JavaScript | #Technology.Python | #Technology.Cue |
	#Technology.Docker | #Technology.Infra | #Technology.Postgres |
	#Technology.Redis | #Technology.ClickHouse | #Technology.Kafka |
	#Technology.Protobuf | #Technology.Yaml | #Technology.Playwright |
	#Technology.Shell


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
#ProtocolMode: #Protocol.Sql | #Protocol.Http | #Protocol.Grpc | #Protocol.Tcp |
	#Protocol.Kafka | #Protocol.Ipc | #Protocol.Redis

// Architectural C4 / LikeC4 component kind
#ComponentKind: {
	Toolchain:    "toolchain"
	Library:      "library"
	Service:      "service"
	App:          "app"
	Addon:        "addon"
	Verification: "verification"
}
#ComponentKindMode: #ComponentKind.Toolchain | #ComponentKind.Library | #ComponentKind.Service |
	#ComponentKind.App | #ComponentKind.Addon | #ComponentKind.Verification

// Service transport mode
#ServiceTransport: {
	Socket:   "socket"
	Loopback: "loopback"
}
#ServiceTransportMode: #ServiceTransport.Socket | #ServiceTransport.Loopback

// What a service is, as its `enact.kind` declares it
#ServiceKind: {
	Postgres:      "postgres"
	Redis:         "redis"
	ClickHouse:    "clickhouse"
	Kafka:         "kafka"
	Temporal:      "temporal"
	ObjectStorage: "object_storage"
	MySql:         "mysql"
	RabbitMq:      "rabbitmq"
	Elasticsearch: "elasticsearch"
	MongoDb:       "mongodb"
	Memcached:     "memcached"
	Http:          "http"
}
#ServiceKindMode: #ServiceKind.Postgres | #ServiceKind.Redis | #ServiceKind.ClickHouse |
	#ServiceKind.Kafka | #ServiceKind.Temporal | #ServiceKind.ObjectStorage |
	#ServiceKind.MySql | #ServiceKind.RabbitMq | #ServiceKind.Elasticsearch |
	#ServiceKind.MongoDb | #ServiceKind.Memcached | #ServiceKind.Http

// Service deployment topology / placement
#ServicePlacement: {
	Shared:   "shared"
	Isolated: "isolated"
}
#ServicePlacementMode: #ServicePlacement.Shared | #ServicePlacement.Isolated

// Runner platform architectures
#Platform: {
	LinuxAmd64:  "linux/amd64"
	LinuxArm64:  "linux/arm64"
	DarwinArm64: "darwin/arm64"
	DarwinAmd64: "darwin/amd64"
}
#PlatformMode: #Platform.LinuxAmd64 | #Platform.LinuxArm64 | #Platform.DarwinArm64 | #Platform.DarwinAmd64

// Service process restart policies
#RestartPolicy: {
	Always:    "always"
	OnFailure: "on_failure"
	Never:     "never"
}
#RestartPolicyMode: #RestartPolicy.Always | #RestartPolicy.OnFailure | #RestartPolicy.Never

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

// Workflow execution layout orchestration
#WorkflowLayout: {
	Staged: "staged"
	Static: "static"
}
#WorkflowLayoutMode: #WorkflowLayout.Staged | #WorkflowLayout.Static

// Sharding strategies
#ShardingSpec: "auto" | int & >0

// Targets packed into shards group by group, for a runner that starts one process per
// group: a group stays in one shard unless it is bigger than a fair share.
#ShardGroups: {
	// A target's group: its leading path segments matching these (`*` within a segment),
	// e.g. "pkgs/*/" groups `pkgs/a/tests/test_x.py` as `pkgs/a`. Unmatched targets share one.
	by: string
	// Seconds each group costs a shard beyond its targets' (its process's startup).
	overhead_s?: number & >=0
}

// How a recording run gets footprints of a job's tests. "own": the job's commands run a
// recorder of their own, writing reach maps to $ENACT_FOOTPRINT_DIR. "own_linux": so do
// they, on Linux only (a recorder tracing through `enact trace run`, eBPF). "trace": `enact trace
// record`/`sample` trace each test in a run of the command of its own, given only that test
// (Linux eBPF; a command taking targets), with the job's services as its own; a
// recording `enact run` does so for a few of its wanted tests per shard (untraced, aged,
// incomplete or reached) and runs the others together, as usual. Unset: the job records
// nothing, so `reach record`/`sample` refuse it and `reach stale` says its tests can't be
// traced.
#Recorder: "own" | "own_linux" | "trace" | "vitest" | "playwright" | "pytest" | "cargo" | "go" | "jest"

// Workflow component scoping strategies
#WorkflowScopeStrategy: {
	Affected: "affected"
	All:      "all"
}
#WorkflowScopeStrategyMode: #WorkflowScopeStrategy.Affected | #WorkflowScopeStrategy.All

// Service lifecycle and provisioning policy
#ServicePolicy: {
	OnDemand: "on_demand"
	Disabled: "disabled"
}
#ServicePolicyMode: #ServicePolicy.OnDemand | #ServicePolicy.Disabled

// Concurrency grouping scope
#ConcurrencyScope: {
	Branch:   "branch"
	Commit:   "commit"
	Workflow: "workflow"
}
#ConcurrencyScopeMode: #ConcurrencyScope.Branch | #ConcurrencyScope.Commit | #ConcurrencyScope.Workflow

// SemVer specification regex pattern
#SemVer: =~"^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$"

// Common version alias
#VersionAlias: {
	Latest:          "latest"
	OldestSupported: "oldest_supported"
	Default:         "default"
}
#VersionAliasMode: #VersionAlias.Latest | #VersionAlias.OldestSupported | #VersionAlias.Default
#VersionSpec:      #SemVer | #VersionAliasMode | string

// Pull request event actions
#PullRequestAction: {
	Opened:      "opened"
	Synchronize: "synchronize"
	Reopened:    "reopened"
	Closed:      "closed"
	Labeled:     "labeled"
}
#PullRequestActionMode: #PullRequestAction.Opened | #PullRequestAction.Synchronize |
	#PullRequestAction.Reopened | #PullRequestAction.Closed | #PullRequestAction.Labeled
#PullRequestDefaultActions: [#PullRequestAction.Opened, #PullRequestAction.Synchronize, #PullRequestAction.Reopened]

// Empty target/file evaluation policy for steps
#EmptyPolicy: {
	Skip:   "skip"
	Pass:   "pass"
	Fail:   "fail"
	RunAll: "run_all"
}
#EmptyPolicyMode: #EmptyPolicy.Skip | #EmptyPolicy.Pass | #EmptyPolicy.Fail | #EmptyPolicy.RunAll

// Cache storage hierarchy
#CacheTier: {
	L1Only: "l1_only"
	L2Only: "l2_only"
	Tiered: "tiered"
}
#CacheTierMode: #CacheTier.L1Only | #CacheTier.L2Only | #CacheTier.Tiered

// Cache mutation mode
#CacheMode: {
	ReadOnly:  "read_only"
	ReadWrite: "read_write"
}
#CacheModeValue: #CacheMode.ReadOnly | #CacheMode.ReadWrite

// Remote cache storage: an S3-compatible bucket signed for region `auto` (Cloudflare R2)
#RemoteCacheBackend: {
	S3R2: "s3-r2"
}
#RemoteCacheBackendMode: #RemoteCacheBackend.S3R2

// Selector target granularity
#TargetGranularity: {
	Item: "item"
	File: "file"
}
#TargetGranularityMode: #TargetGranularity.Item | #TargetGranularity.File

// Selector fallback strategy
#SelectorFallback: {
	All:  "all"
	None: "none"
}
#SelectorFallbackMode: #SelectorFallback.All | #SelectorFallback.None

// Shell interpreter
#Shell: {
	Bash:   "bash"
	Sh:     "sh"
	Pwsh:   "pwsh"
	Python: "python"
	Node:   "node"
}
#ShellMode: #Shell.Bash | #Shell.Sh | #Shell.Pwsh | #Shell.Python | #Shell.Node

// How a CI worker is provisioned: dedicated (standing, never reclaimed), on_demand
// (booted per job) or spot (reclaimable after a notice window)
#WorkerTier: {
	Dedicated: "dedicated"
	OnDemand:  "on_demand"
	Spot:      "spot"
}
#WorkerTierMode: #WorkerTier.Dedicated | #WorkerTier.OnDemand | #WorkerTier.Spot

// Hardware GPU compute tiers
#GpuTier: {
	None: "none"
	T4:   "nvidia-t4"
	A10g: "nvidia-a10g"
	A100: "nvidia-a100"
	H100: "nvidia-h100"
}
#GpuTierMode: #GpuTier.None | #GpuTier.T4 | #GpuTier.A10g | #GpuTier.A100 | #GpuTier.H100

// Standard runner preset tiers (GitHub Actions cloud, AWS/GCP on-demand, self-hosted bare metal)
#RunnerPreset: {
	GithubPublic:       "github-public"
	GithubPrivate:      "github-private"
	CloudMedium:        "cloud-medium"
	CloudLarge:         "cloud-large"
	CloudXlarge:        "cloud-xlarge"
	SelfHostedStandard: "self-hosted-standard"
	SelfHostedLarge:    "self-hosted-large"
	SelfHostedBeast:    "self-hosted-beast"
}
#RunnerPresetMode: #RunnerPreset.GithubPublic | #RunnerPreset.GithubPrivate |
	#RunnerPreset.CloudMedium | #RunnerPreset.CloudLarge | #RunnerPreset.CloudXlarge |
	#RunnerPreset.SelfHostedStandard | #RunnerPreset.SelfHostedLarge | #RunnerPreset.SelfHostedBeast


// A runner's CPU architecture.
#Arch: "x86_64" | "aarch64"

// The CPU architecture a job's runner must have, or `any` (portable).
#JobArch: #Arch | "any"

// Ordering of targets when partitioning across shards.
#ShardOrder: *"balanced" | "contiguous"
