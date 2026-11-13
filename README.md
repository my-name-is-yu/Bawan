# Bawan

Bawan is a resident English ↔ Japanese translation app for Apple Silicon Macs running macOS 14 or later.

Select text in any app and press `⌘C` twice within 400 ms to display the source text and translation near your cursor. You can also press `⌥T` twice—or choose **Open Translator** from the menu bar—to open the window for manual input. Both global shortcuts can be enabled, disabled, and customized individually in **Settings…**.

Bawan stays resident in the Dock and `⌘Tab` switcher after you close the translation panel. The panel comes to the front when invoked and behaves like a standard window afterward, moving behind other apps when unfocused.

## Features & Design

- **Native single-process architecture:** Built with AppKit, Objective-C++, and C++17, statically linking `llama.cpp` for local Metal inference. No Electron, Rust, Python, or external inference server is used.
- **Offline translation:** Works completely offline once the model is downloaded.
- **Side-by-side UI:** Displays source and translated text side by side, follows macOS Light/Dark appearance, and supports macOS **Reduce Motion** and **Increase Contrast** accessibility settings.
- **Streaming & controls:** Streams translation output incrementally without losing your scroll position when reading earlier text, and includes a swap (`⇄`) button to reverse translation direction.
- **Privacy & memory efficiency:** Writes no translation history files or logs. The model loads lazily on first use and unloads automatically after 60 seconds of inactivity.

## Building & Installing

### Prerequisites

- Apple Silicon Mac (macOS 14+)
- Apple Command Line Tools and CMake

### Build from Source

```sh
xcode-select --install
cmake --version
./scripts/build.sh
open build/Bawan.app
```

The first build downloads `llama.cpp` (`b12307`) and verifies its SHA256 checksum. All downloads, intermediate files, and the built app stay inside `build/`. Subsequent runs perform incremental builds. End users do not need CMake or developer tools to run the built app.

### Install to Applications

For regular use, quit the app, copy it to `/Applications`, and launch it from there before granting macOS permissions or enabling Launch at Login:

```sh
ditto build/Bawan.app /Applications/Bawan.app
open /Applications/Bawan.app
```

Builds use ad-hoc signing by default. To sign with your own identity:

```sh
./scripts/build.sh -DBAWAN_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)"
```

To clean build artifacts, quit Bawan and delete `build/`. The downloaded model in Application Support and your macOS permissions are stored separately.

## Setup & Usage

1. **Model download:** On first launch, Bawan downloads the official PLaMo model (~573 MB) and verifies its file size and SHA256 checksum. Progress appears in the window and menu bar. If setup fails, choose **Retry Model Setup** from the menu.
2. **Permissions:** Open **Settings…** from the menu bar (or the gear icon) and grant the permissions shown for your shortcuts:
   - **Input Monitoring** is required for the default `⌘C` ×2 selection translation.
   - **Accessibility** is required for opening the translator (`⌥T` ×2) or using a custom shortcut for selection translation.
   - Manual translation via **Open Translator** works without either permission.
3. **Translate selected text:** Highlight text in another app and press `⌘C` twice (releasing `⌘` between presses also works).
4. **Translate manually:** Press `⌥T` twice or select **Open Translator**. Invoking the shortcut while the window is already open preserves its position, text, and translation state while focusing the source field.

### In-Window Shortcuts

| Action | Shortcut |
| --- | --- |
| Translate / Cancel active translation | `⌘Return` |
| Copy translation | `⌘⇧C` |
| Swap source and translation | `⇄` button |
| Close translator | `Esc` / `⌘W` |

In Settings, `Esc` cancels shortcut recording first; otherwise it returns to the translator with text, scroll position, and editing history preserved. `⌘W` closes the shared window when shortcut recording is inactive.

### Customizing Shortcuts

| Action | Default | Permission Required |
| --- | --- | --- |
| Translate selected text | `⌘C` (2 presses) | Input Monitoring |
| Open translator | `⌥T` (2 presses) | Accessibility |

In **Settings…**, click **Shortcut (click)** to record a new key combination and choose **1** or **2** presses:

- Shortcuts must combine at least one modifier (`⌘`, `⌥`, or `⌃`) with a regular key.
- Reserved app shortcuts (`⌘Return`, `⌘⇧C`, `⌘Q`, `⌘,`) and combinations already used by the other active action cannot be assigned.
- Double-press shortcuts require both presses within 400 ms, releasing the key between presses without holding it down, pressing other keys, or switching apps.
- Unlike the default `⌘C` ×2 (which preserves normal copy behavior), custom shortcuts are intercepted from the first press and are not forwarded to the active app even if a double-press is not completed.
- Custom shortcuts for selection translation trigger a copy in the active app after key release and require Accessibility permission.

### Translation Behavior

- **Auto-direction:** Text containing kana or kanji translates Japanese → English; all other text translates English → Japanese. Clicking `⇄` flips the previous direction rather than re-detecting from the translated text.
- **Limits:** Designed for a few sentences up to a few paragraphs (4,096-token input limit including prompt overhead; 4,096-token output limit, using Q4_K_M weights and F16 KV cache). Oversized input is rejected with a message; output that reaches the generation limit is marked incomplete.
- **Clipboard safety:** If copying selected text fails (e.g., copy-protected views, image-only selections, or Secure Keyboard Entry), Bawan will not translate stale clipboard contents. Use manual input in these cases or if clipboard access is denied.

### Model Location

```text
~/Library/Application Support/local.bawan.Bawan/plamo-3-translate-0.8b-Q4_K_M.gguf
```

Bawan uses its own bundle ID and storage directory and does not migrate models or settings from other apps.

## Testing & Verification

Tests, smoke checks, and profiling tools are excluded from standard release builds. To build and run them locally on Apple Silicon:

```sh
./scripts/build.sh -DBAWAN_BUILD_TESTS=ON -DBAWAN_BUILD_SMOKE=ON
cmake --build build --target short_input_tests shortcut_tests shortcut_preferences_tests panel_smoke settings_smoke mascot_smoke app_delegate_smoke engine_lifecycle engine_event_mailbox_tests engine_smoke engine_profile --parallel 3
ctest --test-dir build --output-on-failure
./build/engine_smoke "$HOME/Library/Application Support/local.bawan.Bawan/plamo-3-translate-0.8b-Q4_K_M.gguf"
```

You can also run single-string inference or resource profiling against a local GGUF model:

```sh
./build/engine_smoke /path/to/model.gguf 'The meeting has been moved to next Monday.'
./build/engine_profile /path/to/model.gguf
```

On Linux, you can build and test the CPU inference engine without the macOS app target:

```sh
cmake -S . -B build -DBAWAN_BUILD_APP=OFF -DBAWAN_BUILD_TESTS=ON -DBAWAN_BUILD_SMOKE=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
./build/engine_smoke /path/to/model.gguf
```

GitHub Actions CI is not used; run builds, signature checks, and real-model tests locally. Live shortcut permissions and key interception checks, full-window UI acceptance, and whole-app resource measurements remain unrecorded. See the [UI QA record](design-qa.md) for evidence and outstanding checks. Engine profiling excludes AppKit and does not establish whole-app memory use or Metal performance from Linux RSS.

## Model & Licenses

Built with PLaMo. Bawan uses the official [PLaMo 3 Translate 0.8B GGUF Q4_K_M](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF) model unmodified under the **PLaMo Community License** (intended for personal use; check the official model card for other usage terms).

Inference is powered by [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/b12307) under the **MIT License**. License notices are bundled in the app's `Resources` directory.
