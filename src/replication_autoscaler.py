"""Tier-based right-sizing for AWS Transform MGN replication servers.

A deployment is fixed to one target account, AWS Region, and target IAM role by
Lambda environment variables. Each invocation inventories every non-archived
AWS Transform MGN source server, sums the provisioned capacity reported for all source disks,
selects a tier target, and optionally updates the replication server type.

The function defaults to dry-run. Set ``auto_update`` to the JSON boolean
``true`` to apply updates.
"""

import json
import logging
import math
import os
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

GIB_PER_TIB = 1024.0
DEFAULT_SIZE_TIERS: List[Tuple[float, str]] = [
    (3 * GIB_PER_TIB, "m5.xlarge"),
    (6 * GIB_PER_TIB, "m5.2xlarge"),
    (10 * GIB_PER_TIB, "m5.4xlarge"),
    (14 * GIB_PER_TIB, "m5.8xlarge"),
    (20 * GIB_PER_TIB, "m5.12xlarge"),
]

INSTANCE_SIZE_RANK = {
    "nano": 0,
    "micro": 1,
    "small": 2,
    "medium": 3,
    "large": 4,
    "xlarge": 5,
    "2xlarge": 6,
    "3xlarge": 7,
    "4xlarge": 8,
    "6xlarge": 9,
    "8xlarge": 10,
    "9xlarge": 11,
    "10xlarge": 12,
    "12xlarge": 13,
    "16xlarge": 14,
    "18xlarge": 15,
    "24xlarge": 16,
    "32xlarge": 17,
    "48xlarge": 18,
    "metal": 19,
}


def _instance_size_rank(instance_type: str) -> int:
    try:
        return INSTANCE_SIZE_RANK[instance_type.rsplit(".", 1)[1]]
    except (IndexError, KeyError) as exc:
        raise ValueError(
            f"Unsupported instance-size suffix in SIZE_TIERS: {instance_type}"
        ) from exc


TARGET_ACCOUNT_ID = os.environ.get("TARGET_ACCOUNT_ID", "")
TARGET_AWS_REGION = os.environ.get("TARGET_AWS_REGION", "")
AUTOMATION_ROLE_ARN = os.environ.get("AUTOMATION_ROLE_ARN", "")
ASSUME_ROLE_SESSION_NAME = os.environ.get(
    "ASSUME_ROLE_SESSION_NAME", "MgnReplicationAutoscaler"
)
BASELINE_INSTANCE_TYPES = tuple(
    value.strip().lower()
    for value in os.environ.get(
        "BASELINE_INSTANCE_TYPES", "t3.small,t3.medium,t3.large"
    ).split(",")
    if value.strip()
)

BOTO_RETRY_CONFIG = BotoConfig(
    retries={"max_attempts": 5, "mode": "adaptive"},
)


def _load_size_tiers() -> List[Tuple[float, str]]:
    """Load and strictly validate the optional SIZE_TIERS JSON value."""
    raw = os.environ.get("SIZE_TIERS")
    if raw is None or raw.strip() == "":
        return list(DEFAULT_SIZE_TIERS)

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"SIZE_TIERS must be valid JSON: {exc}") from exc

    if not isinstance(parsed, list) or not parsed:
        raise ValueError("SIZE_TIERS must be a non-empty JSON array")

    tiers: List[Tuple[float, str]] = []
    for index, item in enumerate(parsed):
        if not isinstance(item, list) or len(item) != 2:
            raise ValueError(
                f"SIZE_TIERS[{index}] must be [min_gib, instance_type]"
            )
        min_gib, instance_type = item
        if isinstance(min_gib, bool) or not isinstance(min_gib, (int, float)):
            raise ValueError(f"SIZE_TIERS[{index}].min_gib must be numeric")
        min_gib = float(min_gib)
        if not math.isfinite(min_gib) or min_gib <= 0:
            raise ValueError(f"SIZE_TIERS[{index}].min_gib must be positive")
        if not isinstance(instance_type, str) or not instance_type.strip():
            raise ValueError(
                f"SIZE_TIERS[{index}].instance_type must be a non-empty string"
            )
        tiers.append((min_gib, instance_type.strip().lower()))

    tiers.sort(key=lambda tier: tier[0])
    thresholds = [tier[0] for tier in tiers]
    targets = [tier[1] for tier in tiers]
    if len(thresholds) != len(set(thresholds)):
        raise ValueError("SIZE_TIERS thresholds must be unique")
    if len(targets) != len(set(targets)):
        raise ValueError("SIZE_TIERS instance types must be unique")
    ranks = [_instance_size_rank(instance_type) for instance_type in targets]
    if any(current >= following for current, following in zip(ranks, ranks[1:])):
        raise ValueError(
            "SIZE_TIERS instance sizes must increase as thresholds increase"
        )
    return tiers


