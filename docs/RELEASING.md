# Releasing

For the maintainer. A release is a tag, a signed and notarized DMG, and a
GitHub Release whose notes are the changelog section — produced by
`make release` locally and `.github/workflows/release.yml` on push.

## Before the tag

- `CHANGELOG.md` has a `## [x.y.z] - YYYY-MM-DD` section. `make release`
  refuses without one. `make changelog-draft` prints the commits since the
  last tag under Keep-a-Changelog headings to edit from.
- The tree is clean and on `master`; CI is green on the commit you will tag.
- The hostile-fixture and patch counts in the changelog match
  `Tests/fixtures/hostile/MANIFEST` and `patches/lwext4/` (the docs suite
  checks the README's; check the changelog's by eye).
- The soak and, when lwext4's write path changed, the hardware loop have been
  run on this build and recorded in `docs/notebook/soak.md` / `docs/HARDWARE.md`, and `docs/STATUS.md`'s record table updated.

## Cutting it

```bash
make release VERSION=x.y.z
git push --tags
```

`make release` builds, signs, makes the DMG and runs `scripts/check_release.sh`
*before* it commits the version bump and tags, so a broken build never gets a
tag. Pushing the tag starts the workflow, which on a macOS runner:

1. imports the Developer ID identity into a temporary keychain (deleted in an
   `always()` step),
2. writes both provisioning profiles from secrets,
3. builds, signs the extension and the app, checks the signature against the
   profiles, builds the DMG,
4. notarizes with the App Store Connect API key, staples, verifies with
   `spctl`,
5. publishes the DMG as a GitHub Release with the changelog section as notes.

A `workflow_dispatch` with `dry_run` (the default) stops after step 3 — the
way to prove the signing path on a branch without notarizing or publishing.

The log must contain `with the shared keychain group`. If it says `without`,
the app was signed without its entitlement and `Ext4Mac forget`/`list` will
not reach the extension's keys on that build; do not publish it.

## The secrets

Set under Settings → Secrets and variables → Actions. `scripts/ci_release.sh`
validates each and names the one that is wrong.

| secret | what | how |
|---|---|---|
| `DEVELOPER_ID_P12` | the Developer ID Application identity — certificate **and** private key | Keychain Access → **My Certificates** → expand the *Developer ID Application* row so the private key shows under it → right-click the certificate → Export, format **Personal Information Exchange (.p12)**, set a password; `base64 -i cert.p12 \| pbcopy`. A `.cer` is the certificate alone and fails. Keychain Access writes legacy RC2 encryption; that is fine for the pipeline, but to inspect it locally with OpenSSL 3 add `-legacy`: `openssl pkcs12 -legacy -in cert.p12 -noout -info` must list a private key and a certificate. |
| `DEVELOPER_ID_P12_PASSWORD` | that password | as chosen at export |
| `EXT_PROVISIONING_PROFILE` | `Extension/Ext4FS.provisionprofile` | `base64 -i Extension/Ext4FS.provisionprofile \| pbcopy` |
| `APP_PROVISIONING_PROFILE` | `App/Ext4Mac.provisionprofile` | `base64 -i App/Ext4Mac.provisionprofile \| pbcopy` |
| `NOTARY_KEY` | an App Store Connect API key (`.p8`) with the Developer role | App Store Connect → Users and Access → Integrations → App Store Connect API → generate; `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | its Key ID | shown beside the key |
| `NOTARY_ISSUER` | the Issuer ID | shown at the top of that page |

`GITHUB_TOKEN` is the workflow's own. Nothing is written to the runner's login
keychain, and a failed run leaves only its logs.

## Release notes

The changelog section verbatim, then these two paragraphs every time, because
they are the two things a new user most needs to know and a changelog will
not tell them:

> **Eject before unplugging.** FSKit gives this driver no way to flush a
> drive's cache, so the journal's ordering guarantee stops at the drive. See
> the barrier section of docs/ENVELOPE.md for what was measured.
>
> **After installing or upgrading, approve the extension** in System
> Settings → General → Login Items & Extensions → File System Extensions.
> macOS grants this by hand only. See docs/INSTALL.md.

Then the DMG's SHA-256 (`shasum -a 256 Ext4Mac-x.y.z.dmg`), and a "known
limitations" list pulled from ENVELOPE's *Not yet* items.

## If CI is down

The local half of the pipeline exists too:

```bash
make dmg
make notarize NOTARY_PROFILE=ext4mac-notary     # a notarytool keychain profile
make staple
scripts/check_release.sh
```

then attach the DMG to the release by hand. The notary profile is created
once with `xcrun notarytool store-credentials`.

## After publishing

On a clean user account: download the DMG from the Release page, install,
approve, mount a disk, run `Ext4Mac status`. This is the path every user
takes and no suite covers it. If INSTALL.md got a step wrong, fix the doc;
re-cut only if a fix touches the bundle.
