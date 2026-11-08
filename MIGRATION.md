# Upgrading from Shade 1.0 to 1.1

## What you need to do

Nothing on the phone. Install the new `.ipa` over the old app the same way you installed it the first time (AltStore, SideStore, Sideloadly or Xcode). On first launch, Shade migrates your data automatically.

Keep the same bundle identifier when you reinstall. Sideloading tools do this by default, and it's what keeps your data. Installing under a *different* bundle ID creates a separate, empty app.

## What migrates automatically

| Data | 1.0 location | 1.1 location | What happens |
| --- | --- | --- | --- |
| Saved recipes | `Documents/Recipes/*.shade` | same | Nothing to do: the file format (`shade.recipe/1`) is unchanged, and 1.0 can still read files written by 1.1. |
| Recipes dropped into the Documents root (via Finder or Files) | read in place from `Documents/*.shade`, `*.json` | moved into `Documents/Recipes` | Moved on launch. The original is deleted only after the copy is safely written. JSON files that aren't recipes are left alone. Broken `.shade` files stay where they are and are listed in the Library. |
| Recipe files that share an id (copied files) | ids reshuffled in memory on every launch | each file gets its own id, written back once | Stable from then on. |
| The look on screen, including unsaved edits | UserDefaults key `currentRecipe` | `Application Support/Shade/state.json` | Converted on first launch, then the old key is removed. If the old data can't be read, it's kept under `currentRecipe.unreadable` rather than deleted. If writing the new file fails, the old key is kept and the migration retries next launch. |
| Claude API key | Keychain, service `com.shadeapp.shade`, account `claude-api-key` | same item | Nothing to do. |
| Model and effort settings | UserDefaults `claudeModel`, `claudeEffort` | same keys | Unknown values fall back to the defaults (Opus 5.5, high). |

## Behaviour changes to know about

- **New limits on imported recipes:** at most 16 passes, 32 parameters per pass, 20,000 characters of code per pass, and 1 MB per file or paste. None of the presets come close. A file over a limit is rejected with a message saying which limit, rather than being half-loaded.
- **Format check:** files claiming a newer format (for example `shade.recipe/2`) are rejected instead of being misread.
- **Saving:** **Save** now overwrites the library recipe you're editing. Edited presets are saved as a new "(edited)" copy. **Revert** discards unsaved edits. A dot after the look's name means it has unsaved changes.
- **GPU safety:** if a custom shader pass crashes the GPU, Shade turns custom passes off in that look and tells you, instead of showing a frozen or black screen.
- **Recording:** recordings stop automatically at 10 minutes, and won't start with less than about 300 MB free.

## For developers

- The Xcode project is still generated: `xcodegen generate`. It now depends on the local package `Packages/ShadeCore`, which XcodeGen wires up automatically.
- Run the core tests with `swift test --package-path Packages/ShadeCore`. They run on Linux too.
- `Tools/ShaderCheck` moved into the package as the `shadercheck` executable. `scripts/check-shaders.sh` calls it.
- Logs use the subsystem `com.shadeapp.shade`, with categories `storage`, `claude`, `generation`, `shaders`, `render`, `camera`, `capture` and `migration`.
