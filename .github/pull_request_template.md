## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Type

- [ ] `feat:` / `fix:` — changes the chart, so the next release picks it up
- [ ] `docs:` / `chore:` / `ci:` / `test:` — does not release a new chart version

<!-- Commit prefixes drive the chart version and the changelog (RELEASING.md). -->

## Checklist

- [ ] `helm lint chart -f chart/ci/test-values.yaml` passes
- [ ] `helm template ci chart -f chart/ci/test-values.yaml` renders, and the chart
      still *refuses* to render with no site values
- [ ] `shellcheck -S warning chart/files/serve.sh chart/files/wait-for-worker.sh scripts/*.sh ansible/init-vault.sh`
- [ ] `scripts/check-anchors.sh` passes
- [ ] `actionlint .github/workflows/*.yml` passes (if workflows changed)
- [ ] `ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/site.yml --syntax-check` (if playbooks changed)
- [ ] No secrets, tokens, real addresses, hostnames or private checkpoint paths added
- [ ] `SYNC.md`, `ENVS.md` and `RELEASING.md` updated if serving parameters or release behaviour changed

## Verification

<!-- What you actually ran, and what it printed. -->

## Notes for reviewers

<!-- Known gaps, follow-ups, or things you could not test without the hardware. -->
