# Contributing to server-compliance

This is an open-source Linux compliance pipeline built on cinc-auditor, Grafana Alloy, and Grafana Cloud. Contributions are welcome.

## Ways to contribute

- **Bug reports** — open a GitHub Issue with steps to reproduce, expected behaviour, and actual behaviour.
- **Feature requests** — open an Issue describing the use-case and why it matters.
- **Pull requests** — see the workflow below.
- **Waiver contributions** — if you have justified waivers for a control on a specific platform, PRs are welcome.

## Development setup

You will need:
- `shellcheck` for linting shell scripts (`brew install shellcheck` or `sudo apt install shellcheck`)
- `ansible-lint` if editing Ansible roles (`pip install ansible-lint`)
- `curl` and `jq` for testing deploy scripts

Run the linter suite:

```bash
./scripts/lint.sh
```

## Pull request workflow

1. Fork the repository and create a feature branch from `main`.
2. Make your changes.
3. Run `./scripts/lint.sh` and fix any shellcheck warnings.
4. Open a PR against `main` with a clear description of the change and why it is needed.
5. PRs that touch Ansible roles should note which Ubuntu version(s) they were tested against.

## Coding conventions

- **Shell scripts** — follow shellcheck recommendations; use `set -euo pipefail`; prefer `[[ ]]` for tests.
- **Ansible** — use fully-qualified module names (`ansible.builtin.*`); tasks must be idempotent.
- **Waiver files** — every waiver entry must include `justification` and `expiration_date`.
- **Python** — standard library only inside heredocs/scripts; follow PEP 8.

## Commit messages

Use the conventional commits style:

```
fix: prevent stderr swallowing in verify.sh
feat: add CONTRIBUTING and SECURITY docs
chore: extract shared gf_api helper into grafana-lib.sh
```

## Reporting security issues

Do **not** open a public GitHub Issue for security vulnerabilities. See [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contributions will be licensed under the [Apache 2.0 License](LICENSE).
