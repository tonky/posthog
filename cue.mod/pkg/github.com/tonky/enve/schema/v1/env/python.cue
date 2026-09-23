package env

// -------------------------------------------------------------
// Python Environment Schema (Strictly Typed)
// -------------------------------------------------------------

// Usage: env.#Python or env.#Python & { PYTHONUNBUFFERED: 1 }
// A version is data, and it belongs on the package: `tools: [pkgs.python3 & {version: "3.12"}]`.
#Python: {
	PYTHONUNBUFFERED?:        0 | 1 | *1
	PYTHONDONTWRITEBYTECODE?: 0 | 1 | *1
	[string]:                 _
}
