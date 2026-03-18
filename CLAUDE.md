# Project Guidelines

## Commit Convention

**Every commit must:**
- Use `git commit -s` (adds `Signed-off-by` trailer automatically)
- Include `Assisted-by: AI` as a footer line in the commit message body
- NOT include `Co-authored-by: Claude ...` or any Anthropic attribution footer

**Format:**
```
<type>(<scope>): <description>

Assisted-by: AI
```

The `Signed-off-by` trailer is added automatically by `git commit -s`.

## Stack

- Go 1.23+, module: `github.com/k8s-nono/nono-nri`
- NRI SDK: `github.com/containerd/nri` v0.10.0
- Tests: Ginkgo v2 + Gomega
- Config: TOML via `github.com/pelletier/go-toml/v2` v2.2.4
- Logging: `log/slog` with `NewJSONHandler`
- go.mod must keep: `replace github.com/opencontainers/runtime-spec => github.com/opencontainers/runtime-spec v1.1.0`

## Project Layout

```
cmd/nono-nri/        # main entrypoint
internal/nri/        # plugin, filter, profile, config, kernel
internal/log/        # slog setup
```

## Key Decisions

- Container opt-in: RuntimeClass filter only (no namespace denylist)
- Pause containers excluded naturally via NRI PodSandbox event separation
- `ContainerAdjustment.SetArgs()` to wrap process.args — no OCI hooks
- nono binary bind-mounted from host into container (works for Kata via virtiofs)
- Kernel check (5.13+ for Landlock) runs before anything else in main()
