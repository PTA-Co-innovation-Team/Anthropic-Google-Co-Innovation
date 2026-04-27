"""
Risk scoring tool for the Deal Desk Agent.
Computes a weighted risk score based on client profile and compliance data.
Called by the Risk Scoring Agent (Haiku 4.5) for fast evaluation.
"""


# ─── Weight configuration ───
WEIGHTS = {
    "aum_size": 0.15,
    "domicile": 0.20,
    "strategy_complexity": 0.15,
    "kyc_status": 0.20,
    "aml_status": 0.15,
    "sanctions_status": 0.15,
}

# ─── Scoring tables ───
DOMICILE_RISK = {
    "united states": 0.1,
    "canada": 0.15,
    "united kingdom": 0.15,
    "singapore": 0.25,
    "hong kong": 0.30,
    "cayman islands": 0.45,
    "british virgin islands": 0.55,
    "luxembourg": 0.20,
    "switzerland": 0.20,
}

STRATEGY_RISK = {
    "long/short equity": 0.20,
    "global macro": 0.35,
    "multi-strategy": 0.30,
    "quantitative equity": 0.25,
    "credit/distressed": 0.45,
    "systematic futures": 0.30,
    "private equity": 0.20,
    "event-driven": 0.35,
    "emerging markets": 0.50,
}

STATUS_RISK = {
    "VERIFIED": 0.0,
    "CLEAR": 0.0,
    "PENDING": 0.5,
    "REVIEW": 0.7,
    "FAILED": 1.0,
    "EXPIRED": 0.6,
}

TIER_THRESHOLDS = {
    "LOW": (0.0, 0.30),
    "MEDIUM": (0.30, 0.55),
    "HIGH": (0.55, 1.0),
}


def _score_aum(aum_millions: float) -> float:
    """Larger AUM = lower risk (more institutional, more oversight)."""
    if aum_millions >= 1000:
        return 0.10
    elif aum_millions >= 500:
        return 0.20
    elif aum_millions >= 200:
        return 0.30
    elif aum_millions >= 100:
        return 0.45
    else:
        return 0.60


def _score_domicile(domicile: str) -> float:
    """Score based on jurisdiction regulatory strength."""
    return DOMICILE_RISK.get(domicile.lower(), 0.50)


def _score_strategy(strategy: str) -> float:
    """Score based on strategy complexity and risk profile."""
    return STRATEGY_RISK.get(strategy.lower(), 0.40)


def _score_status(status: str) -> float:
    """Score a compliance status field."""
    return STATUS_RISK.get(status, 0.5)


def _determine_tier(score: float) -> str:
    """Map numeric score to risk tier."""
    for tier, (low, high) in TIER_THRESHOLDS.items():
        if low <= score < high:
            return tier
    return "HIGH"


def compute_risk_score(
    client_name: str,
    aum_millions: float,
    strategy: str,
    domicile: str,
    kyc_status: str,
    aml_status: str,
    sanctions_status: str
) -> dict:
    """
    Compute a weighted risk score for a client based on their profile
    and compliance data. Returns the score, tier, and a breakdown of
    contributing factors.

    Args:
        client_name: Name of the client.
        aum_millions: Assets under management in millions.
        strategy: Investment strategy.
        domicile: Country/jurisdiction of domicile.
        kyc_status: KYC verification status.
        aml_status: AML screening status.
        sanctions_status: Sanctions screening status.

    Returns:
        dict with risk_score (0-1), risk_tier, confidence, and
        a breakdown of individual factor scores with explanations.
    """
    factors = {
        "aum_size": {
            "score": _score_aum(aum_millions),
            "weight": WEIGHTS["aum_size"],
            "detail": f"AUM ${aum_millions}M — {'large institutional' if aum_millions >= 500 else 'mid-size' if aum_millions >= 200 else 'smaller fund'}"
        },
        "domicile": {
            "score": _score_domicile(domicile),
            "weight": WEIGHTS["domicile"],
            "detail": f"{domicile} — {'strong' if _score_domicile(domicile) < 0.25 else 'moderate' if _score_domicile(domicile) < 0.4 else 'elevated'} regulatory environment"
        },
        "strategy_complexity": {
            "score": _score_strategy(strategy),
            "weight": WEIGHTS["strategy_complexity"],
            "detail": f"{strategy} — {'standard' if _score_strategy(strategy) < 0.3 else 'moderate' if _score_strategy(strategy) < 0.4 else 'complex'} risk profile"
        },
        "kyc_status": {
            "score": _score_status(kyc_status),
            "weight": WEIGHTS["kyc_status"],
            "detail": f"KYC: {kyc_status}"
        },
        "aml_status": {
            "score": _score_status(aml_status),
            "weight": WEIGHTS["aml_status"],
            "detail": f"AML: {aml_status}"
        },
        "sanctions_status": {
            "score": _score_status(sanctions_status),
            "weight": WEIGHTS["sanctions_status"],
            "detail": f"Sanctions: {sanctions_status}"
        },
    }

    # Compute weighted score
    total_score = sum(
        f["score"] * f["weight"] for f in factors.values()
    )
    total_score = round(min(max(total_score, 0.0), 1.0), 4)

    # Confidence based on data completeness
    pending_count = sum(
        1 for s in [kyc_status, aml_status, sanctions_status]
        if s in ("PENDING", "REVIEW")
    )
    confidence = round(1.0 - (pending_count * 0.15), 2)

    tier = _determine_tier(total_score)

    # Flag any blockers
    blockers = []
    if kyc_status == "PENDING":
        blockers.append("KYC verification pending — onboarding blocked until resolved")
    if sanctions_status == "REVIEW":
        blockers.append("Sanctions screening under review — requires manual clearance")
    if aml_status == "REVIEW":
        blockers.append("AML review in progress — requires senior compliance sign-off")

    return {
        "client_name": client_name,
        "risk_score": total_score,
        "risk_tier": tier,
        "confidence": confidence,
        "blockers": blockers,
        "factors": {
            k: {"score": round(v["score"], 3), "weighted": round(v["score"] * v["weight"], 4), "detail": v["detail"]}
            for k, v in factors.items()
        },
        "recommendation": (
            "APPROVE — proceed with onboarding" if tier == "LOW" and not blockers
            else "APPROVE WITH CONDITIONS — review flagged items" if tier == "MEDIUM" and not blockers
            else "HOLD — resolve blockers before proceeding" if blockers
            else "ESCALATE — requires senior risk committee review"
        )
    }
