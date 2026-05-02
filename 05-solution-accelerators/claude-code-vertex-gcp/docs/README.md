# Documentation

Three layers, ordered from "I just want it working" to "I want to
understand every design choice":

| Layer | File | Audience |
|---|---|---|
| 1. Quick install | **[`../INSTALLATION.md`](../INSTALLATION.md)** | Anyone deploying for the first time. Prereqs + single command + verify, ~10 min. |
| 2. Operating it | **[`../CUSTOMER-RUNBOOK.md`](../CUSTOMER-RUNBOOK.md)** | Day-2 cookbook — switching models when one is offline, adding users, troubleshooting, teardown. |
| 3. Deep reference | The two long-form docs in this folder | Authoritative content with diagrams. |

The two long-form docs in this folder:

| File | Audience | Source |
|---|---|---|
| [Engineering Design](./claude-code-vertex-gcp-engineering-design.md) | Platform engineers, security architects, anyone reviewing the design before deploy | Generated from `generate_design_doc.py` |
| [User Guide](./claude-code-vertex-gcp-user-guide.md) | Operators deploying and running the gateway day-to-day | Generated from `generate_user_guide.py` |

The `.docx` versions of both documents are also distributed alongside
this repository for reviewers who prefer Word/Google Docs. The `.md`
versions in this folder are the git-friendly form — diffable in pull
requests, greppable, render in GitHub natively.

## Regenerating

The Python generator scripts are the single source of truth for
content. After editing them, regenerate both formats:

```bash
# Generates the .docx
python3 generate_design_doc.py
python3 generate_user_guide.py

# Converts the .docx to .md (this folder)
python3 convert_docx_to_md.py
```

Both outputs land in the parent directory; copy the `.md` files into
this `docs/` folder and the `assets/*.png` into `docs/assets/` for
in-repo display.
