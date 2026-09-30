package schema

// Declarative workflow tooling linking to enve.tools and multi-tier caches
#Tool: {
	name?:     string
	packages?: [...string]
	env?: [string]: string
	cache?:    #Cache
}

// Preset tools providing zero-boilerplate defaults
#StandardTools: {
	Rust: #Tool & {
		name: "rust"
		packages: ["pkgs.rustc", "pkgs.cargo"]
		cache: {
			name: "rust-cargo"
			paths: [
				"~/.cargo/bin",
				"~/.cargo/registry/index",
				"~/.cargo/registry/cache",
				"~/.cargo/git/db",
				"target",
			]
			key: ["Cargo.lock"]
			tier:  #CacheTier.Tiered
			mode:  #CacheMode.ReadWrite
		}
	}
	Go: #Tool & {
		name: "go"
		packages: ["pkgs.go"]
		cache: {
			name: "go-modules"
			paths: [
				"~/go/pkg/mod",
				"~/.cache/go-build",
			]
			key: ["go.sum", "go.mod"]
			tier:  #CacheTier.Tiered
			mode:  #CacheMode.ReadWrite
		}
	}
	PythonUv: #Tool & {
		name: "uv"
		packages: ["pkgs.uv", "pkgs.python3"]
		cache: {
			name: "uv-cache"
			paths: [
				"~/.cache/uv",
				".venv",
			]
			key: ["uv.lock", "pyproject.toml"]
			tier:  #CacheTier.Tiered
			mode:  #CacheMode.ReadWrite
		}
	}
	NodePnpm: #Tool & {
		name: "pnpm"
		packages: ["pkgs.nodejs", "pkgs.pnpm"]
		cache: {
			name: "pnpm-store"
			paths: [
				"~/.local/share/pnpm/store",
				"node_modules",
			]
			key: ["pnpm-lock.yaml"]
			tier:  #CacheTier.Tiered
			mode:  #CacheMode.ReadWrite
		}
	}
	Oxlint: #Tool & {
		name: "oxlint"
		packages: ["pkgs.oxlint"]
	}
	Ruff: #Tool & {
		name: "ruff"
		packages: ["pkgs.ruff"]
	}
}
