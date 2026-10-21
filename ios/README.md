# Framewise

A native iOS camera that tells you what to photograph, directs you to the
shot, auto-edits what you capture, and writes it straight into your Photos
library. No export step, no share sheet.

Point it at anything at all. Three things happen at once:

1. **It reads the scene and tells you where to stand.** The panel at the top
   names what it thinks it's looking at — *"An animal, shot from above, in flat
   light from behind you"* — and then gives you the moves that would actually
   change the picture: *Get down to its eye level*, *Walk around to the lit
   side*, *You're shooting into the sun*, *Move in to lose the clutter*. Each
   one comes with the reason, so it teaches rather than just commands.
2. **It directs your hands.** A ring marks where the subject should sit, a dot
   rides the subject itself, and one large instruction tells you the single
   next thing to do: *Pan right*, *Tilt down*, *Level it up*. The ring round
   the shutter fills as the frame improves.
3. **It finishes the photo.** On capture the frame is straightened, exposed,
   white-balanced, tone-mapped and sharpened according to what kind of photo
   it is, then saved to Photos and collected in a *Framewise* album. The review
   sheet then shows you how to shoot that same scene better next time.

The division of labour between (1) and (2) is the thing to understand: the
advisor handles decisions you make **with your feet** — height, angle, which
side the light comes from, whether to come back later. The coach handles the
last few inches you fix **without moving** — pan, tilt, level, framing.

With auto-shutter on (the default) you never press anything: hold the frame
where it asks and the photo takes itself.

---

## Building it

You need a Mac with Xcode 16 or newer, and an iPhone. **The simulator is no
use here** — there is no camera and no motion sensor, so there is nothing to
coach.

```sh
open ios/Framewise.xcodeproj
```

1. Select the **Framewise** target → **Signing & Capabilities**.
2. Set **Team** to your own Apple ID. A free account is fine; it signs for
   7 days at a time, after which you re-run from Xcode.
3. If the bundle identifier `com.example.framewise` is taken, change it to
   something unique like `com.yourname.framewise`.
4. Plug in your iPhone, select it as the run destination, and press ⌘R.
5. Accept the camera prompt, and the Photos prompt on your first shot.

On first launch iOS will ask to trust the developer certificate: **Settings →
General → VPN & Device Management → your Apple ID → Trust**.

### If the project won't open

The checked-in project file is hand-written and relies on Xcode 16's
synchronized folder groups. On an older Xcode, regenerate it:

```sh
brew install xcodegen
cd ios && xcodegen generate
```

## Permissions, and what they're for

| Permission | Why | Required? |
|---|---|---|
| Camera | The live frame it coaches and captures | Yes |
| Photos | Saving the finished photo | Yes |
| Location | Solar position, to time golden hour and work out where the sun is relative to where you're pointing | No — falls back to the clock |
| Compass | Camera bearing, so "you're shooting into the sun" can be literal rather than guessed | No — advice falls back to reading the frame's own brightness |

Location is read at kilometre accuracy, used only to compute where the sun is,
and never stored or transmitted. The app makes no network requests at all;
there is no networking code in it.

---

## How it works

### Seeing the scene — `Analysis/`

`FrameAnalyzer` runs the live camera frames through Vision and publishes a
`SceneSignals` snapshot. Cost is the main constraint, so the work is tiered:

- **Saliency and faces** at ~8 Hz, which is fast enough that the aim marker
  feels stuck to the subject.
- **Whole-image classification** at ~1 Hz. It is far heavier, and what kind of
  photo you are taking does not change frame to frame.
- **Tone statistics** on every analysed frame, sampled on a 64×64 grid
  straight out of the BGRA buffer. Gives mean, median, 5th/95th percentiles,
  clipping fractions, saturation, and both gray-world and white-patch colour
  estimates.
- **Sharpness** from Laplacian variance over a 96×96 window at native
  resolution — the downsampled grid has no high-frequency detail left, so it
  cannot distinguish sharp from blurred.

The subject anchor comes from Vision's attention-based saliency, overridden by
a face when one is present: people look at faces, and saliency often latches
onto a bright background instead.

