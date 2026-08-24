# Third Hand logo animation

A seven-second, 1254 × 1254 Remotion composition based on the supplied Third
Hand artwork.

The hand enters from the lower left and settles with a gentle wrist pivot. The
ring remains fixed while three independent, upright heads travel slowly around
it as the name appears letter by letter. The whole emblem drifts gently up and
down in sync with the hand, its center star pulses softly, and the purple dot
over the `i` bounces before every motion eases to a stop.

The source is deterministically separated into true transparent PNG layers for
the hand, each head, center star, every individual letter, and the `i` dot. The
stationary ring is rebuilt as its own smooth transparent PNG so it remains
continuous while the heads move. Run `npm run extract-assets` to rebuild all
layers. The main `ThirdHandLogo` composition has no background and is ready for
app onboarding. The `ThirdHandLogoDebug` composition uses a checkerboard
background to reveal accidental opaque backgrounds or cross-layer fragments.

## Preview

```console
npm run dev -- --no-open
```

Open the `ThirdHandLogo` composition in Remotion Studio.

## Render

```console
npm run render
```

The ProRes 4444 video with alpha is written to
`out/third-hand-logo-transparent.mov`. Run `npm run render:webm` for a VP9 WebM
with alpha for browser playback.
