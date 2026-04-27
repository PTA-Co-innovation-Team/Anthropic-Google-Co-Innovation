"""
BigQuery tools for the Deal Desk Agent.
Read and write operations against the deal_desk_agent dataset.
Used by ADK agents via tool definitions.
"""

import os
import uuid
from datetime import datetime
from google.cloud import bigquery

PROJECT_ID = os.environ.get("PROJECT_ID", "cpe-slarbi-nvd-ant-demos")
DATASET = os.environ.get("BQ_DATASET", "deal_desk_agent")

_client = None

def _get_client():
    """Lazy-init BigQuery client."""
    global _client
    if _client is None:
        _client = bigquery.Client(project=PROJECT_ID)
    return _client


def _run_query(sql: str, params: list = None) -> list[dict]:
    """Execute a parameterized query and return rows as dicts."""
    client = _get_client()
    job_config = bigquery.QueryJobConfig()
    if params:
        job_config.query_parameters = params
    rows = client.query(sql, job_config=job_config).result()
    results = []
    for row in rows:
        d = dict(row)
        for k, v in d.items():
            if hasattr(v, 'isoformat'):
                d[k] = v.isoformat()
        results.append(d)
    return results


# ═══════════════════════════════════════════════════════════════════════════════
# READ TOOLS
# ═══════════════════════════════════════════════════════════════════════════════

def query_client_data(client_name: str) -> dict:
    """
    Look up a client by name in the clients table.
    Returns client profile including AUM, strategy, fee structure,
    relationship status, and primary contact.

    Args:
        client_name: Full or partial name of the client to search for.

    Returns:
        dict with 'found' boolean and 'results' list of matching client records.
    """
    sql = f"""
        SELECT *
        FROM `{PROJECT_ID}.{DATASET}.clients`
        WHERE LOWER(name) LIKE LOWER(@search_term)
        ORDER BY aum_millions DESC
    """
    params = [
        bigquery.ScalarQueryParameter("search_term", "STRING", f"%{client_name}%")
    ]
    results = _run_query(sql, params)
    return {
        "found": len(results) > 0,
        "match_count": len(results),
        "results": results
    }


def query_market_intelligence(client_name: str) -> dict:
    """
    Retrieve recent market intelligence for a given client.
    Returns SEC filings, news articles, and market data sorted by relevance.

    Args:
        client_name: Full or partial name of the client.

    Returns:
        dict with 'found' boolean and 'intel' list of intelligence records.
    """
    sql = f"""
        SELECT *
        FROM `{PROJECT_ID}.{DATASET}.market_intelligence`
        WHERE LOWER(client_name) LIKE LOWER(@search_term)
        ORDER BY relevance_score DESC, date DESC
    """
    params = [
        bigquery.ScalarQueryParameter("search_term", "STRING", f"%{client_name}%")
    ]
    results = _run_query(sql, params)
    return {
        "found": len(results) > 0,
        "record_count": len(results),
        "intel": results
    }


def query_compliance_records(client_name: str) -> dict:
    """
    Retrieve compliance records for a given client.
    Returns KYC status, AML status, sanctions screening, FINRA registration,
    and risk tier.

    Args:
        client_name: Full or partial name of the client.

    Returns:
        dict with 'found' boolean and 'records' list of compliance data.
    """
    sql = f"""
        SELECT *
        FROM `{PROJECT_ID}.{DATASET}.compliance_records`
        WHERE LOWER(client_name) LIKE LOWER(@search_term)
    """
    params = [
        bigquery.ScalarQueryParameter("search_term", "STRING", f"%{client_name}%")
    ]
    results = _run_query(sql, params)
    return {
        "found": len(results) > 0,
        "records": results
    }


# ═══════════════════════════════════════════════════════════════════════════════
# WRITE TOOLS
# ═══════════════════════════════════════════════════════════════════════════════

def update_client_status(client_name: str, new_status: str) -> dict:
    """
    Update a client's relationship status after onboarding.
    Typically changes status from 'Prospect' or 'Returning' to 'Active'.

    Args:
        client_name: Exact name of the client to update.
        new_status: New relationship status (e.g., 'Active').

    Returns:
        dict with 'success' boolean and 'rows_updated' count.
    """
    sql = f"""
        UPDATE `{PROJECT_ID}.{DATASET}.clients`
        SET relationship_status = @new_status
        WHERE LOWER(name) = LOWER(@client_name)
    """
    params = [
        bigquery.ScalarQueryParameter("new_status", "STRING", new_status),
        bigquery.ScalarQueryParameter("client_name", "STRING", client_name),
    ]
    client = _get_client()
    job_config = bigquery.QueryJobConfig(query_parameters=params)
    result = client.query(sql, job_config=job_config).result()
    rows_affected = result.num_dml_affected_rows or 0
    return {
        "success": rows_affected > 0,
        "rows_updated": rows_affected,
        "client_name": client_name,
        "new_status": new_status
    }


