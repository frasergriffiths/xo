#!/usr/bin/env python3
"""Static checks for the GitHub Actions workflows.

GitHub rejects a workflow file, with zero jobs and no useful log, when a job
lacks a runner or the dependency graph is broken. Catching that here turns a
mystery red run into a failed local check with a line number.

Deliberately dependency-free apart from PyYAML, which CI already provides.
"""

import pathlib
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is present in CI
    sys.exit("error: PyYAML is required (pip install pyyaml)")

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

failures = []


def check_job_runs_on(path, name, job):
    """A job must declare a runner, or call a reusable workflow that has one.

    GitHub rejects the whole file when this is missing, so the failure surfaces
    as a run with no jobs rather than as an error on the job that is missing it.
    """
    if "uses" in job:
        return
    if "runs-on" not in job:
        failures.append(f"{path.name}: job {name!r} has neither 'runs-on' nor 'uses'")


def check_needs(path, name, job, job_names):
    needs = job.get("needs", [])
    if isinstance(needs, str):
        needs = [needs]
    for dependency in needs:
        if dependency not in job_names:
            failures.append(f"{path.name}: job {name!r} needs unknown job {dependency!r}")


def check_job_steps(path, name, job):
    # A reusable-workflow call has no steps of its own.
    if "uses" in job:
        return
    if not job.get("steps"):
        failures.append(f"{path.name}: job {name!r} has no steps")


def check_workflow(path):
    workflow = yaml.safe_load(path.read_text())
    if not isinstance(workflow, dict):
        failures.append(f"{path.name}: is not a workflow mapping")
        return

    # PyYAML parses the bare key `on` as boolean True.
    if workflow.get("on", workflow.get(True)) is None:
        failures.append(f"{path.name}: has no 'on:' trigger")

    jobs = workflow.get("jobs")
    if not jobs:
        failures.append(f"{path.name}: declares no jobs")
        return

    job_names = set(jobs)
    for name, job in jobs.items():
        if not isinstance(job, dict):
            failures.append(f"{path.name}: job {name!r} is not a mapping")
            continue
        check_job_runs_on(path, name, job)
        check_needs(path, name, job, job_names)
        check_job_steps(path, name, job)


def main():
    paths = sorted(WORKFLOWS.glob("*.yml"))
    if not paths:
        print(f"error: no workflows found in {WORKFLOWS}", file=sys.stderr)
        return 1

    for path in paths:
        check_workflow(path)

    if failures:
        print("error: workflow validation failed", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"workflow validation: ok ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())