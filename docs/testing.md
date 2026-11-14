# Testing QuotaBar

The SwiftPM package contains XCTest and Swift Testing cases. There are also Python pricing codec tests and shell regression tests for the measurement driver and CI workflow. A green `swift test` alone does **not** run those other suites.

## Run the CI-equivalent suites

From the repository root on macOS 15 or later:

```sh
swift build -j 2 --disable-index-store
bash script/test_suites.sh
```

`test_suites.sh` checks the CI workflow, exercises the shell measurement driver using a fake `swift` executable, runs every `*Tests.py` unittest file, then runs the complete SwiftPM test set (XCTest and Swift Testing). It fails if any command fails. All tests run without provider credentials unless they are explicitly opted into live validation.

The default is two Swift build/test jobs, with indexing disabled to lower peak memory use on smaller Macs. Override concurrency with `QUOTABAR_TEST_JOBS=1 bash script/test_suites.sh` if needed. Lower concurrency reduces memory pressure; it does not fix a real compiler or assertion failure.

## Focused efficiency tests

```sh
bash script/test_efficiency.sh
```

This uses one `swift test` process with a combined filter instead of repeatedly starting SwiftPM. It is a developer convenience, **not** a substitute for the full suites above.

## Interpreting skips

A few Swift tests intentionally skip on CI because they require local account state, a real ledger, or an explicit benchmarking/live-validation opt-in. A successful hosted CI run does not certify those environment-dependent checks. Do not inject live credentials into CI just to remove a skip; use local opt-in instructions in the corresponding test when authorized.