def insert_deal_package(
    client_name: str,
    aum_millions: float,
    strategy: str,
    mandate_type: str,
    fee_structure: str,
    compliance_status: str,
    risk_tier: str,
    risk_score: float,
    primary_contact: str,
    primary_contact_title: str,
    notes: str = ""
) -> dict:
    """
    Insert a completed deal package into the deal_packages table.
    Creates an audit record of the agent's work.

    Args:
        client_name: Name of the client.
        aum_millions: Assets under management in millions.
        strategy: Investment strategy.
        mandate_type: Type of mandate (e.g., 'Long/Short Equity').
        fee_structure: Fee structure (e.g., '2/20').
        compliance_status: Overall compliance result (e.g., 'CLEARED').
        risk_tier: Risk tier assigned (e.g., 'MEDIUM').
        risk_score: Numeric risk score (0.0 to 1.0).
        primary_contact: Name of primary contact.
        primary_contact_title: Title of primary contact.
        notes: Additional notes from the synthesis agent.

    Returns:
        dict with 'success' boolean and the generated 'deal_id'.
    """
    deal_id = f"DEAL-{uuid.uuid4().hex[:8].upper()}"
    sql = f"""
        INSERT INTO `{PROJECT_ID}.{DATASET}.deal_packages`
        (deal_id, client_name, aum_millions, strategy, mandate_type,
         fee_structure, compliance_status, risk_tier, risk_score,
         primary_contact, primary_contact_title, salesforce_opportunity_id,
         status, created_by, created_at, notes)
        VALUES
        (@deal_id, @client_name, @aum_millions, @strategy, @mandate_type,
         @fee_structure, @compliance_status, @risk_tier, @risk_score,
         @primary_contact, @primary_contact_title, NULL,
         'PENDING_SF_ENTRY', 'deal_desk_agent', CURRENT_TIMESTAMP(), @notes)
    """
    params = [
        bigquery.ScalarQueryParameter("deal_id", "STRING", deal_id),
        bigquery.ScalarQueryParameter("client_name", "STRING", client_name),
        bigquery.ScalarQueryParameter("aum_millions", "FLOAT64", aum_millions),
        bigquery.ScalarQueryParameter("strategy", "STRING", strategy),
        bigquery.ScalarQueryParameter("mandate_type", "STRING", mandate_type),
        bigquery.ScalarQueryParameter("fee_structure", "STRING", fee_structure),
        bigquery.ScalarQueryParameter("compliance_status", "STRING", compliance_status),
        bigquery.ScalarQueryParameter("risk_tier", "STRING", risk_tier),
        bigquery.ScalarQueryParameter("risk_score", "FLOAT64", risk_score),
        bigquery.ScalarQueryParameter("primary_contact", "STRING", primary_contact),
        bigquery.ScalarQueryParameter("primary_contact_title", "STRING", primary_contact_title),
        bigquery.ScalarQueryParameter("notes", "STRING", notes),
    ]
    client = _get_client()
    job_config = bigquery.QueryJobConfig(query_parameters=params)
    client.query(sql, job_config=job_config).result()
    return {
        "success": True,
        "deal_id": deal_id,
        "client_name": client_name,
        "status": "PENDING_SF_ENTRY"
    }


def update_deal_with_sf_opportunity(deal_id: str, opportunity_id: str) -> dict:
    """
    Stamp a Salesforce opportunity ID onto a deal package record.
    Called by the Salesforce browser agent after creating the opportunity.

    Args:
        deal_id: The deal package ID (e.g., 'DEAL-A1B2C3D4').
        opportunity_id: The Salesforce opportunity ID (e.g., 'OPP-006Xx000001abc').

    Returns:
        dict with 'success' boolean.
    """
    sql = f"""
        UPDATE `{PROJECT_ID}.{DATASET}.deal_packages`
        SET salesforce_opportunity_id = @opportunity_id,
            status = 'COMPLETED'
        WHERE deal_id = @deal_id
    """
    params = [
        bigquery.ScalarQueryParameter("opportunity_id", "STRING", opportunity_id),
        bigquery.ScalarQueryParameter("deal_id", "STRING", deal_id),
    ]
    client = _get_client()
    job_config = bigquery.QueryJobConfig(query_parameters=params)
    result = client.query(sql, job_config=job_config).result()
    rows_affected = result.num_dml_affected_rows or 0
    return {
        "success": rows_affected > 0,
        "deal_id": deal_id,
        "salesforce_opportunity_id": opportunity_id,
        "status": "COMPLETED"
    }
