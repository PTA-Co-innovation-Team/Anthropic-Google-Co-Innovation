<p align="center">
  <img src="assets/hero-banner.png" alt="Anthropic + Google Cloud Co-Innovation" width="100%"/>
</p>

# Anthropic + Google Cloud: AI Co-Innovation Space

Welcome to the official co-innovation repository for the **Anthropic + Google Cloud partnership**. This space is designed to showcase the deep integration between Anthropic's **Claude** family of frontier models and Google Cloud's secure, scalable AI infrastructure — including **Vertex AI**, **Agentspace**, **BigQuery**, and the **Agent Development Kit (ADK)**.

---

## 📂 Repository Structure

| Module | Description |
|---|---|
| [`01-tutorials`](./01-tutorials) | **Step-by-Step Learning:** Detailed, hands-on walk-throughs covering foundational concepts, from basic prompting with Claude on Vertex AI to advanced agentic orchestration. |
| [`02-quick-starts`](./02-quick-starts) | **Fast-Track Deployment:** Minimalist code snippets and scripts to get Claude models running on Google Cloud in minutes. |
| [`03-demos`](./03-demos) | **Interactive Showcases:** End-to-end functional examples and UI-driven applications that highlight the "Better Together" story in real-world enterprise scenarios. |
| [`04-best-practice-guides`](./04-best-practice-guides) | **Optimization & Governance:** Expert advice on performance tuning, cost management, context engineering, and responsible AI implementation for Claude. |
| [`05-solution-accelerators`](./05-solution-accelerators) | **Production Blueprints:** Pre-packaged, enterprise-ready architectures and automation pipelines to jumpstart complex agentic AI projects. |

---

## 🚀 Getting Started

### Prerequisites

Before diving in, make sure you have:

- A **Google Cloud project** with billing enabled and the **Vertex AI API** activated
- Access to **Anthropic's Claude models on Vertex AI** — request access via the [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) if needed
- The **gcloud CLI** installed and authenticated (`gcloud auth application-default login`)
- **Python 3.10+** or **Node.js 20+** depending on the module
- (Optional) **Claude Code** installed locally for the best developer experience when working through tutorials

### Quick authentication check

```bash
gcloud auth list
gcloud config set project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
```

### Recommended learning path

1. **Start with [`01-tutorials`](./01-tutorials)** — master the fundamentals of calling Claude on Vertex AI, structured tool use, and the Model Context Protocol (MCP).
2. **Move to [`02-quick-starts`](./02-quick-starts)** — copy-paste runnable snippets to validate your environment end-to-end.
3. **Explore [`03-demos`](./03-demos)** — see full "Better Together" reference applications combining Claude with BigQuery, AlloyDB, and Agentspace.
4. **Level up with [`04-best-practice-guides`](./04-best-practice-guides)** — apply context engineering, caching, and cost-optimization patterns.
5. **Ship with [`05-solution-accelerators`](./05-solution-accelerators)** — adapt production-ready blueprints for your own enterprise use cases.

### Getting help

If you hit an issue, open a GitHub Issue against this repo or reach out to the PTA Co-Innovation Team directly.

---

## 🤝 The Partnership

This repository reflects a collaborative effort to combine **Anthropic's** leadership in safe, frontier AI research with **Google Cloud's** secure, scalable, and high-performance global infrastructure. Together we deliver Claude to enterprises through **Vertex AI**, **Agentspace**, and the broader Google Cloud ecosystem.
