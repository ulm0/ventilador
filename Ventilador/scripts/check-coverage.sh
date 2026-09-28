#!/bin/bash
# Runs both test suites and fails unless every file under Sources/ that is compiled into the app
# target has 100% line coverage. Must run on real Apple Silicon hardware (AppleSMC read-only tests).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/coverage"
RESULT="$OUT/TestResults.xcresult"
rm -rf "$RESULT"
mkdir -p "$OUT"

xcodegen generate --quiet
xcodebuild test \
  -project Ventilador.xcodeproj \
  -scheme Ventilador \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  -enableCodeCoverage YES \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$RESULT" \
  | grep -E "^\*\* TEST|: error: |^Failing tests:" || true

if ! xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null | grep -q '"result":"Passed"'; then
  echo "coverage gate: test run did not pass" >&2
  exit 1
fi

xcrun xccov view --report --json "$RESULT" > "$OUT/coverage.json"

xcrun swift - "$OUT/coverage.json" <<'SWIFT'
import Foundation

struct Report: Decodable {
    struct Target: Decodable { let name: String; let files: [File] }
    struct File: Decodable { let path: String; let coveredLines: Int; let executableLines: Int }
    let targets: [Target]
}

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let report = try JSONDecoder().decode(Report.self, from: data)
guard let app = report.targets.first(where: { $0.name == "Ventilador.app" }) else {
    print("coverage gate: Ventilador.app missing from coverage report"); exit(1)
}
// The single exemption: calls that hand control to macOS (register a root daemon, open System
// Settings, quit the host). See the header of that file. Nothing else may be exempted.
let exempt = ["/Sources/App/SystemActions.swift"]
let files = app.files.filter { file in file.path.contains("/Sources/") && !exempt.contains { file.path.hasSuffix($0) } }
let short = files.filter { $0.coveredLines < $0.executableLines }
let covered = files.reduce(0) { $0 + $1.coveredLines }, total = files.reduce(0) { $0 + $1.executableLines }
print("coverage gate: \(covered)/\(total) lines in \(files.count) files")
for file in short.sorted(by: { $0.path < $1.path }) {
    print("  \(file.path.components(separatedBy: "/Sources/").last!): \(file.coveredLines)/\(file.executableLines)")
}
exit(short.isEmpty && !files.isEmpty ? 0 : 1)
SWIFT
