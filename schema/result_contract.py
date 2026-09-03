"""Semantic checks shared by versioned result-document validators."""

from __future__ import annotations

from typing import Any


def semantic_problems(document: dict[str, Any]) -> list[str]:
    """Return policy/provenance contradictions in one result document."""
    publication = document.get("publication")
    if not isinstance(publication, dict):
        return []
    policy_version = publication.get("policy_version", 0)
    if (
        not isinstance(policy_version, int)
        or isinstance(policy_version, bool)
        or policy_version < 2
    ):
        return []

    provenance = document.get("provenance")
    provenance = provenance if isinstance(provenance, dict) else {}
    harness = provenance.get("harness")
    harness = harness if isinstance(harness, dict) else {}
    path = harness.get("path")
    sha256 = harness.get("sha256")
    modules = harness.get("modules")
    complete = (
        isinstance(path, str)
        and bool(path)
        and isinstance(sha256, str)
        and bool(sha256)
        and isinstance(modules, list)
        and bool(modules)
        and any(
            isinstance(module, dict)
            and module.get("path") == path
            and module.get("sha256") == sha256
            for module in modules
        )
    )
    if complete:
        return []

    problems: list[str] = []
    if publication.get("eligible") is True:
        problems.append(
            "publication policy v2 forbids eligible=true without an exact "
            "harness.path/sha256 entry in harness.modules"
        )
    reasons = publication.get("reasons")
    reasons = reasons if isinstance(reasons, list) else []
    reason_codes = {
        reason.get("code")
        for reason in reasons
        if isinstance(reason, dict)
    }
    if "HARNESS_MODULES_UNPROVEN" not in reason_codes:
        problems.append(
            "publication policy v2 requires HARNESS_MODULES_UNPROVEN when "
            "interpreted-harness module provenance is incomplete"
        )
    return problems
