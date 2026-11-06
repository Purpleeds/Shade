# Shade

Real-time shaders for real life. Shade is an iPhone camera app that runs a stack of GPU shader passes over the live camera, so you see the world as a comic book, an oil painting, a thermal camera, or any style you show it.

You can make new looks three ways:

| Method | What happens | Needs |
| --- | --- | --- |
| **Claude (in app)** | Pick an image or video. Claude studies the style and writes a shader recipe, including custom Metal code. The app compiles it on your GPU, and if anything fails to compile it sends the errors back to Claude to fix (up to 2 rounds). | A Claude API key |
| **On-device** | Measures a reference image's palette, contrast, saturation, grain and vignette, then builds a look from the built-in effects. Instant and offline. | Nothing |
| **Claude chat** | Tap **Copy prompt**, paste it into [claude.ai](https://claude.ai) with your image or video, copy Claude's reply, then tap **Paste Claude's reply**. The same prompt is in [`PROMPT.md`](PROMPT.md). | A Claude account (free works) |

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

Built-in effects: color grade, posterize, ink outlines, pixelate, chromatic aberration, vignette, film grain, CRT scanlines, halftone, palette map, duotone, bloom, blur, sharpen, oil paint (Kuwahara), thermal, dither, wave, kaleidoscope, glitch, hue shift, pencil sketch, sepia, invert, mirror and blend-original. The full specification, with every parameter, is in [`PROMPT.md`](PROMPT.md) (generated from `Shade/Recipe/RecipeSpec.swift`). See [`Examples/watercolor.shade`](Examples/watercolor.shade) for a complete recipe.

Recipes are stored as `.shade` files in **Files → On My iPhone → Shade → Recipes**. You can AirDrop them, and opening a `.shade` file imports it.

## How it works

- `Shade/Camera`: AVFoundation capture, 1080p portrait BGRA frames.
- `Shade/Rendering`: a Metal renderer. Camera frames become textures without a copy (`CVMetalTextureCache`), run through each pass into half-float ping-pong textures, then go to the screen, a photo, or an H.264 video.
- `Shade/Recipe`: the recipe model, built-in effects and presets (pure Swift + Foundation). Each pass is wrapped in a generated Metal source file (helpers, a `ShadeParams` struct built from the pass's params, and entry points) and compiled **at runtime** with `MTLDevice.makeLibrary(source:)`. That's what lets Claude-written shaders run without rebuilding the app.
- `Shade/AI`: the Claude Messages API client, the generate → compile → fix loop, the video-frame sampler and the on-device style analyzer.
- `Tools/ShaderCheck` + `scripts/check-shaders.sh`: generate the Metal source for every built-in effect, preset and example, then compile each one with the offline Metal compiler on CI. They also regenerate `PROMPT.md`.

## Limitations

- Videos are recorded without audio.
- The app is portrait-only and iPhone-only, and needs iOS 16 or later.
- Custom shaders can be expensive; very heavy code may drop below 30 fps on older iPhones.
