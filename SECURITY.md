# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately via GitHub's private vulnerability
reporting: go to the **Security** tab of this repository and click
**Report a vulnerability**. Do not open a public issue for security
problems.

You can expect an acknowledgment within 7 days. Please include steps to
reproduce and the version of Jot affected (Jot → About, or
`brew info --cask jamyc3/jot/jot`).

## Scope

Jot processes speech entirely on-device and makes no network calls except
for optional, opt-in features (model downloads, Sparkle update checks,
opt-in cloud AI). Reports about data leaving the device outside those
paths are treated as highest severity.

## Supported versions

Only the latest release receives security fixes. Update via Sparkle
(in-app) or `brew upgrade --cask jot`.
