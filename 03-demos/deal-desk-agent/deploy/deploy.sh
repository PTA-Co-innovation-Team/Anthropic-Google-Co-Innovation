#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Deal Desk Agent — Deploy to Google Cloud
# Builds all containers and deploys to Cloud Run + GCE
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Colors ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}═══ Step $1: $2 ═══${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ─── Config ───
PROJECT_ID="${PROJECT_ID:-cpe-slarbi-nvd-ant-demos}"
REGION="${REGION:-us-east5}"
INFRA_REGION="${INFRA_REGION:-us-central1}"
AR_REPO="deal-desk-agent"
BACKEND_IMAGE="${INFRA_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/backend"
FRONTEND_IMAGE="${INFRA_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/frontend"
BROWSER_IMAGE="${INFRA_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/browser-vm"

echo "══════════════════════════════════════════════════════════════"
echo "  Deal Desk Agent — Deployment"
echo "  Project:  ${PROJECT_ID}"
echo "  Model Region: ${REGION}"
echo "  Infra Region: ${INFRA_REGION}"
echo "══════════════════════════════════════════════════════════════"

read -p "$(echo -e "${YELLOW}Deploy to ${PROJECT_ID}? (y/N): ${NC}")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."; exit 0
fi

gcloud config set project "$PROJECT_ID" --quiet

# ─── Step 1: Enable APIs ───
step "1/8" "Enabling APIs"
gcloud services enable \
    aiplatform.googleapis.com \
    bigquery.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    compute.googleapis.com \
    --quiet
ok "APIs enabled"

# ─── Step 2: Create Artifact Registry ───
step "2/8" "Creating Artifact Registry repo"
if gcloud artifacts repositories describe "$AR_REPO" --location="$INFRA_REGION" &>/dev/null 2>&1; then
    warn "Repo already exists: ${AR_REPO}"
else
    gcloud artifacts repositories create "$AR_REPO" \
        --repository-format=docker \
        --location="$INFRA_REGION" \
        --description="Deal Desk Agent containers" \
        --quiet
    ok "Repo created: ${AR_REPO}"
fi

# Configure Docker auth
gcloud auth configure-docker "${INFRA_REGION}-docker.pkg.dev" --quiet
ok "Docker auth configured"

# ─── Step 3: Create Service Account ───
step "3/8" "Creating service account"
SA_NAME="deal-desk-agent-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null 2>&1; then
    warn "Service account already exists"
else
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="Deal Desk Agent Service Account" \
        --quiet
    ok "Service account created"
fi

# Bind roles
for role in roles/aiplatform.user roles/bigquery.dataEditor roles/bigquery.jobUser; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$role" \
        --condition=None --quiet 2>/dev/null
done
ok "IAM roles bound"

# ─── Step 4: Build Backend ───
step "4/8" "Building backend container"
cd "$(dirname "$0")/../backend"
gcloud builds submit \
    --tag="${BACKEND_IMAGE}:latest" \
    --region="$INFRA_REGION" \
    --quiet
ok "Backend image built"

# ─── Step 5: Build Frontend ───
step "5/8" "Building frontend container"
cd "$(dirname "$0")/../frontend"
gcloud builds submit \
    --tag="${FRONTEND_IMAGE}:latest" \
    --region="$INFRA_REGION" \
    --quiet
ok "Frontend image built"

# ─── Step 6: Build Browser VM ───
step "6/8" "Building browser VM container"
cd "$(dirname "$0")/../computer-use"
gcloud builds submit \
    --tag="${BROWSER_IMAGE}:latest" \
    --region="$INFRA_REGION" \
    --quiet
ok "Browser VM image built"

# ─── Step 7: Deploy Backend to Cloud Run ───
step "7/8" "Deploying backend to Cloud Run"
gcloud run deploy deal-desk-backend \
    --image="${BACKEND_IMAGE}:latest" \
    --region="$INFRA_REGION" \
    --service-account="$SA_EMAIL" \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},REGION=${REGION},BQ_DATASET=deal_desk_agent,MODEL_PROVIDER=claude,OPUS_MODEL=claude-opus-4-5@20251101,SONNET_MODEL=claude-sonnet-4-6@default,HAIKU_MODEL=claude-haiku-4-5@20251001" \
    --memory=2Gi \
    --cpu=2 \
    --timeout=300 \
    --max-instances=5 \
    --allow-unauthenticated \
    --quiet

BACKEND_URL=$(gcloud run services describe deal-desk-backend --region="$INFRA_REGION" --format="value(status.url)")
ok "Backend deployed: ${BACKEND_URL}"

# ─── Step 8: Deploy Frontend to Cloud Run ───
step "8/8" "Deploying frontend to Cloud Run"

# Rebuild frontend with backend URL injected
cd "$(dirname "$0")/../frontend"
gcloud run deploy deal-desk-frontend \
    --image="${FRONTEND_IMAGE}:latest" \
    --region="$INFRA_REGION" \
    --set-env-vars="API_BASE=${BACKEND_URL}" \
    --memory=512Mi \
    --cpu=1 \
    --max-instances=3 \
    --allow-unauthenticated \
    --quiet

FRONTEND_URL=$(gcloud run services describe deal-desk-frontend --region="$INFRA_REGION" --format="value(status.url)")
ok "Frontend deployed: ${FRONTEND_URL}"

# ─── Summary ───
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  ✅ Deal Desk Agent — Deployment Complete"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Frontend:    ${FRONTEND_URL}"
echo "  Backend API: ${BACKEND_URL}"
echo "  Health:      ${BACKEND_URL}/api/health"
echo "  Agent Card:  ${BACKEND_URL}/.well-known/agent.json"
echo ""
echo "  Browser VM requires manual setup on GCE:"
echo "  Image: ${BROWSER_IMAGE}:latest"
echo "  Ports: 6080 (noVNC), 5900 (VNC)"
echo ""
echo "  To deploy Browser VM on GCE:"
echo "  gcloud compute instances create-with-container deal-desk-browser \\"
echo "    --container-image=${BROWSER_IMAGE}:latest \\"
echo "    --zone=${INFRA_REGION}-a \\"
echo "    --machine-type=e2-standard-4 \\"
echo "    --tags=deal-desk-browser \\"
echo "    --container-env=SALESFORCE_URL=https://orgfarm-53f3fee654.lightning.force.com"
echo ""
echo "══════════════════════════════════════════════════════════════"
