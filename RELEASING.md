# Releasing Ventilador

Ventilador is distributed as a notarized zip on GitHub Releases, installed through a Homebrew tap.
`Ventilador/scripts/release.sh` builds, signs, notarizes and packages a release, and generates the cask.

## Why signing and notarization are required

- The app embeds a **privileged helper** (a launchd daemon registered with `SMAppService`). macOS registers it
  only for a properly signed app, and the helper accepts connections only from the app signed by the same team.
- Gatekeeper rejects downloaded apps that aren't notarized, and Homebrew stopped accepting casks that aren't.

An *Apple Development* certificate is enough to run the app on your own Mac; distribution needs a
**Developer ID Application** certificate from the paid Apple Developer Program.

## One-time setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/).
2. Create a **Developer ID Application** certificate (Xcode > Settings > Accounts > Manage Certificates), and
   note your Team ID.
3. Store notarization credentials in the keychain (needs an app-specific password from appleid.apple.com):
   ```bash
   xcrun notarytool store-credentials ventilador-notary --apple-id <you@example.com> --team-id <TEAMID>
   ```
4. Create the tap repository, named exactly `homebrew-tap`:
   ```bash
   gh repo create <user>/homebrew-tap --public --description "Homebrew tap"
   ```

## Cutting a release

```bash
cd Ventilador
scripts/check-coverage.sh                       # tests + 100% coverage, on real Apple Silicon hardware
DEVELOPMENT_TEAM=<TEAMID> scripts/release.sh 0.1.0
```

The script:

1. builds Release with the Developer ID identity, hardened runtime and a secure timestamp;
2. checks that the app and the helper carry the same team and hardened runtime, and that the version landed in
   `Info.plist`;
3. zips the app, submits it to Apple's notary service, staples the ticket, checks it with `spctl`, and zips again;
4. writes `dist/Ventilador-<version>.zip` and `dist/ventilador.rb` (the cask, with the version and SHA-256 filled in).

Then publish:

```bash
gh release create v0.1.0 dist/Ventilador-0.1.0.zip --title "Ventilador 0.1.0" --notes "..."
cp dist/ventilador.rb <path-to>/homebrew-tap/Casks/ventilador.rb
# commit and push the tap
```

Users install with:

```bash
brew install --cask <user>/tap/ventilador
```

After installing, they click **Enable Fan Control** in the popover and approve Ventilador in
*System Settings > General > Login Items & Extensions*.

## Releasing from Xcode (no `notarytool` profile needed)

Xcode notarizes with the Apple ID you are signed in with, so this route skips the app-specific password.

1. Bump `MARKETING_VERSION` in `Ventilador/project.yml`, run `xcodegen generate`, and archive: Product > Archive.
2. In the Organizer choose **Distribute App > Direct Distribution** (Developer ID). Do **not** choose *App Store
   Connect*: Ventilador cannot be sandboxed (the sandbox blocks `AppleSMC` and root helpers), so the Mac App Store
   is not an option.
3. When the Organizer shows the build as ready, **Export** the notarized app.
4. Package it. This checks the signatures and the stapled ticket, zips the app and writes the cask:
   ```bash
   cd Ventilador
   DEVELOPMENT_TEAM=<TEAMID> scripts/release.sh --package-only /path/to/exported/Ventilador.app
   ```
5. Publish as described above (`gh release create`, then copy `dist/ventilador.rb` into the tap).

If signing fails with `The timestamp service is not available`, something on your machine is blocking plain HTTP
(port 80) for `codesign`, which fetches Apple's secure timestamp over HTTP. A network content filter such as Cisco
Secure Client can do this. Sign and notarize from another machine, or from CI.

## Dry run without the paid account

```bash
DEVELOPMENT_TEAM=<TEAMID> SIGN_IDENTITY="Apple Development" scripts/release.sh 0.1.0 --skip-notarize
```

Builds, verifies and packages with your development identity and generates the cask. The zip is **not**
distributable (Gatekeeper rejects it), but it exercises every other step.

## Notes

- **Version**: `release.sh` sets `MARKETING_VERSION` from its argument. Tag as `v<version>`; the cask URL depends on it.
- **CI**: GitHub-hosted macOS runners are virtual machines without AppleSMC, so the hardware-reading tests
  can't run there and the coverage gate would fail. Run the gate locally (or on a self-hosted Apple Silicon
  runner) before every release.
- **Homebrew's official cask repository** (`homebrew/cask`) also expects a notable, established project; a personal
  tap has no such requirement.
- **Uninstall**: the cask stops the helper (`launchctl`) before removing the app; stopping the helper returns
  manually controlled fans to automatic. The exact behavior of `uninstall launchctl:` for an `SMAppService`
  daemon hasn't been verified on a real install yet; check `brew uninstall --cask` once the first release exists.
