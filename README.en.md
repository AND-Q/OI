<div align="center">

<img src="assets/AppIcon.svg" width="128" alt="OI icon">

# OI

**A native macOS menu bar launcher**

Press `⌥Space` for a Spotlight-style panel: launch apps, find files, calculate, open URLs, and ask AI;<br>
force click, press `⌥D`, or select an area of the screen in any app to translate in place.

[![Latest release](https://img.shields.io/github/v/release/AND-Q/OI?label=release)](https://github.com/AND-Q/OI/releases/latest)
![macOS 27.0+](https://img.shields.io/badge/macOS-27.0%2B-000000?logo=apple)

English · [中文](README.md)

[Download](https://github.com/AND-Q/OI/releases/latest) · [User Guide (Chinese)](docs/OI%20使用指南.md) · [Feature List (Chinese)](docs/OI%20功能清单.md)

</div>

## Features

### Launcher

- **App search**: matches English and Chinese names, full pinyin (`weixin`), initials (`wx`, `vsc`), bundle IDs, and fuzzy subsequences; results are ranked by match tier first, then by how often you use them. The index lives in memory and never goes online.
- **File search**: searches files and folders in your home folder through the system Spotlight index, listed after apps; type a path starting with `/` or `~` to open it directly, including hidden files and `~/Library`.
- **Quick queries**: type an expression for an instant result (`2^10`, `(8-5)/3`) or `ip` for your local network address; press Enter to copy.
- **URLs and web search**: type `github.com` or `localhost:3000` and press Enter to open it; `⌘Enter` searches the current input with Bing, Google, Baidu, or DuckDuckGo.
- **Result actions**: `⌘F` shows in Finder, `⌘Y` previews with Quick Look, and `⌘K` opens quick actions (Copy Path, Copy Bundle ID, Open in Terminal, Open With).

### AI and translation

- **Quick AI**: press `Tab` in the panel to ask a question, then keep asking follow-ups; reopen within 5 minutes of hiding the panel to pick up the conversation. Works with any OpenAI-compatible API (including local models such as Ollama) and streams Markdown answers.
- **Translator**: force click on the trackpad to translate the word under the pointer, or press `⌥D` to translate the selected text (the clipboard when nothing is selected). The translation streams into a bubble next to the original; bubbles can be dragged and pinned, and the original can be read aloud offline with the system voice.
- **Screenshot translation**: for text you can't select, such as images or video subtitles, press `⌥S` and select an area of the screen. The text is recognized on your Mac, then translated.

### More

- English and Simplified Chinese interface: follows the system language, or pick one in Settings → General → Language.
- Launch at login; the launcher, translate, and screenshot translate shortcuts can all be changed.
- Quick AI and the translator can use different APIs and models; API keys are stored in the keychain.
- **Check for Updates…** in the menu bar looks for a new version on GitHub and shows the release notes.

## Installation

Requires macOS 27.0 or later. Force click translation needs a Force Touch trackpad; without one, use `⌥D`.

1. Download `OI-<version>.dmg` from [Releases](https://github.com/AND-Q/OI/releases/latest), open it, and drag OI to the Applications folder.
2. OI is not notarized by Apple, so macOS says it can't be verified the first time you open it. Click **Done**, then go to **System Settings → Privacy & Security**, click **Open Anyway** near the bottom, and confirm. Or run this in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/OI.app
   ```

3. OI lives in the menu bar (the `⌘` icon) with no Dock icon. Press `⌥Space` to open the launcher, and click the menu bar icon → **Settings…** to change options.

> [!NOTE]
> **Grant permissions again after upgrading**: OI isn't signed with a developer certificate, so macOS treats every new version as a different app. If the translator or screenshot translation stops working after an upgrade, remove the old OI from the **Accessibility** and **Screen & System Audio Recording** lists in **System Settings → Privacy & Security**, then grant access again from **Permissions** in OI's settings.

## Keyboard shortcuts

Global shortcuts (work in any app, can be changed in Settings):

| Keys | Action |
| --- | --- |
| `⌥Space` | Show / hide the launcher |
| `⌥D` | Translate the selected text, or the clipboard when nothing is selected |
| `⌥S` | Select an area of the screen, recognize its text, and translate |
| Force click on the trackpad | Translate the word under the pointer |

In the launcher panel:

| Keys | Action |
| --- | --- |
| `↑` / `↓` | Move the selection |
| `Enter` | Open the app, file, or URL; copy when a query result is selected |
| `⌘Enter` | Search the web for the current input |
| `Tab` | Enter / leave Quick AI |
| `⌘F` | Show in Finder; copy when a query result or URL is selected |
| `⌘Y` | Quick Look preview |
| `⌘K` | Quick actions menu |
| `Esc` | Clear the input first, then close the panel |

In a translation bubble: `Enter` copies the translation and closes, `⌘C` copies, `⌘⇧S` reads the original aloud, `Esc` dismisses, `⌘W` closes.

## Search examples

| Input | Finds | Match |
| --- | --- | --- |
| `weixin` / `xin` | 微信 (WeChat) | Full pinyin, starting from any character |
| `wx` | 微信 (WeChat) | Pinyin initials |
| `vsc` | Visual Studio Code | Initials |
| `code` | Visual Studio Code | Word prefix |
| `com.apple.Saf` | Safari | Bundle ID |
| `visulstdo` | Visual Studio Code | Fuzzy subsequence |

Matches fall into 8 tiers: exact → name prefix → word prefix → bundle name and ID → aliases and initials → full pinyin → substring → fuzzy. Tiers always come first; launch counts and recent use only order results within a tier, so the apps you use most rise to the top.

## Setting up Quick AI and the translator

Enter the API endpoint, model, and API key in **Settings… → Quick AI** and **Settings… → Translator**:

- The endpoint is the address of an OpenAI-compatible service, such as `https://api.openai.com/v1`; for a local Ollama, use `http://localhost:11434/v1` and leave the API key empty.
- Click **Test Connection** to check the endpoint and API key, or **Fetch Models** to pick a model from the service's model list.
- For translation, a fast model without thinking works best, or set the reasoning effort to `low`.

## Permissions and privacy

| Permission | Used for | When it's requested |
| --- | --- | --- |
| Desktop, Documents, and Downloads folders | File search | At first launch; no longer requested once file search is off |
| Accessibility | Reading the selected text and the word under the pointer | When you turn it on in **Settings… → Permissions** |
| Screen Recording | Screenshot translation | The first time you press `⌥S` |
| Notifications | Explaining why an app or file failed to open | The first time one is needed |

- App search, file search, and quick queries run locally. Search terms and opened files are not recorded; only app launch counts and last-used times are kept for ranking, and you can turn that off in Settings.
- Your question or the original text is sent to the API you entered only when you ask Quick AI or translate (a follow-up also sends the earlier questions and answers in the conversation). Screenshots are recognized on your Mac and are never saved or uploaded; only the recognized text is sent.
- If Accessibility can't read the selected text when you press `⌥D` (in Chrome pages or PDFs in Preview, for example), OI presses `⌘C` once to read the selection, then immediately puts back what was on your clipboard. Clipboard managers may still record that copy.
- Beyond that, OI only reads the model list from the API you entered when you click **Fetch Models** or **Test Connection** in Settings (no questions or text are sent), and only contacts GitHub when you choose **Check for Updates…**.

## FAQ

**Nothing happens when I press `⌥Space`?**
Some input methods use `⌥Space` to switch between full-width and half-width characters, and other menu bar tools may use the same shortcut. Turn it off in your input method settings, or pick another shortcut in **Settings… → General** (a red hint appears when a shortcut is taken).

**The system dictionary pops up when I force click?**
In **System Settings → Trackpad → Point & Click**, set **Look up & data detectors** to **Tap with Three Fingers** or turn it off, and keep **Force Click and haptic feedback** on.

**A newly installed app doesn't show up?**
Changes to the Applications folders are picked up the next time you open the panel; open it once and search again.

See the [User Guide FAQ (Chinese)](docs/OI%20使用指南.md#15-常见问题) for more.

## Building from source

Requires Xcode with the macOS 27 SDK. Open `OI.xcodeproj` and run the shared `OI` scheme, or use the command line:

```bash
xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug build
xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug test -destination 'platform=macOS'
```

Debug, Release, and the test target (`OITests`) use complete strict concurrency checking, and Release enables the Hardened Runtime. OI doesn't use the App Sandbox: it needs to scan system apps, register global shortcuts, and read text from other apps through Accessibility, which the sandbox doesn't allow.

Interface text is written in Chinese in the code and translated through `Localizable.xcstrings` (English and Simplified Chinese). When you add or change interface text, add the English translation to the catalog as well.

## Project structure

The project uses a "single app target + explicit layers + composition root" architecture, with dependencies flowing as follows:

```text
App -> Features -> Application -> Domain
App -> Infrastructure -> Application / Domain
App -> UI -> Features / Application / Domain
```

| Folder | Responsibility |
| --- | --- |
| `App/` | Composition root: app lifecycle and coordination; `AppDependencies.live(configuration:)` is the only place that creates concrete dependencies |
| `Domain/` | Business models (apps, files, search results, quick queries, translation languages); Foundation-only and `Sendable` |
| `Application/` | `Ports` protocols for external capabilities, `UseCases` business flows, `Search` app search index and pinyin normalization, `Errors` stable error model |
| `Features/` | Feature state and view models: `Launcher` (search, quick queries, URL detection, `⌘K` menu), `Settings`, `Translator`, plus the shared Markdown and streaming text in `Shared` |
| `Infrastructure/` | System implementations: app scanning and folder watching, Spotlight file search, NSWorkspace opening, Carbon shortcuts, login item, OpenAI-compatible client and keychain, text capture and screen text recognition, notifications, update checks, UserDefaults storage |
| `UI/` | AppKit / SwiftUI bridging: launcher panel, menu bar, settings window, translation bubbles and area selection, icon cache, update alerts |
| `OITests/` | Unit tests |
| `assets/`, `scripts/` | Icon sources, dmg background, and release scripts |
| `docs/` | User guide, feature list, release notes, and to-do list (in Chinese) |

Conventions:

- Features never create concrete infrastructure. Cross-layer side effects are first defined as protocols in `Application/Ports` and then implemented in `Infrastructure`; use cases convert low-level errors into `ApplicationError`, and features map those to interface text.
- UI types such as `NSImage`, `NSPanel`, and `NSStatusItem` appear only in `UI`; Domain doesn't reference AppKit, SwiftUI, or Carbon; Infrastructure doesn't depend on Features or UI.
- Features use explicit state types to avoid contradictory combinations of booleans; new user flows get their own feature instead of adding state to `LauncherViewModel`.
- `@MainActor` covers only the interface and AppKit coordination; slow work such as file scanning runs in the background and supports cancellation.
- Tests replace dependencies with port stubs, in-memory stores, or custom `AppDependencies`, never global singletons.
- No `Manager`, `Service`, or `Repository` types or empty folders without a real responsibility. A local Swift package is extracted only when a module has its own compile boundary, its own owner, or a clear build benefit.

## Releasing

OI is distributed as a dmg through GitHub Releases. It isn't on the App Store and isn't signed with a Developer ID or notarized (the dmg is ad-hoc signed). To release a version:

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, write `docs/releases/v<version>.md`, commit, and run all tests.
2. Install dmgbuild (`pip3 install dmgbuild`) and run `scripts/release.sh` in a clean working tree: it builds the Release version, packages it as `build/release/OI-<version>.dmg` (window layout in `scripts/dmg-settings.py`), and generates release notes with the SHA-256.
3. Run the `gh release create` command printed at the end of the script.

You can also archive in Xcode, export `OI.app` through Distribute App → Custom → Copy App, and package it with `scripts/make-dmg.sh <OI.app> <version> <output dmg>`.

**Check for Updates…** compares the latest release tag with the current version. Tags must look like `v<version>` (such as `v1.1.0`, as in the command the script prints); drafts and pre-releases are ignored.
