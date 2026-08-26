## Description

Briefly describe the changes introduced by this pull request.

- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature causing existing behavior to change)
- [ ] Documentation update
- [ ] Performance / Tuning optimization

## Testing & Verification

Describe the tests you ran to verify your changes:

- [ ] Local ShellCheck (`shellcheck install_unbound_interactive.sh lib/*.sh setup.sh`)
- [ ] Automated test suite passed (`./tests/test_suite.sh`)
- [ ] Tested inside an Alpine Linux LXC / VM container
- [ ] Verified DNS resolution (`dig @127.0.0.1 google.com`)
- [ ] Verified DNSSEC validation (`dig @127.0.0.1 -p 5335 dnssec-failed.org`)

## Checklist

- [ ] My code adheres to the project's coding style and Karpathy simplicity guidelines.
- [ ] I have updated the documentation (`README.md`, `CHANGELOG.md`) if applicable.
- [ ] No extraneous dependencies or heavy packages introduced.
