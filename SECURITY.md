# Security Policy

> **Fork note:** QuotaBar is an independent fork of OpenUsage. This policy covers the fork's macOS
> and Windows apps.

## Reporting a Vulnerability

Report vulnerabilities through a private channel. Please keep vulnerability details out of public issues.

### Preferred: GitHub Security Advisories

Use [Report a vulnerability to QuotaBar](https://github.com/tverma101/QuotaBar/security/advisories/new)
to send a private report to this repository's maintainers.

This keeps the report private until a fix is released.

### OpenUsage Upstream

For vulnerabilities that also affect OpenUsage, use [upstream's security reporting page](https://github.com/robinebers/openusage/security/advisories/new)
or email [rob@robinebers.com](mailto:rob@robinebers.com) with the subject line "OpenUsage Security Report".

## What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Impact assessment (what can an attacker do?)

## Response Timeline

- Acknowledgment within 48 hours
- Assessment and plan within 7 days
- Fix released as soon as practical, depending on severity

## Scope

The following are in scope:

- QuotaBar for macOS and Windows
- The built-in providers (credential handling, API calls)
- The local HTTP API
- Build and release infrastructure

The following are out of scope:

- Third-party provider APIs (report to the provider directly)
- Social engineering attacks
- Denial of service attacks

## Supported Versions

Only the latest release is supported with security updates.
