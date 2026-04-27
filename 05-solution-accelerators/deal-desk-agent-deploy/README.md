# Deal Desk Agent — Colab Enterprise Deploy Accelerator

**Stand up the [Deal Desk Agent demo](../../03-demos/deal-desk-agent) end-to-end in a fresh Google Cloud project, cell-by-cell from a single notebook.**

## What this accelerator does

Running [`colab_deploy.ipynb`](./colab_deploy.ipynb) top-to-bottom in **Colab Enterprise** deploys:

- **BigQuery** dataset + 4 tables, seeded with ~20 synthetic FSI clients
- **Backend** (FastAPI) on Cloud Run — orchestrates the multi-agent pipeline
- **Frontend** (React/Vite) on Cloud Run — the demo UI
- **Browser VM** (n2-standard-4) on Compute Engine — Xvfb + Chrome + noVNC + Salesforce Computer Use agent
- **Secrets** (`AGENT_SECRET`, Salesforce credentials) in Secret Manager
- **Agent Engine** deployment of the ADK pipeline — captures the resource ID
- **Gemini Enterprise** registration — registers the agent into your existing engine using both A2A and the Agent Engine resource

Plus smoke tests and teardown cells.

## Prerequisites

The notebook §1 walks through these in detail. Summary:

1. **GCP project** with billing enabled and the right IAM roles
2. **Vertex AI Claude model access** for `claude-opus-4-5`, `claude-sonnet-4-6`, `claude-haiku-4-5` in `us-east5`
3. **Salesforce Developer Edition org** ([sign up](https://developer.salesforce.com/signup))
4. **Existing Gemini Enterprise engine** (you provide the engine ID)
5. Operator workstation public IP (for the noVNC firewall rule)

## Time and cost

- **Wall-clock:** ~25-40 min for a fresh deploy (Cloud Build × 3, GCE cold-start, Agent Engine deploy)
- **Cost:** ~$5-15 for a deploy + ~30 min idle. The GCE browser VM bills 24/7 if left running — **run §20 teardown cells**.

## Disclaimer

The deployed system is a **demonstration**, not production-ready software. See [`03-demos/deal-desk-agent/DESIGN.md`](../../03-demos/deal-desk-agent/DESIGN.md) §9 for known limitations and §10 for the security model. Do not deploy against real client data, production Salesforce orgs, or regulated workloads.
