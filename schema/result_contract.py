"""Semantic checks shared by versioned result-document validators."""

from __future__ import annotations

import hashlib
from typing import Any


def _publication_reason_codes(publication: dict[str, Any]) -> set[str]:
    reasons = publication.get("reasons")
    reasons = reasons if isinstance(reasons, list) else []
    return {
        reason.get("code")
        for reason in reasons
        if isinstance(reason, dict) and isinstance(reason.get("code"), str)
    }


def _registry_metric(registry: dict[str, Any] | None, metric_id: object) -> dict[str, Any] | None:
    if not isinstance(registry, dict) or not isinstance(metric_id, str):
        return None
    metrics = registry.get("metrics")
    if not isinstance(metrics, list):
        return None
    for metric in metrics:
        if isinstance(metric, dict) and metric.get("id") == metric_id:
            return metric
    return None


def _corpus_problems(
    document: dict[str, Any], registry: dict[str, Any] | None
) -> list[str]:
    """Validate v3 block-corpus cross-field consistency and publication policy."""

    problems: list[str] = []
    session = document.get("session")
    session = session if isinstance(session, dict) else {}
    requested = session.get("requested_samples")
    publication = document.get("publication")
    publication = publication if isinstance(publication, dict) else {}
    eligible = publication.get("eligible") is True
    policy_version = publication.get("policy_version")

    arms_value = document.get("arms")
    arms = arms_value if isinstance(arms_value, list) else []
    corpus_arms: dict[str, dict[str, Any]] = {}

    for arm in arms:
        if not isinstance(arm, dict):
            continue
        corpus = arm.get("corpus")
        if not isinstance(corpus, dict):
            continue
        arm_id = arm.get("arm_id")
        arm_name = arm_id if isinstance(arm_id, str) else "?"
        corpus_arms[arm_name] = arm

        blocks_value = corpus.get("blocks")
        blocks = blocks_value if isinstance(blocks_value, list) else []
        block_dicts = [block for block in blocks if isinstance(block, dict)]
        block_ids = [block.get("block") for block in block_dicts]
        integer_ids = [
            value
            for value in block_ids
            if isinstance(value, int) and not isinstance(value, bool)
        ]

        if isinstance(requested, int) and not isinstance(requested, bool):
            if len(block_dicts) != requested:
                problems.append(
                    f"arm {arm_name}: corpus has {len(block_dicts)} block records but "
                    f"session.requested_samples={requested}"
                )
            expected = list(range(1, requested + 1))
            if sorted(integer_ids) != expected:
                problems.append(
                    f"arm {arm_name}: corpus block ids must be exactly 1..{requested}"
                )

        if len(integer_ids) != len(set(integer_ids)):
            problems.append(f"arm {arm_name}: corpus block ids are not unique")

        valid_blocks = [block for block in block_dicts if block.get("valid") is True]
        stats = arm.get("statistics")
        stats = stats if isinstance(stats, dict) else {}
        if stats.get("valid_samples") != len(valid_blocks):
            problems.append(
                f"arm {arm_name}: statistics.valid_samples={stats.get('valid_samples')} "
                f"but {len(valid_blocks)} corpus blocks are valid"
            )

        observations = sum(
            block.get("observations", 0)
            for block in valid_blocks
            if isinstance(block.get("observations"), int)
            and not isinstance(block.get("observations"), bool)
        )
        if stats.get("observations") != observations:
            problems.append(
                f"arm {arm_name}: statistics.observations={stats.get('observations')} "
                f"but valid corpus blocks sum to {observations}"
            )

        raw_paths: list[str] = []
        digest = hashlib.sha256()
        digest_ready = True
        for block in sorted(
            valid_blocks,
            key=lambda item: item.get("block")
            if isinstance(item.get("block"), int)
            else 0,
        ):
            raw = block.get("raw_file")
            if not isinstance(raw, dict):
                digest_ready = False
                continue
            path = raw.get("path")
            sha = raw.get("sha256")
            if isinstance(path, str):
                raw_paths.append(path)
            if isinstance(sha, str):
                try:
                    digest.update(bytes.fromhex(sha))
                except ValueError:
                    digest_ready = False
            else:
                digest_ready = False
        if len(raw_paths) != len(set(raw_paths)):
            problems.append(f"arm {arm_name}: valid corpus raw-file paths are not unique")
        if digest_ready and corpus.get("digest_chain_sha256") != digest.hexdigest():
            problems.append(
                f"arm {arm_name}: corpus.digest_chain_sha256 does not match ordered raw-file hashes"
            )

    comparisons: list[dict[str, Any]] = []
    comparison = document.get("comparison")
    if isinstance(comparison, dict):
        comparisons.append(comparison)
    diagnostics = document.get("diagnostic_comparisons")
    if isinstance(diagnostics, list):
        comparisons.extend(item for item in diagnostics if isinstance(item, dict))

    for comparison_item in comparisons:
        baseline_id = comparison_item.get("baseline_arm")
        candidate_id = comparison_item.get("candidate_arm")
        baseline = corpus_arms.get(baseline_id) if isinstance(baseline_id, str) else None
        candidate = corpus_arms.get(candidate_id) if isinstance(candidate_id, str) else None
        if baseline is None and candidate is None:
            continue
        if baseline is None or candidate is None:
            problems.append(
                "comparison between block-corpus arms requires both baseline and candidate corpora"
            )
            continue
        baseline_corpus = baseline["corpus"]
        candidate_corpus = candidate["corpus"]
        if baseline_corpus.get("block_unit") != "paired-session-round" or candidate_corpus.get(
            "block_unit"
        ) != "paired-session-round":
            problems.append(
                "paired block-corpus comparison requires block_unit=paired-session-round on both arms"
            )
        baseline_blocks = baseline_corpus.get("blocks", [])
        candidate_blocks = candidate_corpus.get("blocks", [])
        baseline_ids = [
            block.get("block")
            for block in baseline_blocks
            if isinstance(block, dict)
        ]
        candidate_ids = [
            block.get("block")
            for block in candidate_blocks
            if isinstance(block, dict)
        ]
        if baseline_ids != candidate_ids:
            problems.append(
                "paired block-corpus comparison requires identical ordered block ids"
            )
        if any(
            isinstance(block, dict) and block.get("valid") is not True
            for block in [*baseline_blocks, *candidate_blocks]
        ):
            problems.append(
                "paired block-corpus comparison cannot use rejected blocks"
            )

    metric = document.get("metric")
    metric = metric if isinstance(metric, dict) else {}
    metric_id = metric.get("id")
    if metric_id == "IPC-RTT" and corpus_arms:
        parameters = metric.get("parameters")
        parameters = parameters if isinstance(parameters, dict) else {}
        payload_tier = parameters.get("payload_tier")
        payload_bytes = parameters.get("payload_bytes")
        handshake_included = parameters.get("handshake_included")
        if not isinstance(payload_tier, str) or not payload_tier:
            problems.append("IPC-RTT block corpus requires metric.parameters.payload_tier")
        if (
            not isinstance(payload_bytes, int)
            or isinstance(payload_bytes, bool)
            or payload_bytes < 1
        ):
            problems.append("IPC-RTT block corpus requires positive metric.parameters.payload_bytes")
        if handshake_included is not False:
            problems.append("IPC-RTT block corpus requires metric.parameters.handshake_included=false")

        for arm_name, arm in corpus_arms.items():
            artifacts = arm.get("artifacts")
            artifacts = artifacts if isinstance(artifacts, list) else []
            roles = [
                artifact.get("role")
                for artifact in artifacts
                if isinstance(artifact, dict) and isinstance(artifact.get("role"), str)
            ]
            if len(roles) != len(set(roles)):
                problems.append(f"arm {arm_name}: artifact roles are not unique")
            if publication.get("eligible") is True and not artifacts:
                problems.append(
                    f"arm {arm_name}: eligible IPC block corpus requires measured artifact provenance"
                )

    spec = _registry_metric(registry, metric_id)
    sample_class = spec.get("sample_class") if isinstance(spec, dict) else None
    registry_policies = registry.get("sample_policy") if isinstance(registry, dict) else None
    sample_policy = (
        registry_policies.get(sample_class)
        if isinstance(registry_policies, dict) and isinstance(sample_class, str)
        else None
    )
    if isinstance(sample_policy, dict) and sample_policy.get("mode") == "block-corpus":
        if eligible and (not isinstance(policy_version, int) or policy_version < 3):
            problems.append(
                "eligible block-corpus result requires publication.policy_version >= 3"
            )
        if eligible:
            if not corpus_arms:
                problems.append(
                    "eligible block-corpus metric requires at least one corpus arm"
                )
            min_blocks = sample_policy.get("sessions_min")
            min_observations = sample_policy.get("calls_per_session")
            allowed_units = sample_policy.get("allowed_block_units")
            required_stats = sample_policy.get("required_statistics")
            required_cis = sample_policy.get("required_confidence_intervals")
            for arm_name, arm in corpus_arms.items():
                corpus = arm["corpus"]
                blocks = [
                    block
                    for block in corpus.get("blocks", [])
                    if isinstance(block, dict) and block.get("valid") is True
                ]
                if isinstance(min_blocks, int) and len(blocks) < min_blocks:
                    problems.append(
                        f"arm {arm_name}: eligible block corpus has {len(blocks)} valid blocks; "
                        f"registry requires at least {min_blocks}"
                    )
                if isinstance(min_observations, int):
                    for block in blocks:
                        observations = block.get("observations")
                        if not isinstance(observations, int) or observations < min_observations:
                            problems.append(
                                f"arm {arm_name}: block {block.get('block')} has {observations} "
                                f"observations; registry requires at least {min_observations}"
                            )
                if isinstance(allowed_units, list) and corpus.get("block_unit") not in allowed_units:
                    problems.append(
                        f"arm {arm_name}: block_unit {corpus.get('block_unit')!r} is not allowed by registry"
                    )
                stats = arm.get("statistics")
                stats = stats if isinstance(stats, dict) else {}
                if isinstance(required_stats, list):
                    for statistic in required_stats:
                        value = stats.get(statistic)
                        if not isinstance(value, (int, float)) or isinstance(value, bool):
                            problems.append(
                                f"arm {arm_name}: eligible block corpus requires numeric statistics.{statistic}"
                            )
                intervals = stats.get("confidence_intervals")
                intervals = intervals if isinstance(intervals, dict) else {}
                if isinstance(required_cis, list):
                    for statistic in required_cis:
                        if not isinstance(intervals.get(statistic), dict):
                            problems.append(
                                f"arm {arm_name}: eligible block corpus requires confidence_intervals.{statistic}"
                            )

    return problems


def semantic_problems(
    document: dict[str, Any], registry: dict[str, Any] | None = None
) -> list[str]:
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

    problems: list[str] = []
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
    reason_codes = _publication_reason_codes(publication)
    if not complete:
        if publication.get("eligible") is True:
            problems.append(
                "publication policy v2 forbids eligible=true without an exact "
                "harness.path/sha256 entry in harness.modules"
            )
        if "HARNESS_MODULES_UNPROVEN" not in reason_codes:
            problems.append(
                "publication policy v2 requires HARNESS_MODULES_UNPROVEN when "
                "interpreted-harness module provenance is incomplete"
            )

    schema_version = document.get("schema_version")
    if isinstance(schema_version, int) and not isinstance(schema_version, bool) and schema_version >= 3:
        problems.extend(_corpus_problems(document, registry))
    return problems
