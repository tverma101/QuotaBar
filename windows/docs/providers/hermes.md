# Hermes

Enable Hermes in QuotaBar to see Today, This Week, This Month, and Usage Trend for the local Hermes Agent installation. QuotaBar reads `state.db` from `HERMES_HOME`, or from `%USERPROFILE%\.hermes` if the variable isn't set. The database is read-only and no network request is made.

Tokens include input, output, cache reads/writes and reasoning. An active session may still be writing its usage, and a period without complete recorded pricing shows tokens without a dollar total. Usage billed through OpenCode is excluded from Hermes and counted on the OpenCode card instead when both providers are enabled.
