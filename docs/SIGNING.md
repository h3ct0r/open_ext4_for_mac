# Signing

An FSKit module needs the restricted entitlement
`com.apple.developer.fskit.fsmodule`. macOS only honours it when it is
authorised by a provisioning profile issued from a **paid** Apple Developer
Program account ($99/yr). There is no way around this: an ad-hoc or
self-signed build will compile and pass `codesign --verify`, but `fskitd` will
refuse to load it, and the extension will not appear in System Settings.

This is the same path Apple's own modules and the other third-party FSKit
drivers take — the shipping ExtendFS extension, for example, is signed
`Developer ID Application` with exactly these two entitlements.

## One-time setup

1. **Certificate.** In Xcode or at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates),
   create a **Developer ID Application** certificate and install it in your
   login keychain. Confirm it is there:

   ```bash
   security find-identity -v -p codesigning
   ```

2. **App IDs.** Register two identifiers under
   *Certificates, Identifiers & Profiles → Identifiers*:

   | Identifier | For |
   |---|---|
   | `dev.h3ct0r.ext4mac` | container app |
   | `dev.h3ct0r.ext4mac.Ext4FS` | the FSKit extension |

   On the extension's App ID, enable the **FSKit File System Module**
   capability.

3. **Provisioning profile.** Create a **Developer ID** profile for
   `dev.h3ct0r.ext4mac.Ext4FS`, download it, and save it as:

   ```
   Extension/Ext4FS.provisionprofile
   ```

   That path is in `.gitignore` — never commit it. `scripts/sign.sh` copies it
   to `Contents/embedded.provisionprofile` inside the `.appex`, which is what
   authorises the entitlement at load time.

## Building a signed bundle

```bash
make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

Then install and enable it:

```bash
make install
```

Enable the extension in **System Settings → General → Login Items &
Extensions → File System Extensions**. Verify macOS sees it:

```bash
pluginkit -m -p com.apple.fskit.fsmodule
```

## Troubleshooting: `errSecInternalComponent`

```
Warning: unable to build chain to self-signed root for signer "Developer ID Application: ..."
<target>: errSecInternalComponent
```

The warning is usually a red herring. Check whether the chain is genuinely
broken before chasing it:

```bash
security find-identity -v -p codesigning          # is the identity there?
security find-certificate -a -c "Developer ID Certification Authority" -Z | grep SHA-256
security find-certificate -c "Developer ID Application: YOUR NAME" -p > /tmp/leaf.pem
security verify-cert -c /tmp/leaf.pem -p codeSign  # "verification successful"?
```

Note the `-a` on the second command. Without it, `find-certificate` returns only
the **first** match, and since the G1 and G2 intermediates share a common name,
it is easy to conclude the G2 intermediate is missing when it is present.

### First check: are the Apple certs in the *System* keychain?

`codesign` builds its chain from `/Library/Keychains/System.keychain`. Having
the intermediates only in your login keychain is not enough, and produces
exactly this error even though `security verify-cert` succeeds and every
certificate is individually present.

```bash
security find-certificate -a -c "Developer ID Certification Authority" \
        /Library/Keychains/System.keychain | grep -c labl
security find-certificate -a -c "Apple Root CA" \
        /Library/Keychains/System.keychain | grep -c labl
```

If either prints `0`, install them (needs admin rights):

```bash
cd ~/Downloads
curl -sLO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
curl -sLO https://www.apple.com/appleca/AppleIncRootCertificate.cer
sudo security import DeveloperIDG2CA.cer      -k /Library/Keychains/System.keychain
sudo security import AppleIncRootCertificate.cer -k /Library/Keychains/System.keychain
```

Note there are **two** Developer ID intermediates sharing a common name: the
original and G2. Check which one signed your certificate before assuming you
have the right one:

```bash
security find-certificate -c "Developer ID Application: YOUR NAME" -p \
  | openssl x509 -noout -issuer          # look for OU=G2
```

### Other causes

If the System keychain already has them, the next suspect is the **login
keychain**, not the certificate:

- duplicate private-key entries — one certificate showing up as several
  identities in `security find-identity -v`
- unrelated PKI with long chains (national eID / tax certificates and their
  root stores) that Security has to walk

Either can make chain construction fail inside `codesign` while every
individual piece checks out. The reliable fix is to sign from a keychain that
contains only the signing identity:

```bash
# Export the identity first: Keychain Access -> right-click the Developer ID
# certificate -> Export -> .p12 (set a password).

security create-keychain -p KEYCHAIN_PW signing.keychain
security set-keychain-settings -lut 21600 signing.keychain
security unlock-keychain -p KEYCHAIN_PW signing.keychain
security import DeveloperID.p12 -k signing.keychain -P P12_PW \
        -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k KEYCHAIN_PW signing.keychain
security list-keychains -d user -s login.keychain-db signing.keychain
```

Then build with it:

```bash
make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
          SIGN_KEYCHAIN=signing.keychain
```

`scripts/diagnose_signing.sh` runs the whole check and tells you plainly whether
a usable signature was produced.

### What this is *not*

**System Integrity Protection.** SIP has no bearing on `codesign` reading a
keychain identity, and disabling it does not help. Leave it enabled.

## Distribution

For others to install without their own developer account, the build must be
**notarised** and stapled:

```bash
xcrun notarytool submit Ext4Mac.dmg --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple Ext4Mac.dmg
```

Note that the Mac App Store is not an option for this project: it vendors
lwext4, so the combined work is GPL, and the App Store terms are incompatible
with the GPL.

## Can a free Apple account be used?

**No.** Verified against Apple's
[supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
table, which lists **FSKit Module** as available to *Apple Developer Program*
and *Developer ID* — and **not** to the free *Apple Developer* tier:

| Capability | ADP (paid) | Developer ID | Apple Developer (free) |
|---|---|---|---|
| App Sandbox | yes | yes | yes |
| Hardened runtime | yes | yes | yes |
| **FSKit Module** | **yes** | **yes** | **no** |
| System Extension | yes | yes | no |

A free Personal Team provisioning profile therefore cannot carry the
entitlement, and signing fails with *"Provisioning profile doesn't include the
FSKit Module entitlement."*

There is no developer-mode escape hatch: neither `fskitd(8)` nor
`fskit_agent(8)` documents one, and `fskitd` performs a hard entitlement check
on the mounting client.

It is technically possible to disable SIP and then AMFI
(`amfi_get_out_of_my_way=0x1`) so the kernel stops validating entitlements at
all. That is not recommended — it is unverified for FSKit, it is a significant
security downgrade, it requires Reduced Security on Apple Silicon, and it still
produces nothing distributable.

## Building without a certificate

Everything except loading the extension works with no Apple account at all:

```bash
make test    # 41 assertions against real ext2/3/4 images
```

The ext4 core is deliberately decoupled from FSKit and driven through
callbacks, so `ext4dump` exercises the real filesystem code over a plain file.

This is a deliberate constraint of the project, not an accident: **contributors
cannot sign either**, so a project whose test suite required a paid Apple
account would receive no outside contributions.

What actually needs a certificate is narrow:

| Work | Certificate required |
|---|---|
| Read core (complete) | no |
| Write path — journalling, allocation, create/delete/rename | no |
| Crash-consistency and differential-vs-Linux suites | no |
| Mounting a real disk in Finder | **yes** |
| Notarised DMG for other people | **yes** |

The write path is developed against disk images with `e2fsck` as the oracle,
which is how it should be built regardless — journal replay is not something to
debug against a disk holding real data.
