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

## Building without a certificate

Everything except loading the extension works with no Apple account at all:

```bash
make test    # 41 assertions against real ext2/3/4 images
```

The ext4 core is deliberately decoupled from FSKit and driven through
callbacks, so `ext4dump` exercises the real filesystem code over a plain file.
Contributors can develop and test the entire core without paying Apple
anything — only the final mount-on-a-real-Mac step needs a certificate.
