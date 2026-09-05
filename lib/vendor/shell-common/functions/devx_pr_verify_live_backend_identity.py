#!/usr/bin/env python3
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/devx_pr_verify_live_backend_identity.py
# Synced 2026-09-05T10:16Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/functions/devx_pr_verify_live_backend_identity.py
# Python backend identity verification helper. Orchestrates the fallback ladder
# to check if the running backend contains the target commit.
#
# Ladder:
#   A. host PID/cwd ancestry
#   B. docker exec git ancestry
#   C. container internal file/route presence check (heuristic)
#   D. build SHA/version endpoint query (can run as part of endpoint checks)

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request


def run_cmd(cmd, cwd=None):
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, check=False)
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except Exception as e:
        return -1, "", str(e)


def main():
    parser = argparse.ArgumentParser(description="Verify backend serving identity")
    parser.add_argument("--repo-root", required=True, help="Host repository root directory")
    parser.add_argument("--target-repo", required=True, help="GitHub repository owner/repo")
    parser.add_argument("--target-sha", required=True, help="Target mergeCommit.oid or headRefOid")
    parser.add_argument("--base-url", required=True, help="Frontend base URL")
    parser.add_argument("--backend-ports", default="", help="Comma-separated candidate backend ports")
    parser.add_argument("--container-name", default=None, help="Explicit container name/ID")
    args = parser.parse_args()

    logs = []

    def log(msg):
        logs.append(msg)
        sys.stderr.write(f"[backend-identity] {msg}\n")
        sys.stderr.flush()

    log(f"Starting verification: target_sha={args.target_sha}, ports={args.backend_ports}")

    # Parse ports
    ports = [p.strip() for p in args.backend_ports.split(",") if p.strip()]
    ports_regex = "|".join(ports) if ports else ""

    # =========================================================================
    # Rung A: Host PID/cwd ancestry check
    # =========================================================================
    pids = set()
    if ports:
        log("Rung A: Checking host PID/cwd ancestry...")
        # Check Linux
        if os.path.exists("/proc"):
            ret, out, err = run_cmd(["ss", "-ltnp"])
            if ret == 0:
                for line in out.splitlines():
                    for port in ports:
                        has_port = (
                            f":{port} " in line
                            or f":{port}\t" in line
                            or (len(line.split()) > 3 and f":{port}" in line.split()[3])
                        )
                        if has_port:
                            m = re.search(r"pid=(\d+)", line)
                            if m:
                                pids.add(int(m.group(1)))
            else:
                log(f"ss -ltnp failed: {err}")

        # Check macOS / other via lsof
        if not pids and shutil.which("lsof"):
            for port in ports:
                ret, out, err = run_cmd(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"])
                if ret == 0:
                    for line in out.splitlines()[1:]:
                        parts = line.split()
                        if len(parts) > 1:
                            try:
                                pids.add(int(parts[1]))
                            except ValueError:
                                pass
                else:
                    log(f"lsof failed for port {port}: {err}")

    # Filter out docker processes from host PIDs
    non_docker_pids = set()
    for pid in pids:
        ret, comm, _ = run_cmd(["ps", "-p", str(pid), "-o", "comm="])
        comm_clean = comm.strip() if ret == 0 else ""
        if comm_clean in ("docker-proxy", "dockerd", "containerd", "docker"):
            log(f"PID {pid} belongs to docker ({comm_clean}), skipping host check.")
        else:
            non_docker_pids.add(pid)

    for pid in non_docker_pids:
        log(f"Checking non-docker host PID: {pid}")
        cwd = None
        if os.path.exists(f"/proc/{pid}/cwd"):
            try:
                cwd = os.readlink(f"/proc/{pid}/cwd")
            except Exception as e:
                log(f"readlink failed for PID {pid}: {e}")
        else:
            # lsof fallback
            ret, out, _ = run_cmd(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
            if ret == 0:
                for line in out.splitlines():
                    if line.startswith("n"):
                        cwd = line[1:]
                        break
        if cwd:
            ret, git_root, _ = run_cmd(["git", "rev-parse", "--show-toplevel"], cwd=cwd)
            if ret == 0 and git_root:
                log(f"Found host git repo at {git_root}")
                ret, _, _ = run_cmd(["git", "-C", git_root, "merge-base", "--is-ancestor", args.target_sha, "HEAD"])
                ret_sha, HEAD_sha, _ = run_cmd(["git", "rev-parse", "HEAD"], cwd=git_root)
                observed_sha = HEAD_sha if ret_sha == 0 else "unknown"
                if ret == 0:
                    log(f"Host PID {pid} verified successfully.")
                    result = {
                        "result": "verified",
                        "layer": "backend",
                        "mode": "host-pid-ancestry",
                        "container": "",
                        "target_sha": args.target_sha,
                        "observed_sha": observed_sha,
                        "evidence": [f"host PID/cwd ancestry success: process {pid} in {cwd}"],
                        "logs": logs,
                    }
                    print(json.dumps(result))
                    sys.exit(0)
                else:
                    log(f"Host PID {pid} serving {observed_sha} mismatch: {args.target_sha} is not an ancestor.")
                    result = {
                        "result": "mismatch",
                        "layer": "backend",
                        "mode": "host-pid-ancestry",
                        "container": "",
                        "target_sha": args.target_sha,
                        "observed_sha": observed_sha,
                        "evidence": [
                            f"host PID/cwd ancestry failed: target SHA {args.target_sha} "
                            f"not in ancestry of HEAD ({observed_sha}) in {git_root}"
                        ],
                        "logs": logs,
                    }
                    print(json.dumps(result))
                    sys.exit(0)

    # =========================================================================
    # Rung B: Docker exec git ancestry check
    # =========================================================================
    docker_available = False
    if shutil.which("docker"):
        ret, _, _ = run_cmd(["docker", "ps"])
        if ret == 0:
            docker_available = True

    containers = []
    if docker_available:
        log("Rung B: Checking docker containers...")
        if args.container_name:
            containers = [args.container_name]
        elif ports_regex:
            ret, out, _ = run_cmd(["docker", "ps", "--format", "{{.Names}} {{.Ports}}"])
            if ret == 0:
                for line in out.splitlines():
                    parts = line.split()
                    if len(parts) >= 2:
                        name = parts[0]
                        ports_str = " ".join(parts[1:])
                        if re.search(rf"\b({ports_regex})\b", ports_str):
                            containers.append(name)
            log(f"Found candidate containers by port mapping: {containers}")

    verified_container = None
    mismatched_container = None
    unverified_reasons = {}

    for container in containers:
        log(f"Inspecting container: {container}")
        ret, inspect_out, err = run_cmd(["docker", "inspect", container])
        if ret != 0 or not inspect_out:
            log(f"Failed to inspect {container}: {err}")
            unverified_reasons[container] = "inspect_failed"
            continue
        try:
            inspect_data = json.loads(inspect_out)
            if not inspect_data:
                continue
            container_info = inspect_data[0]
        except Exception as e:
            log(f"Failed to parse inspect JSON for {container}: {e}")
            unverified_reasons[container] = "inspect_parse_failed"
            continue

        mounts = container_info.get("Mounts", [])
        workdir = container_info.get("Config", {}).get("WorkingDir", "")
        log(f"Container {container} has workdir={workdir}, mounts count={len(mounts)}")

        # Build git root candidates inside container
        candidates = []
        for m in mounts:
            src = m.get("Source", "")
            dest = m.get("Destination", "")
            if src and dest:
                try:
                    common = os.path.commonpath([os.path.abspath(src), os.path.abspath(args.repo_root)])
                    if common == os.path.abspath(src):
                        rel = os.path.relpath(args.repo_root, src)
                        dest_repo_root = os.path.join(dest, rel) if rel != "." else dest
                        candidates.append(dest_repo_root)
                    elif common == os.path.abspath(args.repo_root):
                        candidates.append(dest)
                except Exception:
                    pass

        if workdir:
            candidates.append(workdir)
        candidates.extend(["/app", "/workspace"])

        # De-duplicate preserving order
        unique_candidates = []
        for c in candidates:
            if c not in unique_candidates:
                unique_candidates.append(c)

        log(f"Container {container} candidates: {unique_candidates}")
        resolved_git_root = None
        for cand in unique_candidates:
            ret, toplevel, _ = run_cmd(["docker", "exec", container, "git", "-C", cand, "rev-parse", "--show-toplevel"])
            if ret == 0 and toplevel:
                resolved_git_root = toplevel
                break

        if resolved_git_root:
            log(f"Resolved git repository inside {container} at {resolved_git_root}")
            # Check ancestry
            ret, _, _ = run_cmd(
                [
                    "docker",
                    "exec",
                    container,
                    "git",
                    "-C",
                    resolved_git_root,
                    "merge-base",
                    "--is-ancestor",
                    args.target_sha,
                    "HEAD",
                ]
            )
            ret_sha, HEAD_sha, _ = run_cmd(
                ["docker", "exec", container, "git", "-C", resolved_git_root, "rev-parse", "HEAD"]
            )
            observed_sha = HEAD_sha if ret_sha == 0 else "unknown"
            if ret == 0:
                log(f"Container {container} verified successfully.")
                verified_container = (container, resolved_git_root, observed_sha)
                break
            else:
                log(f"Container {container} git check failed: {args.target_sha} not in ancestry of {observed_sha}")
                mismatched_container = (container, resolved_git_root, observed_sha)
        else:
            unverified_reasons[container] = "no_git_repository_found"

    if verified_container:
        container, resolved_git_root, obs_sha = verified_container
        result = {
            "result": "verified",
            "layer": "backend",
            "mode": "docker-exec-git",
            "container": container,
            "target_sha": args.target_sha,
            "observed_sha": obs_sha,
            "evidence": [
                f"docker-exec-git: target_sha is ancestor of HEAD in container {container} at {resolved_git_root}"
            ],
            "logs": logs,
        }
        print(json.dumps(result))
        sys.exit(0)

    if mismatched_container:
        container, resolved_git_root, obs_sha = mismatched_container
        result = {
            "result": "mismatch",
            "layer": "backend",
            "mode": "docker-exec-git",
            "container": container,
            "target_sha": args.target_sha,
            "observed_sha": obs_sha,
            "evidence": [
                f"docker-exec-git failed: target_sha {args.target_sha} "
                f"not in ancestry of HEAD ({obs_sha}) "
                f"in container {container} at {resolved_git_root}"
            ],
            "logs": logs,
        }
        print(json.dumps(result))
        sys.exit(0)

    # =========================================================================
    # Rung D: Version / build SHA endpoint query
    # =========================================================================
    if ports:
        log("Rung D: Querying version / build SHA endpoints...")
        version_urls = []
        for port in ports:
            for path in ("/version", "/api/version", "/api/v1/version", "/health"):
                version_urls.append(f"http://127.0.0.1:{port}{path}")

        for url in version_urls:
            log(f"Querying: {url}")
            try:
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=2) as resp:
                    if resp.status == 200:
                        body = resp.read().decode("utf-8", errors="ignore")
                        log(f"Response: {body}")
                        sha = None
                        try:
                            data = json.loads(body)
                            for key in ("sha", "commit", "git_sha", "git_commit", "gitCommit", "gitSha"):
                                if key in data and isinstance(data[key], str):
                                    sha = data[key]
                                    break
                        except Exception:
                            body_clean = body.strip()
                            if re.match(r"^[0-9a-fA-F]{7,40}$", body_clean):
                                sha = body_clean

                        if sha:
                            log(f"Extracted SHA {sha} from {url}")
                            if args.target_sha.startswith(sha) or sha.startswith(args.target_sha):
                                result = {
                                    "result": "verified",
                                    "layer": "backend",
                                    "mode": "version-endpoint",
                                    "container": "",
                                    "target_sha": args.target_sha,
                                    "observed_sha": sha,
                                    "evidence": [f"API version endpoint {url} returned matching SHA {sha}"],
                                    "logs": logs,
                                }
                                print(json.dumps(result))
                                sys.exit(0)
                            else:
                                result = {
                                    "result": "mismatch",
                                    "layer": "backend",
                                    "mode": "version-endpoint",
                                    "container": "",
                                    "target_sha": args.target_sha,
                                    "observed_sha": sha,
                                    "evidence": [
                                        f"API version endpoint {url} returned different SHA {sha} "
                                        f"(expected {args.target_sha})"
                                    ],
                                    "logs": logs,
                                }
                                print(json.dumps(result))
                                sys.exit(0)
            except Exception as e:
                log(f"Request failed for {url}: {e}")

    # =========================================================================
    # Rung C: Container internal file/route presence check
    # =========================================================================
    container_evidence = []
    if docker_available and containers:
        log("Rung C: Checking container files / routes presence...")
        # Get list of files changed in commit
        ret, files_out, _ = run_cmd(
            ["git", "diff", "--name-only", f"{args.target_sha}~1", args.target_sha], cwd=args.repo_root
        )
        if ret != 0 or not files_out:
            ret, files_out, _ = run_cmd(
                ["git", "show", "--name-only", "--pretty=format:", args.target_sha], cwd=args.repo_root
            )

        changed_files = [f.strip() for f in files_out.splitlines() if f.strip()] if ret == 0 else []
        backend_files = []
        for f in changed_files:
            if "apps/web" in f or "frontend" in f:
                continue
            is_backend = (
                "apps/server" in f
                or "server/" in f
                or "backend/" in f
                or f.endswith((".py", ".js", ".ts", ".go", ".rs"))
            )
            if is_backend:
                backend_files.append(f)

        log(f"Target backend files changed: {backend_files}")

        if backend_files:
            for container in containers:
                ret, inspect_out, _ = run_cmd(["docker", "inspect", container])
                if ret != 0 or not inspect_out:
                    continue
                try:
                    container_info = json.loads(inspect_out)[0]
                except Exception:
                    continue

                mounts = container_info.get("Mounts", [])
                workdir = container_info.get("Config", {}).get("WorkingDir", "/app")

                resolved_paths = []
                for f in backend_files:
                    mapped = False
                    for m in mounts:
                        src = m.get("Source", "")
                        dest = m.get("Destination", "")
                        if src and dest:
                            full_host_path = os.path.join(args.repo_root, f)
                            try:
                                common = os.path.commonpath([src, full_host_path])
                                if common == src:
                                    rel = os.path.relpath(full_host_path, src)
                                    resolved_paths.append((f, os.path.join(dest, rel) if rel != "." else dest))
                                    mapped = True
                                    break
                            except Exception:
                                pass
                    if not mapped:
                        resolved_paths.append((f, os.path.join(workdir or "/app", f)))

                existing_files = []
                for rel_path, cont_path in resolved_paths:
                    ret, _, _ = run_cmd(["docker", "exec", container, "test", "-f", cont_path])
                    if ret == 0:
                        existing_files.append((rel_path, cont_path))

                lines_matched = []
                for rel_path, cont_path in existing_files:
                    ret_diff, diff_out, _ = run_cmd(
                        ["git", "diff", "-U0", f"{args.target_sha}~1", args.target_sha, "--", rel_path],
                        cwd=args.repo_root,
                    )
                    if ret_diff == 0 and diff_out:
                        added_lines = []
                        for line in diff_out.splitlines():
                            if line.startswith("+") and not line.startswith("+++"):
                                clean = line[1:].strip()
                                keywords = ("def ", "router", "app.", "route", "api", "path", "class ", "import ")
                                if len(clean) > 10 and any(kw in clean for kw in keywords):
                                    added_lines.append(clean)

                        for line in added_lines[:5]:
                            ret_grep, _, _ = run_cmd(["docker", "exec", container, "grep", "-F", line, cont_path])
                            if ret_grep == 0:
                                lines_matched.append(f"container {container}:{cont_path} contains code: {line}")

                if existing_files:
                    evidence_entry = (
                        f"container {container} contains {len(existing_files)}/"
                        f"{len(resolved_paths)} modified backend files"
                    )
                    if lines_matched:
                        evidence_entry += f" and matches {len(lines_matched)} added lines"
                    container_evidence.append(evidence_entry)
                    container_evidence.extend(lines_matched)

    if container_evidence:
        result = {
            "result": "unverified",
            "layer": "backend",
            "evidence": ["container-file-route presence check successful"] + container_evidence,
            "logs": logs,
            "reason": (
                "git ancestry check was not possible in container (no git inside container), "
                "but file/route presence matches the target commit"
            ),
        }
        print(json.dumps(result))
        sys.exit(0)

    # =========================================================================
    # Fallback to Unverified
    # =========================================================================
    reason = "no host PID found, no matching docker containers found, or docker not available"
    if containers:
        container_reasons = [f"{c}:{unverified_reasons.get(c, 'unknown')}" for c in containers]
        reason = (
            f"containers {containers} found but could not verify git ancestry/files ({', '.join(container_reasons)})"
        )

    result = {"result": "unverified", "layer": "backend", "evidence": [], "logs": logs, "reason": reason}
    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
