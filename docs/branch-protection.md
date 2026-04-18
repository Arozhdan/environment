# Branch protection (GitHub example)

In **Settings → Branches → Branch protection rule** for `main`:

1. **Require a pull request before merging**
   - Require approvals: ≥ 1 (or 2 for sensitive repos)
2. **Require status checks to pass**
   - Required checks: `validate`, `yamllint` (from `.github/workflows/ci.yaml`)
3. **Require conversation resolution**
4. **Do not allow bypassing** the above for admins (recommended)
5. **Include administrators** (optional, stricter)

For GitLab/Gittea, mirror the same ideas with merge requests and pipeline gates.
