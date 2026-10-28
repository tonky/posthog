package replay

pipeline: ci: remote_cache: {
	secrets: {
		bucket:            "R2_BUCKET"
		access_key_id:     "R2_ACCESS_KEY_ID"
		secret_access_key: "R2_SECRET_ACCESS_KEY"
	}
	public_url: "https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev"
	public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
}

// Admit only a bounded plan before CI allocates its matrix.
pipeline: ci: budget: {
	enforce:        true
	untraced_tests: 10
	wall_minutes:   30
}