Horizon position is derived from **device attitude and lens field of view**,
not from looking for a horizon line in the pixels. That works on a featureless
sky, through a window, and when the real skyline is behind buildings.

`MotionMonitor` takes angles from the gravity vector rather than Euler angles,
which stay meaningful when you are shooting straight down at a plate.

### Deciding what to say — `Coaching/`

`CompositionCoach` is a pure function of `(SceneSignals, FramingTarget)`. It
runs about a dozen rules — level, subject placement, subject size, eye line,
clipping at the frame edge, horizon placement, exposure, backlight, shake,
focus, edge clutter, converging verticals — and each returns a 0–1 score, a
weight, and possibly one directive.

Only the single most urgent directive is ever shown. A list of everything
wrong with a frame is accurate and useless; the next single thing to do is
actionable.

`DirectiveStabilizer` stops the text flickering. Near a threshold two rules
trade places constantly, so a new directive has to hold for 0.45 s before it
takes over — unless it is at least 3 priority steps more urgent, in which case
waiting would be worse than switching.

**Sign conventions** are the easiest thing to get wrong here, so they are
written down at each site. Panning the camera right sweeps the scene *left*
across the frame; tilting down sweeps it *up*. So moving a subject onto the
left third means panning right.

### Where to stand — `Coaching/AngleAdvisor.swift`

The default coaching mode, and a pure function of the signals like the coach
is. It generates advice along six axes and shows the top four, because four is
about as much as anyone can hold in their head while also looking at a
subject:

- **Light** leads, because it is the thing you cannot fix afterwards and the
  thing that most changes the photo. Backlight is checked first since it's the
  one condition that actively fights you.
- **Height** is next, because it's the correction that most often transforms a
  snapshot and almost nobody makes it unprompted — people shoot everything
  from standing eye level because that's where their eyes already are.
- Then **distance**, **angle**, **background** and **timing**.

Two inputs make the light advice concrete rather than generic:

**Sun bearing relative to the camera.** The compass gives the camera's
bearing, `SunPosition` gives the sun's azimuth, and the difference says whether
you're shooting into the sun (within 40°), across it (60–120°, the good case),
or with it behind you (beyond 140°, flat and shadowless). That's what lets the
app say *"turn 90° so the sun is over your shoulder"* instead of *"the light is
bad"*.

**Light direction read off the frame.** `ToneAnalyzer` measures mean luma per
half of the frame, and the imbalance says which way the light falls. This is
what works indoors, where there's no sun bearing to use: a brighter left half
means the window is on your left, so the advice becomes *"keep it to the side,
put the subject an arm's length from the glass"*. The sensor buffer is
landscape-native and the frame is portrait, so that mapping is rotated before
use — getting it backwards would have the app pointing you at the wrong side of
the room.

Advice is recomputed about once a second, not on every analysed frame.
Positional advice that rewrites itself eight times a second is unreadable, and
the underlying facts barely change that fast.

### Assignments — `Coaching/ShotLibrary`, `ShotDirector` (optional)

Behind a preference, off by default: instead of reading the scene, the panel
hands you shots to go and find. 24 assignments across portraits, pets, food,
landscape, street, architecture, still life, plants and night. Each carries a
`FramingTarget`, so picking "overhead flat lay" genuinely reconfigures the
coach — it switches the aim rule to centred, tightens the tolerance, and
starts caring whether the phone is flat.

`ShotDirector` scores every assignment against the moment rather than drawing
at random. Light is a hard filter: suggesting a blue-hour shot at eleven in the
morning is the fastest way to make the app feel stupid.

It's off by default because being told to go find a window portrait isn't much
help when you're stood in a field. Turn it on in Settings → Coaching.

`SunPosition` implements the standard NOAA solar approximation — accurate to
well under a degree, which is far better than needed to say "golden hour in
about forty minutes". Golden hour is taken as solar elevation −1° to +6°, blue
hour −6° to −1°.

### Finishing the photo — `Editing/`

Measure, then decide, then apply. Statistics come off the captured frame
first, become an `EditRecipe` of explicit numbers, and only then build the
filter chain. That ordering is what lets the editor leave a good frame alone
instead of pushing every photo toward the same preset.

