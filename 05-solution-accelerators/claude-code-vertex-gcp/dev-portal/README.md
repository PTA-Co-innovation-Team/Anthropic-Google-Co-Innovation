# Dev Portal

A tiny IAP-protected static page on Cloud Run that tells developers
**how to point their Claude Code install at this deployment**. New hires
hit the URL, copy three commands, and they're done.

- **Tech:** nginx-alpine serving hand-written HTML/CSS. No JS framework,
  no build step, no dependencies.
- **Size:** ~10 MB container, scales to zero on Cloud Run.
- **Auth:** IAP in front of Cloud Run. Only Google identities in
  `access.allowed_principals` can open the page.

---

## How URL substitution works

`public/index.html` contains placeholders that get replaced at deploy
time:

| Placeholder | Replaced with |
| --- | --- |
| `__LLM_GATEWAY_URL__` | The LLM gateway's Cloud Run URL |
| `__MCP_GATEWAY_URL__` | The MCP gateway's Cloud Run URL |
| `__PROJECT_ID__` | The GCP project ID |
| `__REGION__` | The Vertex region (e.g. `global`) |

`scripts/deploy-dev-portal.sh` runs `envsubst` over `index.html`, then
builds the container. The substituted HTML is what ships.

---

## Local preview

```bash
cd dev-portal
# Simple preview without substitution (placeholders will be visible)
python3 -m http.server --directory public 8080
# Open http://localhost:8080
```

To preview with real values, pre-substitute:

```bash
export LLM_GATEWAY_URL=https://llm-gateway-xxx-uc.a.run.app
export MCP_GATEWAY_URL=https://mcp-gateway-xxx-uc.a.run.app
export PROJECT_ID=my-project
export REGION=global

envsubst '$LLM_GATEWAY_URL $MCP_GATEWAY_URL $PROJECT_ID $REGION' \
  < public/index.html \
  | sed \
      -e "s#__LLM_GATEWAY_URL__#$LLM_GATEWAY_URL#g" \
      -e "s#__MCP_GATEWAY_URL__#$MCP_GATEWAY_URL#g" \
      -e "s#__PROJECT_ID__#$PROJECT_ID#g" \
      -e "s#__REGION__#$REGION#g" \
  > /tmp/index.html

python3 -m http.server --directory /tmp 8080
```

---

## Building the container

```bash
docker build -t dev-portal:local .
docker run --rm -p 8080:8080 dev-portal:local
# Open http://localhost:8080
```

The nginx config template is `envsubst`'d at container startup (by the
nginx image's built-in entrypoint), so `$PORT` from Cloud Run gets
honored with no shell wrapper.

---

## Customizing

- **Branding.** Edit `public/styles.css`. The palette uses Google
  blue (`#1a73e8`) — swap for your own primary color in one place.
- **Extra instructions.** Add another `<section class="card">` in
  `index.html`. The tab switcher is plain JS at the bottom of the
  file; adding OS variants is trivial.
- **Multilingual.** Duplicate `index.html` to `index.es.html`, etc.,
  and let nginx negotiate or route by subpath.

Keep the portal **static and boring**. This is the first thing a new
team member sees — it should never fail and never need a JS refresh to
render.
