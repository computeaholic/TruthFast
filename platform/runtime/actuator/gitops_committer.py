# runtime/actuator/gitops_committer.py
from __future__ import annotations

from pathlib import Path
from typing import Any


class GitOpsCommitter:
    """Commits approved plans into a Git repo as the canonical execution record."""

    def __init__(self, repo_path: str):
        self.repo = Path(repo_path)

    def commit_plan(self, plan: dict[str, Any]) -> str:
        plan_id = plan["plan_id"]
        plan_file = self.repo / "plans" / f"{plan_id}.yaml"
        plan_file.parent.mkdir(parents=True, exist_ok=True)

        plan_file.write_text(self._serialize(plan))

        # B607/B603: Safe - using hardcoded git commands with validated file paths
        # plan_file is from internal Path, plan_id from validated plan
        from git import Repo

        repo = Repo(self.repo)  # GitPython handles repository operations safely
        repo.index.add([str(plan_file)])
        repo.index.commit(f"Approved plan {plan_id}")
        commit = repo.head.commit.hexsha

        return commit

    def _serialize(self, plan: dict[str, Any]) -> str:
        import yaml

        return yaml.safe_dump(plan, sort_keys=False)
