#!/usr/bin/env bash
# =============================================================================
# regions.sh — Vertex region picker.
#
# Exposes pick_region() which prints a menu of common regions, accepts a
# numeric selection OR free-form entry, validates the result against a
# region-name regex, and echoes the chosen region on stdout.
#
# Source after common.sh.
# =============================================================================

# Ordered list of common regions with short labels. Keep in sync with
# ARCHITECTURE.md and COSTS.md so users see the same set everywhere.
COMMON_REGIONS=(
  "global|Vertex multi-region (recommended default)"
  "us-east5|Columbus, OH — most mature Claude region"
  "us-central1|Iowa"
  "europe-west1|Belgium"
  "europe-west3|Frankfurt — EU data residency"
  "europe-west4|Netherlands"
  "asia-southeast1|Singapore"
  "asia-northeast1|Tokyo"
  "us|US multi-region"
  "europe|Europe multi-region"
)

# Regex matching Vertex-compatible region strings (either our
# multi-region tokens, or a `<continent>-<loc><digit>` form).
_REGION_RE='^(global|us|europe|asia|[a-z]+-[a-z]+[0-9]+)$'

# -----------------------------------------------------------------------------
# pick_region — interactive picker. Writes the final selection to stdout
# (so callers can do  REGION=$(pick_region)).
# Prompts and menu go to stderr so stdout is clean.
# -----------------------------------------------------------------------------
pick_region() {
  # Menu.
  echo "" >&2
  echo "Choose a Vertex region:" >&2
  echo "" >&2
  local i=1
  for entry in "${COMMON_REGIONS[@]}"; do
    local name="${entry%%|*}"
    local desc="${entry#*|}"
    printf "  %2d) %-22s %s\n" "$i" "$name" "$desc" >&2
    i=$((i + 1))
  done
  printf "  %2d) %s\n" "$i" "Enter a region name manually" >&2
  echo "" >&2

  # Loop until we get a valid answer.
  while true; do
    local choice
    read -rp "Selection [1-$i], or type a region: " choice </dev/tty

    # Numeric choice within the menu range?
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      local n=$((choice))
      if ((n >= 1 && n <= ${#COMMON_REGIONS[@]})); then
        local entry="${COMMON_REGIONS[$((n - 1))]}"
        echo "${entry%%|*}"
        return 0
      fi
      if ((n == i)); then
        # Manual entry.
        local manual
        read -rp "Region name: " manual </dev/tty
        if [[ "$manual" =~ $_REGION_RE ]]; then
          echo "$manual"
          return 0
        fi
        log_warn "'$manual' doesn't look like a region string. Try again." >&2
        continue
      fi
      log_warn "selection out of range." >&2
      continue
    fi

    # Not numeric — treat as a direct region name.
    if [[ "$choice" =~ $_REGION_RE ]]; then
      echo "$choice"
      return 0
    fi
    log_warn "'$choice' doesn't look like a menu number or region string." >&2
  done
}

# -----------------------------------------------------------------------------
# fallback_region_for <region> — prints a GCE/Cloud Run region to use
# when the given Vertex region is a multi-region ("global", "us", etc.).
# -----------------------------------------------------------------------------
fallback_region_for() {
  local region="$1"
  # Only multi-region Vertex values need a fallback. Real GCE-compatible
  # regions (e.g. us-east5, europe-west3) are used directly — matching
  # Terraform's local.gce_region logic in variables.tf.
  case "$region" in
    global)  echo "us-central1" ;;
    us)      echo "us-central1" ;;
    europe)  echo "europe-west1" ;;
    asia)    echo "asia-southeast1" ;;
    *)       echo "${region}" ;;
  esac
}