Order of operations:

1. **Straighten** from the roll angle at capture, but only between 0.3° and
   8°: below that nobody can see it, above it is probably deliberate.
2. **Exposure** toward the scene's target median, clamped asymmetrically and
   backed off when highlights are already clipping.
3. **White balance** as the geometric mean of gray-world and white-patch
   estimates. Neither is reliable alone — gray-world is thrown by a frame
   dominated by one colour, white-patch by a specular glint.
4. **Shadows and highlights**, in proportion to how much is actually crushed
   or blown rather than by a fixed amount.
5. **Tone curve**, strength scaled by how flat the frame already is, with a
   black point put back underneath any significant shadow lift.
6. **Vibrance** scaled by existing saturation, so a vivid sunset gets none and
   a flat overcast street gets the full dose.
7. **Clarity, sharpening, noise reduction**, with detail backed off when noise
   reduction is heavy — the two fight each other and leave a plastic texture.

Scene presets do the rest. Portraits get gentler contrast, much less clarity
and a weaker colour correction, because sharpening is unkind to skin and warm
casts on skin usually read as pleasant. Night scenes keep a low target median
and held-down blacks: lifting a night shot to a daylight median is the single
most common way auto-edits ruin them. Golden hour and blue hour have their
colour correction cut hard, because that cast *is* the photograph.

Working space is Display P3 — gamma-encoded, so tone decisions line up with
the perceptual statistics measured earlier, and wide enough not to clip the
camera's gamut the way sRGB would. Output is HEIF where supported, JPEG
otherwise, with EXIF/TIFF/GPS carried across so the saved asset keeps its
date, lens data and location.

The capture review sheet shows the recipe in plain language. An auto-editor
that works invisibly is impossible to trust or argue with; one that says it
added half a stop and warmed the white balance is something you can learn from
and switch off.

### Saving — `Library/PhotoSaver.swift`

`PHAssetCreationRequest` writes the edited photo into the camera roll and adds
it to a named album. Album management needs read-write access, so if only
add-only is granted the photo still saves — it just isn't grouped. Losing the
album is a much smaller loss than losing the photo.

---

## Layout

```
ios/Framewise/
  FramewiseApp.swift          app entry
  Analysis/                   Vision, tone statistics, device attitude
  Camera/                     AVCaptureSession, preview layer, capture delegate
  Coaching/                   angle advisor, composition rules, shot library, sun
  Editing/                    scene presets and the Core Image pipeline
  Library/                    Photos library writes
  UI/                         viewfinder, overlay, assignment card, settings
  Support/                    coordinate mapping, settings, haptics
```

## Known limits

- **Portrait only.** The analysis assumes the portrait frame orientation
  throughout. Landscape would need the Vision orientation, the buffer
  rotation, and the focus-point mapping all generalised together.
- **No raw or ProRAW.** Capture is HEIF/JPEG, so the editor works on
  already-demosaiced, already-tone-mapped data. Raw would give the exposure
  and white-balance stages considerably more room.
- **The "soft focus" check is conservative.** Sharpness is unreliable on
  genuinely smooth scenes — a clear sky reads as blur — so it only fires when
  the frame has contrast to resolve and the phone is otherwise steady.
- **Scene classification is keyword-matched** from Vision's label list rather
  than a purpose-trained model. It is right often enough to pick a sensible
  preset, and faces and shooting angle override it where they are decisive.
- **The location toggle takes effect on next launch**, since the director
  starts location services when it is created.
- **Sun-relative light advice needs the compass.** Without a heading fix the
  advisor falls back to reading the frame's own brightness, which still gets
  left/right and backlight, but can't tell you where the sun is. Heading
  calibration prompts are suppressed so they never interrupt the viewfinder.
- **The scene read is only as good as the classifier.** When it guesses wrong
  the positional advice will be aimed at the wrong kind of photo, which is why
  the panel shows its read on the first line — so you can see it's wrong before
  you act on it.
- Untested on device: there is no Mac or iPhone in the environment this was
  written in, so it has had a careful review pass but has never been compiled
  or run. Expect to fix a few small things on first build.