SIZE_TIERS = _load_size_tiers()


def _validate_runtime_config() -> None:
    if not re.fullmatch(r"\d{12}", TARGET_ACCOUNT_ID):
        raise ValueError("TARGET_ACCOUNT_ID must be a 12-digit AWS account ID")
    if not re.fullmatch(r"[a-z]{2}(?:-gov)?-[a-z]+-\d", TARGET_AWS_REGION):
        raise ValueError("TARGET_AWS_REGION is not a valid AWS Region name")
    role_match = re.fullmatch(
        r"arn:[^:]+:iam::(\d{12}):role/.+", AUTOMATION_ROLE_ARN
    )
    if not role_match or role_match.group(1) != TARGET_ACCOUNT_ID:
        raise ValueError(
            "AUTOMATION_ROLE_ARN must be a role ARN in TARGET_ACCOUNT_ID"
        )
    if not re.fullmatch(r"[\w+=,.@-]{2,64}", ASSUME_ROLE_SESSION_NAME):
        raise ValueError("ASSUME_ROLE_SESSION_NAME is not a valid STS session name")
    if not BASELINE_INSTANCE_TYPES:
        raise ValueError("BASELINE_INSTANCE_TYPES must contain at least one type")


def _extract_event_payload(event: Any) -> Dict[str, Any]:
    if not isinstance(event, dict):
        raise ValueError("Invocation event must be a JSON object")
    detail = event.get("detail")
    if detail is not None:
        if not isinstance(detail, dict):
            raise ValueError("EventBridge detail must be a JSON object")
        return dict(detail)
    return dict(event)


def _parse_bool(payload: Dict[str, Any], key: str, default: bool = False) -> bool:
    value = payload.get(key, default)
    if type(value) is not bool:  # bool is intentionally strict; strings are rejected.
        raise ValueError(f"{key} must be a JSON boolean")
    return value


def _validate_event_target(payload: Dict[str, Any]) -> None:
    supplied_account = payload.get("target_account_id")
    supplied_region = payload.get("aws_region")
    if supplied_account is not None and supplied_account != TARGET_ACCOUNT_ID:
        raise ValueError("target_account_id does not match this deployment")
    if supplied_region is not None and supplied_region != TARGET_AWS_REGION:
        raise ValueError("aws_region does not match this deployment")


# Minimum STS session duration. It exceeds the Lambda timeout, so credentials
# never expire mid-run, and limits the useful lifetime of the credentials.
ASSUME_ROLE_DURATION_SECONDS = 900


def _assume_role_session() -> boto3.Session:
    """Return a session for the target role.

    The temporary credentials stay in memory for this invocation only. They are
    never logged, persisted, or included in the function response.
    """
    sts_client = boto3.client(
        "sts", region_name=TARGET_AWS_REGION, config=BOTO_RETRY_CONFIG
    )
    response = sts_client.assume_role(
        RoleArn=AUTOMATION_ROLE_ARN,
        RoleSessionName=ASSUME_ROLE_SESSION_NAME,
        DurationSeconds=ASSUME_ROLE_DURATION_SECONDS,
    )
    credentials = response["Credentials"]
    return boto3.Session(
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
        region_name=TARGET_AWS_REGION,
    )


