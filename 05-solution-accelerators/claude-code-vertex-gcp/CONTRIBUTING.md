# Contributing

Thanks for wanting to improve this project! It's meant to be a useful
reference architecture for a whole community of GCP teams deploying Claude
Code, so contributions from different environments are very welcome.

## Filing issues

Please include:

- **What you were trying to do** (one sentence).
- **What happened** (error text verbatim, or a screenshot).
- **Your environment:** output of `gcloud version`, `terraform version` (if
  relevant), OS, and shell.
- **Which deployment path** (curl-to-bash, clone+script, Terraform, or
  notebook).

If it's a bug in the gateway, the output of `gcloud logging read` filtered
to the gateway service is extremely helpful.

## Submitting pull requests

1. Fork the repo and create a topic branch from `main`.
2. Make focused changes — one concern per PR.
3. For any Python change, run `python -m py_compile` on the touched files.
4. For any Terraform change, run `terraform fmt -recursive` and
   `terraform validate`.
5. For any shell change, run `bash -n` on the touched scripts.
6. Run `scripts/pre-deploy-check.sh` before submitting — it validates
   code consistency across deploy scripts, Terraform modules, and
   application code (30 checks covering GLB, VPC internal, IAP, Cloud
   NAT, and teardown coverage — no GCP access needed).
7. Keep the beginner-friendly tone. Heavy comments are a feature, not a bug
   — don't strip them in the name of concision.
8. Update `README.md`, `ARCHITECTURE.md`, `COSTS.md`, or
   `TROUBLESHOOTING.md` as needed when behavior changes.

### Token validation sync requirement

`gateway/app/token_validation.py` and `mcp-gateway/token_validation.py`
must stay in sync — they are independent copies because the two services
build separate containers. The pre-deploy check script (step 6 above)
verifies this automatically. When editing one file, update the other to
match (from the first `import` statement onward).

### GLB validation

If your change affects GLB, IAP, or auth behavior, run
`scripts/validate-glb-demo.sh` against a live deployment to verify
the 31-test suite across all 8 layers (infrastructure, config, auth,
routing, dev VM, IAP, MCP, parity).

## What belongs in this repo

**Yes:**

- Fixes and improvements to the gateway, Terraform, scripts, or notebook.
- Additional example MCP tools under `mcp-gateway/tools/` — they should be
  small and GCP-relevant (e.g., "list GCS buckets", "describe Cloud Run
  service").
- More troubleshooting entries.
- Additional regions, machine types, or model defaults.

**Probably no:**

- Business-logic MCP tools that are specific to one company.
- Major architecture changes that move away from the "pass-through proxy"
  design — open an issue to discuss first.
- Support for non-GCP clouds (that's a different project).

## Style

- Python: type hints, Google-style docstrings, structured logging (no
  `print()`).
- Terraform: `description` on every variable and resource, `locals` for
  computed values.
- Shell: `set -euo pipefail`, use `scripts/lib/common.sh` helpers, support
  `--help` and `--dry-run` where reasonable.
- Markdown: short paragraphs, runnable code blocks, beginner tone.

## License

By contributing you agree that your contributions are licensed under
Apache 2.0, same as the rest of the project.
