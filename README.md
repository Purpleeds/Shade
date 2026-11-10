# Shade

Real-time shaders for real life. Shade is an iPhone camera app that runs a stack of GPU shader passes over the live camera, so you see the world as a comic book, an oil painting, a thermal camera, or any style you show it.

You can make new looks three ways:

| Method | What happens | Needs |
| --- | --- | --- |
| **Claude (in app)** | Pick an image or video. Claude studies the style and writes a shader recipe, including custom Metal code. The app compiles it on your GPU, and if anything fails to compile it sends the errors back to Claude to fix (up to 2 rounds). | A Claude API key |
| **On-device** | Measures a reference image's palette, contrast, saturation, grain and vignette, then builds a look from the built-in effects. Instant and offline. | Nothing |
| **Claude chat** | Tap **Copy prompt**, paste it into [claude.ai](https://claude.ai) with your image or video, copy Claude's reply, then tap **Paste Claude's reply**. The same prompt is in [`PROMPT.md`](PROMPT.md). | A Claude account (free works) |

There are 30 ready-made looks in five groups: **Nostalgic** (Super 8, Camcorder '98, Faded Memory, Instant Summer, Silent Reel, Lomo, Film Noir), **Dreamy** (Golden Hour, Dreamscape, Cotton Candy, Ethereal Trails, Moonlight, Prism Dream, Daydream, Miniature World and more), **Retro Tech**, **Artistic** and **Fun**.

Customising a look:

- **Intensity:** the slider above the presets fades the whole look in or out.
- **Compare:** press and hold the eye button to see the camera without the look.
- **Tap to focus:** looks with a focus point (tilt-shift, zoom blur, vignettes) follow your tap on the preview.
- **Adjust:** every effect has sliders and color pickers. Each control has its own reset button. Effects can be randomized, reset, duplicated, reordered, mixed and turned off. **Remix** nudges the whole look in a new direction. **Add effect** opens a searchable, categorized effect browser.
- **Custom code:** write your own Metal pass, or let Claude write one. Turn on **Feedback** to give a pass its own previous frame, for trails and echoes.

**Resolution and smoothness.** Tap the megapixel chip in the top bar (or go to Settings → Camera & performance) to choose how many megapixels Shade processes:

| Setting | Size | Good for |
| --- | --- | --- |
| 0.5 MP | 540 × 960 | Smoothest on any iPhone |
| 0.9 MP | 720 × 1280 | Smooth on any iPhone |
| 2.1 MP | 1080 × 1920 | The default: sharp |
| 3.7 MP | 1440 × 2560 | Very sharp, heavier |
| 8.3 MP | 2160 × 3840 (4K) | Maximum detail; heavy looks can stutter |

Photos and videos are saved at that size. **Smooth mode** (on by default) watches how hard the GPU is working. When a look is too heavy to keep up, it lowers the live preview's resolution in steps, and raises it again once there's room. Photos are still captured at the full resolution you chose. Turn on **Show frame rate** to see the frame rate, megapixels and GPU time live.

You can also capture photos and (silent) videos to your library, preview looks on a still photo, tweak every parameter with sliders and color pickers, reorder or add passes, edit the Metal code in the app, and share looks as `.shade` files.

## Install it on your iPhone (sideloading)

The app isn't on the App Store, so you install it yourself. Every push to this repo builds an **unsigned `.ipa`** on GitHub Actions. A sideloading tool signs it with your Apple ID when it installs.

### 1. Get the `.ipa`

- **From a release** (easiest): open the repo's **Releases** page and download `Shade.ipa`. To make a release, go to **Actions → Build unsigned IPA → Run workflow**, tick **Publish a GitHub Release**, and run it. Pushing a tag like `v1.0.0` does the same.
- **From a workflow run**: **Actions → latest "Build unsigned IPA" run → Artifacts → Shade-ipa**. This downloads a zip that contains `Shade.ipa`.

### 2. Install it

Pick one:

- **Sideloadly** (Windows or Mac): connect the iPhone with a cable, drag `Shade.ipa` in, enter your Apple ID, and click Start.
- **AltStore / SideStore**: install AltStore (AltServer on your computer) or SideStore, then open `Shade.ipa` on the phone and choose AltStore/SideStore. They can refresh the app over Wi-Fi.
- **Xcode** (Mac): see "Build it yourself" below.

### 3. Trust it and run

- On iOS 16 or later, turn on **Settings → Privacy & Security → Developer Mode**, then restart the phone.
- If iOS says "Untrusted Developer", go to **Settings → General → VPN & Device Management**, tap your Apple ID, and trust it.
- With a free Apple ID the app has to be re-signed every **7 days**. AltStore and SideStore do this automatically; with Sideloadly, just install it again. Your recipes are kept.

### Build it yourself (Mac + Xcode)

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Shade.xcodeproj
```

Select the **Shade** target, choose your Team under **Signing & Capabilities** (change the bundle identifier if Xcode asks), plug in your iPhone, and press Run.

## Using Claude in the app

1. Create an API key at [console.anthropic.com](https://console.anthropic.com) → API Keys, and add some credit.
2. In Shade, open **Settings** (gear icon) and paste the key. It is stored only in the iPhone Keychain and is only sent to `api.anthropic.com`.
3. Tap the **sparkles** button, choose **Claude**, pick up to 4 images or videos (videos are sampled to 4 frames), optionally describe what you want, and tap **Generate shader**.

The default model is Claude Opus 5.5 at effort *high*; you can switch to Sonnet 5.5, Haiku 5.5 or Fable 5.1 in Settings. One generation typically costs a few cents. Requests opt into the API's server-side refusal fallback, so if a safety classifier declines a request it's retried on a suitable fallback model.

A note on what "AI learns the style" means here: Claude doesn't train a model on your image. It looks at the image, works out how the look is made (palette, line work, texture, lighting, motion), and writes shader code that recreates it. The shader then runs on your camera at 30 fps entirely on the phone.

## Recipe format

A look is a JSON *recipe*: an ordered list of passes. Each pass is either one of the built-in effects with parameter values, or custom Metal code:

```json
{
  "format": "shade.recipe/1",
  "name": "Neon Comic",
  "passes": [
    { "effect": "posterize", "params": { "levels": 5 } },
    {
      "name": "Glow outlines",
      "code": "float4 shade(float2 uv, float2 res, float time, texture2d<float> tex, texture2d<float> orig, sampler smp, constant ShadeParams& P) { ... }",
      "params": [{ "name": "glow", "type": "float", "value": 1.2, "min": 0, "max": 4 }]
    }
  ]
}
```

Built-in effects (43), by category:

- **Film & Nostalgia:** faded film, light leaks, dust & scratches, flicker & gate weave, cross process, instant photo frame, vignette, film grain, sepia
- **Dreamy & Light:** Orton glow, pastel, dreamy haze, sparkles, prism rainbow, tilt-shift, zoom blur, dream trails (motion trails), bloom, blur
- **Retro Tech:** VHS tape, date stamp, CRT scanlines, pixelate, dither, glitch
- **Color & Tone:** color grade, split tone, palette map, duotone, hue shift, invert
- **Artistic:** posterize, ink outlines, halftone, oil paint, pencil sketch, thermal
- **Lens & Distortion:** chromatic aberration, wave, kaleidoscope, mirror
- **Utility:** sharpen, blend original

The full specification, with every parameter, is in [`PROMPT.md`](PROMPT.md) (generated from `Shade/Recipe/RecipeSpec.swift`). See [`Examples/watercolor.shade`](Examples/watercolor.shade) for a complete recipe.

Recipes are stored as `.shade` files in **Files → On My iPhone → Shade → Recipes**. You can AirDrop them, and opening a `.shade` file imports it.

## How it works

```
Packages/ShadeCore/          platform-independent core (builds and tests on macOS and Linux)
  Recipe/                    model, RecipeCodec (all JSON in/out), RecipeValidator, limits
  Effects/                   built-in effects and preset looks
  Shaders/                   Metal source generation for a pass
  Storage/                   RecipeLibrary (.shade files), SessionStore (state.json), LegacyMigration
  Claude/                    Messages API client, retry policy, settings
  Generation/                StyleGenerator: ask Claude -> validate -> compile -> send errors back
  Analysis/                  on-device style analyzer
  Errors/, Logging/          ShadeError (stable codes), os.Logger wrapper
  Sources/shadercheck/       CI tool: writes every shader to .metal files and regenerates PROMPT.md
  Tests/ShadeCoreTests/      unit tests
Shade/                       the iOS app
  App/                       ShadeApp, AppModel (camera, capture, notices), LookStore, GenerationController
  Services/                  camera, Metal shader compiler + cache, Keychain, Photos, media loading, temp files
  Rendering/                 Metal renderer, video recorder, display shader
  Views/, Support/           SwiftUI screens and helpers
```

- **Rendering.** Rendering runs on its own thread and draws straight into a `CAMetalLayer`, so the interface never waits for the GPU. Each camera frame is rendered exactly once. At most two frames are on the GPU at a time, and when the GPU falls behind, the newest frame is dropped rather than queued, so delay never builds up. Compiled shaders are cached by structure, so moving a slider only uploads new numbers. Camera frames become Metal textures without a copy. They run through each pass into half-float ping-pong textures, then go to the screen, a photo or an H.264 video. Each pass is wrapped in generated Metal source and compiled **at runtime** with `MTLDevice.makeLibrary(source:)`. That's what lets Claude-written shaders run without rebuilding the app. One thread-safe pipeline cache is shared by the renderer and by AI validation.
- **Trust boundary.** Everything from outside the app goes through `RecipeCodec` and `RecipeValidator` before use: files, the clipboard and Claude's replies. That covers size limits (1 MB input, 16 passes, 32 params, 20k characters of code per pass), the format version, effect names and safe parameter identifiers. Custom code only ever runs on the GPU, with read access to the camera image and nothing else. If a pass crashes the GPU (for example, an endless loop), the renderer turns custom passes off and says so.
- **Storage.** Recipes are one `.shade` file each in `Documents/Recipes`, written atomically. Files that can't be read are listed in the Library with the reason, never silently dropped. The on-screen look, including unsaved edits, is saved to `Application Support/Shade/state.json` shortly after you stop editing, and immediately when the app goes to the background. The API key lives in the Keychain (this device only).
- **Claude.** The client retries 408/429/5xx/529 and network drops with exponential backoff and jitter, honouring `retry-after`, at one layer only. It never retries 4xx errors. Errors carry stable codes (`ShadeError.Code`) and request IDs for the logs.
- **Logs.** Open Console.app on a Mac with the iPhone connected and filter on subsystem `com.shadeapp.shade`. The logs never contain the API key, images or shader code.

### Running the tests

```bash
swift test --package-path Packages/ShadeCore
```

```bash
./scripts/check-shaders.sh
```

The second command generates every shader. On a Mac it also compiles each one with Apple's offline Metal compiler. CI runs both before building the app.

## Limitations

- Videos are recorded without audio.
- The app is portrait-only and iPhone-only, and needs iOS 16 or later.
- Custom shaders can be expensive; very heavy code may drop below 30 fps on older iPhones.