def select_target_instance_type(source_capacity_gib: float) -> Optional[str]:
    """Return the highest tier target met by the source capacity."""
    target: Optional[str] = None
    for min_gib, instance_type in SIZE_TIERS:
        if source_capacity_gib < min_gib:
            break
        target = instance_type
    return target


def _upgrade_decision(current: Any, target: Optional[str]) -> Tuple[bool, str]:
    """Allow baseline-to-tier and lower-tier-to-higher-tier transitions only."""
    if target is None:
        return False, "below the smallest size tier"
    if not isinstance(current, str) or not current.strip():
        return False, "current replication instance type is unavailable"

    current = current.strip().lower()
    target = target.lower()
    if current == target:
        return False, "already at the tier target"
    if current in BASELINE_INSTANCE_TYPES:
        try:
            if _instance_size_rank(target) > _instance_size_rank(current):
                return True, "current type is in the configured baseline set"
        except ValueError:
            return False, "configured baseline type has an unsupported size suffix"
        return False, "target would not be an upgrade"

    ordered_targets = [instance_type for _, instance_type in SIZE_TIERS]
    if current not in ordered_targets:
        return False, "current type is outside the managed baseline and tier sets"
    if ordered_targets.index(target) > ordered_targets.index(current):
        return True, "source capacity moved to a higher configured tier"
    return False, "target would not be an upgrade"


def _hostname(source_server: Dict[str, Any]) -> Optional[str]:
    source_properties = source_server.get("sourceProperties")
    if not isinstance(source_properties, dict):
        return None
    identification_hints = source_properties.get("identificationHints")
    if not isinstance(identification_hints, dict):
        return None
    hostname = identification_hints.get("hostname")
    return hostname if isinstance(hostname, str) else None


def list_source_servers() -> List[Dict[str, Optional[str]]]:
    session = _assume_role_session()
    client = session.client("mgn", config=BOTO_RETRY_CONFIG)
    servers: List[Dict[str, Optional[str]]] = []
    paginator = client.get_paginator("describe_source_servers")
    for page in paginator.paginate(filters={"isArchived": False}):
        for server in page.get("items", []):
            source_server_id = server.get("sourceServerID")
            if source_server_id:
                servers.append(
                    {
                        "sourceServerID": source_server_id,
                        "hostname": _hostname(server),
                    }
                )
    return servers


def _source_disk_inventory(
    source_server: Dict[str, Any],
) -> Tuple[List[Dict[str, Any]], float, bool]:
    disks: List[Dict[str, Any]] = []
    total_gib = 0.0
    source_properties = source_server.get("sourceProperties")
    if not isinstance(source_properties, dict):
        return disks, total_gib, False

    source_disks = source_properties.get("disks")
    if not isinstance(source_disks, list) or not source_disks:
        return disks, total_gib, False

    inventory_complete = True
    for disk in source_disks:
        if not isinstance(disk, dict):
            disks.append({"deviceName": "unknown", "sourceCapacityGiB": None})
            inventory_complete = False
            continue

        size_bytes = disk.get("bytes")
        size_gib: Optional[float] = None
        if (
            isinstance(size_bytes, (int, float))
            and not isinstance(size_bytes, bool)
            and math.isfinite(float(size_bytes))
            and size_bytes > 0
        ):
            size_gib = float(size_bytes) / (1024**3)
            total_gib += size_gib
        else:
            inventory_complete = False
        disks.append(
            {
                "deviceName": disk.get("deviceName", "unknown"),
                "sourceCapacityGiB": round(size_gib, 2) if size_gib is not None else None,
            }
        )
    return disks, total_gib, inventory_complete


