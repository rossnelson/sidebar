# Sidebar

An Arc-style frame and sidebar for Google Chrome on macOS.

Sidebar is a small menu-bar app. It draws a colored frame around your Chrome
window and puts a sidebar on the left with:

- your open tabs
- your Chrome bookmarks (synced and local)
- a grid of favorites for each Chrome profile ("space")
- a ⌘T palette that searches tabs, bookmarks and history, or opens a URL or a web search
- back, forward and reload buttons, and an address pill that opens the palette

The frame color comes from the theme color of the Chrome profile that owns the
window, so each profile gets its own look. Chrome itself is not changed: Sidebar
moves and resizes Chrome's window to make room, and reads Chrome's profile files
to show bookmarks, history and theme.

## Requirements

- A Mac with Apple silicon (the build script builds for `arm64`)
- macOS 14 or later
- Google Chrome
- Swift 6.2 or later. The Xcode Command Line Tools are enough; you do not need Xcode.

To install the Command Line Tools:

```sh
xcode-select --install
swift --version   # must show 6.2 or later
```

## Setup

### 1. Get the code

```sh
git clone https://github.com/rossnelson/sidebar.git
cd sidebar
```

### 2. (Recommended) Create a local signing certificate

macOS ties the Accessibility permission to the app's code signature. With an
ad-hoc signature, the signature changes on every build, and macOS asks for the
permission again after each rebuild. A self-signed certificate keeps the
permission across rebuilds. You only do this once.

```sh
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Sidebar Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Sidebar Local Signing" -out id.p12 -passout pass:sidebar
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P sidebar -T /usr/bin/codesign
rm key.pem cert.pem id.p12 cert.cnf
```

Keychain Access shows the certificate as "not trusted". That is expected and
does not matter for local signing.

Skip this step if you only want to try the app once. The build script falls
back to an ad-hoc signature.

### 3. Build

```sh
Scripts/bundle.sh
```

This builds `build/Sidebar.app`. The script signs the app with, in order:

1. the identity in `SIDEBAR_SIGN_IDENTITY`, if you set it
2. the "Sidebar Local Signing" certificate from step 2
3. an ad-hoc signature

Optional: copy the app to Applications.

```sh
cp -R build/Sidebar.app /Applications/
```

### 4. Run and grant permissions

```sh
open build/Sidebar.app      # or /Applications/Sidebar.app
```

Sidebar has no Dock icon. Look for its icon in the menu bar.

On first launch, macOS asks for two permissions:

| Permission | Where | Why |
| --- | --- | --- |
| **Accessibility** | System Settings → Privacy & Security → Accessibility | Follow, move and resize Chrome's window |
| **Automation → Google Chrome** | A prompt the first time Sidebar talks to Chrome | Read, switch, open and close tabs |

After you turn on Accessibility, quit Sidebar from its menu-bar icon and open it again.

### 5. (Optional) Open at login

Add Sidebar in System Settings → General → Login Items → **+**.

## Shortcuts

These shortcuts work only while Chrome is the front app, so other apps keep their own.

| Shortcut | Action |
| --- | --- |
| ⌘T | Open the palette: search tabs, bookmarks and history, or type a URL or search |
| ⇧⌘C | Copy the current tab's URL. You can change this shortcut in Settings. |
| ⌃⌘S | Collapse or expand the sidebar. When collapsed, move the pointer to the left edge to peek. |

In the palette, Chrome's own ⌘ shortcuts still work. The palette closes and
sends the key to Chrome.

## Settings

Open the menu-bar icon → **Settings…**. To change a shortcut, click its field
and press the new keys. A shortcut must include ⌘, ⌃ or ⌥. Press Esc to cancel.

## Favorites

Each Chrome profile has its own favorites grid, with up to 12 favorites. Add a
favorite from a tab's context menu. Click a favorite to switch to its open tab,
or to open it when no tab matches.

Sidebar saves favorites in
`~/Library/Application Support/Sidebar/favorites-<profile folder>.json`.

## Development

```sh
Scripts/test.sh     # unit tests
Scripts/bundle.sh   # release build into build/Sidebar.app
```

`Scripts/test.sh` passes the Swift Testing framework path that SwiftPM does not
find when only the Command Line Tools are installed.

To rebuild and restart:

```sh
pkill -f 'Sidebar.app/Contents/MacOS/Sidebar'; Scripts/bundle.sh && open build/Sidebar.app
```

Code layout:

- `Sources/SidebarCore`: parsing and rules with no UI (bookmarks, history,
  profiles, themes, palette search, window layout, shortcuts). The tests cover this target.
- `Sources/Sidebar`: the AppKit and SwiftUI app (frame, sidebar, palette,
  Chrome window tracking, hotkeys, settings).

## Troubleshooting

**The sidebar does not appear.** Make sure Accessibility is on for Sidebar,
then quit and open Sidebar again. Sidebar attaches only to a normal Chrome
window on the current screen and Space. It does not attach to full-screen windows.

**macOS asks for Accessibility after every rebuild.** The app has an ad-hoc
signature. Create the certificate in step 2 and build again.

**Tabs do not show.** Allow Sidebar to control Chrome in System Settings →
Privacy & Security → Automation.

**Reset the permissions** and get the prompts again:

```sh
tccutil reset Accessibility com.ross.sidebar
tccutil reset AppleEvents com.ross.sidebar
```

## Uninstall

```sh
pkill -f 'Sidebar.app/Contents/MacOS/Sidebar'
rm -rf /Applications/Sidebar.app ~/Library/Application\ Support/Sidebar
defaults delete com.ross.sidebar
security delete-certificate -c "Sidebar Local Signing"   # if you created it
```
