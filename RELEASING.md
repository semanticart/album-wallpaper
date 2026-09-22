# Cutting a release

Releases are published by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)). Push a
version tag and the workflow builds the release `.app`, signs it with the
Developer ID certificate, stamps the tag into the bundle version, packages it
into a DMG with `make dist`, notarizes and staples it with `make notarize`,
writes the Sparkle appcast with `make appcast`, and attaches all of it to a
GitHub Release with auto-generated notes. Installed copies then update
themselves from that release through Sparkle:

```sh
make release VERSION=0.1.0
```

That stamps the version into `Resources/Info.plist`, commits it, tags
`v0.1.0`, and pushes — so the tag and bundle version can't drift apart. (The
equivalent by hand is: edit the plist, commit, `git tag vX.Y.Z`,
`git push origin main vX.Y.Z`.) You can also trigger the workflow manually
from the **Actions** tab, passing the tag to cut.

## One-time setup: repository secrets

This repo needs the same six secrets as
[keymonster](https://github.com/semanticart/keymonster)'s release workflow,
since both apps release under the same Apple Developer account and Developer
ID certificate. Set them on **this** repo yourself — they're sensitive, so
run these commands locally rather than pasting values into chat:

```sh
gh secret set KEYCHAIN_PASSWORD --repo semanticart/album-wallpaper --body "$(openssl rand -base64 32)"
gh secret set APPLE_ID --repo semanticart/album-wallpaper
gh secret set APPLE_TEAM_ID --repo semanticart/album-wallpaper
gh secret set APP_SPECIFIC_PASSWORD --repo semanticart/album-wallpaper
```

(`gh secret set NAME --repo ...` with no `--body` prompts for the value, or
reads it from stdin — use whatever you used for keymonster's `APPLE_ID`,
`APPLE_TEAM_ID`, and `APP_SPECIFIC_PASSWORD`.)

For the certificate, export the same "Developer ID Application: Jeffrey Chupp"
identity already in your login keychain (Keychain Access → find the cert →
right-click → Export, or via `security export`), then:

```sh
gh secret set P12_PASSWORD --repo semanticart/album-wallpaper   # the export password you chose
base64 -i DeveloperIDApplication.p12 | gh secret set BUILD_CERTIFICATE_BASE64 --repo semanticart/album-wallpaper
rm DeveloperIDApplication.p12
```

## Sparkle signing key

Sparkle only installs an update whose appcast entry is signed by the private
EdDSA key matching `SUPublicEDKey` in `Resources/Info.plist`. This app
**reuses keymonster's key** rather than generating a new one — Sparkle's own
`generate_keys --help` recommends one signing key per developer, not per app
("You only need one signing key, no matter how many apps you embed Sparkle
in"). The key already lives in your login keychain (Sparkle's `generate_keys`
put it there when you set up keymonster), so set the same secret value here:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY --repo semanticart/album-wallpaper < sparkle-private-key
rm sparkle-private-key
```

(The `generate_keys` binary appears under `.build/artifacts/sparkle/` after
the first `swift build` in this repo, same as keymonster.)

Keep a copy of the exported key somewhere safe: if it's lost, a new one can be
generated, but every installed copy of both apps still trusts the old public
key and would have to be updated by hand once.

To write the appcast locally (after `make dist`), which reads the key from
the keychain:

```sh
make appcast
```

## Notarizing locally

To notarize locally instead of via CI, store an app-specific password once
with:

```sh
xcrun notarytool store-credentials album-wallpaper-notary \
  --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
```

then run `make dist && make notarize`.
