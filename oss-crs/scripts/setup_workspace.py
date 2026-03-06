#!/usr/bin/env python3
"""
Create task_detail.json for FuzzingBrain from oss-crs environment variables.

Reads oss-crs standard env vars and creates the task_detail.json file that
FuzzingBrain's local service expects in the workspace directory.
"""
import json
import os
import time
import uuid


def main():
    workspace = os.environ.get("WORKSPACE", "/workspace")
    project = os.environ.get("OSS_CRS_TARGET", "unknown")
    harness = os.environ.get("OSS_CRS_TARGET_HARNESS", "")
    language = os.environ.get("FUZZING_LANGUAGE", "c")
    sanitizer = os.environ.get("SANITIZER", "address")
    mode = os.environ.get("OSS_CRS_TARGET_MODE", "")

    # Determine task type from mode or presence of diff directory
    diff_dir = os.path.join(workspace, "diff")
    if mode == "delta" or os.path.isdir(diff_dir):
        task_type = "delta"
    else:
        task_type = "full"

    # Deadline: use timeout from env or default to 4 hours
    timeout_s = int(os.environ.get("OSS_CRS_TIMEOUT", str(4 * 3600)))
    deadline_ms = int((time.time() + timeout_s) * 1000)

    task_detail = {
        "task_id": str(uuid.uuid4()),
        "type": task_type,
        "project_name": project,
        "focus": "repo",
        "deadline": deadline_ms,
        "harnesses_included": True,
        "metadata": {
            "oss_crs": "true",
            "target": project,
            "harness": harness,
            "language": language,
            "sanitizer": sanitizer,
        },
    }

    task_detail_path = os.path.join(workspace, "task_detail.json")
    with open(task_detail_path, "w") as f:
        json.dump(task_detail, f, indent=2)

    print(f"[setup_workspace] Created task_detail.json: type={task_type}, project={project}")


if __name__ == "__main__":
    main()