def list_disk_settings(*, auto_update: bool = False) -> List[Dict[str, Any]]:
    """Evaluate all non-archived AWS Transform MGN source servers in the configured target."""
    session = _assume_role_session()
    client = session.client("mgn", config=BOTO_RETRY_CONFIG)
    paginator = client.get_paginator("describe_source_servers")
    results: List[Dict[str, Any]] = []
    failures: List[Dict[str, str]] = []

    for page in paginator.paginate(filters={"isArchived": False}):
        for server in page.get("items", []):
            source_server_id = server.get("sourceServerID")
            if not source_server_id:
                continue

            disks, source_capacity_gib, inventory_complete = _source_disk_inventory(server)
            entry: Dict[str, Any] = {
                "sourceServerID": source_server_id,
                "hostname": _hostname(server),
                "size_source": "sourceProperties.disks[].bytes",
                "inventory_complete": inventory_complete,
                "disks": disks,
                "source_capacity_gib": round(source_capacity_gib, 2),
                "replication_instance_check": {},
            }
            check = entry["replication_instance_check"]

            try:
                replication_config = client.get_replication_configuration(
                    sourceServerID=source_server_id
                )
                current = replication_config.get("replicationServerInstanceType")
                if not inventory_complete:
                    check.update(
                        {
                            "current_instance": current,
                            "target_instance": None,
                            "meets_size_tier": False,
                            "should_update": False,
                            "decision_reason": "source disk capacity inventory is incomplete",
                        }
                    )
                    results.append(entry)
                    continue

                target = select_target_instance_type(source_capacity_gib)
                should_update, reason = _upgrade_decision(current, target)
                check.update(
                    {
                        "current_instance": current,
                        "target_instance": target,
                        "meets_size_tier": target is not None,
                        "should_update": should_update,
                        "decision_reason": reason,
                    }
                )

                if should_update and not auto_update:
                    check["dry_run"] = True
                    logger.info(
                        "[DRY-RUN] %s (%s): %s -> %s (%.0f GiB source capacity)",
                        source_server_id,
                        entry["hostname"] or "hostname unavailable",
                        current,
                        target,
                        source_capacity_gib,
                    )
                elif should_update:
                    client.update_replication_configuration(
                        sourceServerID=source_server_id,
                        replicationServerInstanceType=target,
                    )
                    check.update({"updated": True, "new_instance": target})
                    logger.info(
                        "Updated %s: %s -> %s (%.0f GiB source capacity)",
                        source_server_id,
                        current,
                        target,
                        source_capacity_gib,
                    )
            except (ClientError, BotoCoreError) as exc:
                # Record and continue so one server cannot block the rest of the fleet;
                # the invocation still fails at the end so retries and the DLQ engage.
                message = str(exc)
                check["error"] = message
                failures.append({"sourceServerID": source_server_id, "error": message})
                logger.exception("Failed processing source server %s", source_server_id)

            results.append(entry)

    if failures:
        summary = {"failed_count": len(failures), "failures": failures}
        logger.error("Invocation completed with failures: %s", json.dumps(summary))
        raise RuntimeError(json.dumps(summary))
    return results


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Lambda entry point for direct or EventBridge invocation."""
    _validate_runtime_config()
    payload = _extract_event_payload(event)
    _validate_event_target(payload)
    action = payload.get("action", "list_disks")
    if not isinstance(action, str):
        raise ValueError("action must be a string")
    action = action.strip().lower()
    auto_update = _parse_bool(payload, "auto_update", False)

    logger.info(
        "Invoked target_account=%s region=%s action=%s auto_update=%s tiers=%s",
        TARGET_ACCOUNT_ID,
        TARGET_AWS_REGION,
        action,
        auto_update,
        SIZE_TIERS,
    )

    if action == "list_servers":
        results: Sequence[Dict[str, Any]] = list_source_servers()
    elif action == "list_disks":
        results = list_disk_settings(auto_update=auto_update)
    else:
        raise ValueError("action must be 'list_disks' or 'list_servers'")

    return {
        "status": "SUCCESS",
        "action": action,
        "count": len(results),
        "results": results,
    }
