import CoreGraphics
import Foundation

/// Whether a shot needs to be set up indoors, outdoors, or either.
enum ShootingContext {
    case indoor
    case outdoor
    case either
}

/// One assignment: what to photograph, where to find it, and how to stand.
///
/// The framing block is what makes an assignment more than a text prompt — it
/// reconfigures the live coach, so picking "overhead flat lay" actually
/// changes what the aim marker asks of you.
struct ShotAssignment: Identifiable, Equatable {
    let id: String
    /// Short name, shown on the card.
    let title: String
    /// What to point the camera at.
    let subject: String
    /// Where to go to find it.
    let findIt: String
    /// Ordered physical directions. Kept concrete: distances, angles, sides.
    let steps: [String]
    /// The photographic reason, so the app teaches rather than just commands.
    let why: String
    let framing: FramingTarget
    /// Scene kinds this assignment suits, used for matching against what the
    /// camera is actually seeing.
    let sceneKinds: [SceneKind]
    /// Light this shot needs.
    let light: Set<LightPhase>
    let context: ShootingContext
    /// 1 = anyone can do it now, 3 = needs patience or setup.
    let difficulty: Int

    static func == (lhs: ShotAssignment, rhs: ShotAssignment) -> Bool { lhs.id == rhs.id }
}

/// The everyday shot library.
///
/// Scope is deliberately broad — portraits, pets, food, landscape, street,
/// still life, night — because the point is to have something worth shooting
/// wherever you happen to be standing.
enum ShotLibrary {

    static let all: [ShotAssignment] = [

        // MARK: People

        ShotAssignment(
            id: "window-portrait",
            title: "Window-light portrait",
            subject: "Someone's face, lit by a window",
            findIt: "Any room with a decent-sized window. Turn off the overhead lights — mixing them with daylight makes skin go an odd colour.",
            steps: [
                "Put your subject about an arm's length from the glass, side-on to it, not facing it.",
                "Stand with your shoulder to the window so you're shooting across the light.",
                "Ask them to turn their nose slowly toward the window until a small triangle of light appears on the cheek furthest from you. Stop there.",
                "Fill the frame from chest to just above the head, and keep their eyes on the upper third.",
            ],
            why: "A big window close by is a huge, soft light source. Across the face it carves out shape; straight on it flattens everything.",
            framing: {
                var f = FramingTarget.default(for: .portrait)
                f.subjectArea = 0.14...0.44
                f.usesEyeLine = true
                f.eyeLineY = 0.35
                return f
            }(),
            sceneKinds: [.portrait, .groupPortrait],
            light: [.softDaylight, .harshDaylight, .goldenHour, .unknown],
            context: .indoor,
            difficulty: 1),

        ShotAssignment(
            id: "golden-rim",
            title: "Backlit at golden hour",
            subject: "A person with the low sun behind them",
            findIt: "Outside, somewhere with an unobstructed low sun — a park, a car park, the end of a street.",
            steps: [
                "Put the sun directly behind your subject's head, so you're shooting into it.",
                "Step close enough that their head and shoulders fill most of the frame.",
                "Move a few inches until the sun is just hidden behind their head — you should see a bright rim around their hair and no flare washing the frame out.",
                "Tap their face on screen so the phone exposes for them, not the sky.",
            ],
            why: "Backlight separates someone from the background with a bright outline, and low sun is weak enough that you can still hold detail in their face.",
            framing: {
                var f = FramingTarget.default(for: .portrait)
                f.subjectArea = 0.18...0.55
                f.eyeLineY = 0.38
                f.targetMedianLuma = 0.40
                return f
            }(),
            sceneKinds: [.portrait, .groupPortrait],
            light: [.goldenHour],
            context: .outdoor,
            difficulty: 2),

        ShotAssignment(
            id: "open-shade",
            title: "Open-shade portrait",
            subject: "A face out of direct sun",
            findIt: "The shaded side of a building, under an awning, inside a doorway — anywhere with open sky in front but no sun on the face.",
            steps: [
                "Stand your subject just inside the shade, facing out toward the bright open sky.",
                "Keep yourself in the shade too, so no sun hits your lens.",
                "Check their eyes have light in them — if the sockets look dark, move them a step toward the edge of the shade.",
                "Frame head and shoulders, eyes on the upper third.",
            ],
            why: "Midday sun overhead makes raccoon eyes and hard shadows. Open shade swaps it for a soft wall of light from the sky.",
            framing: {
                var f = FramingTarget.default(for: .portrait)
                f.subjectArea = 0.15...0.48
                return f
            }(),
            sceneKinds: [.portrait, .groupPortrait],
            light: [.harshDaylight, .softDaylight],
            context: .outdoor,
            difficulty: 1),

        ShotAssignment(
            id: "looking-room",
            title: "Looking room",
            subject: "Someone gazing out of the frame",
            findIt: "Anywhere you can shoot a person side-on — a window seat, a bench, a street corner.",
            steps: [
                "Have them look off to one side, past the edge of the frame.",
                "Put them on the third they're looking away from, so the empty space is in front of their gaze.",
                "Keep that empty space clean — a blank wall or open sky works better than clutter.",
                "Shoot from their eye height, not above it.",
            ],
            why: "A figure pressed against the edge they're facing feels trapped. Space in front of the gaze gives the picture somewhere to go.",
            framing: {
                var f = FramingTarget.default(for: .portrait)
                f.subjectArea = 0.10...0.35
                f.placement = .thirds
                f.aimTolerance = 0.08
                return f
            }(),
            sceneKinds: [.portrait, .street],
            light: [.softDaylight, .goldenHour, .harshDaylight, .blueHour, .unknown],
            context: .either,
            difficulty: 2),

        ShotAssignment(
            id: "hands-doing",
            title: "Hands at work",
            subject: "A pair of hands mid-task",
            findIt: "Someone cooking, writing, fixing, playing an instrument, holding a mug.",
            steps: [
                "Get in close — hands and the thing they're touching, nothing else.",
                "Shoot from slightly above, looking down the forearms.",
                "Wait for the moment the hands are actually doing something, not resting.",
                "Keep the background to a plain surface so the hands read instantly.",
            ],
            why: "Hands tell a story without needing a face, and they're the easiest way to photograph a person who hates being photographed.",
            framing: {
                var f = FramingTarget.default(for: .stillLife)
                f.subjectArea = 0.25...0.70
                f.placement = .thirds
                return f
            }(),
            sceneKinds: [.stillLife, .portrait, .interior],
            light: [.softDaylight, .goldenHour, .unknown],
            context: .either,
            difficulty: 1),

        ShotAssignment(
            id: "silhouette",
            title: "Silhouette",
            subject: "A shape blacked out against a bright sky",
            findIt: "Outside near sunset, or a bright doorway or window seen from a dark room.",
            steps: [
                "Put your subject directly between you and the brightest part of the sky.",
                "Tap the bright background to meter for it — your subject should fall to near-black.",
                "Pick a subject with a clean, readable outline, and keep it clear of other shapes.",
                "Keep the horizon level and low in the frame.",
            ],
            why: "Stripping someone to an outline removes all the detail and leaves only gesture, which is often the strongest part of the picture anyway.",
            framing: {
                var f = FramingTarget.default(for: .landscape)
                f.subjectArea = 0.06...0.40
                f.horizon = .lowerThird
                f.targetMedianLuma = 0.38
                return f
            }(),
            sceneKinds: [.landscape, .portrait, .street],
            light: [.goldenHour, .blueHour],
            context: .either,
            difficulty: 2),

        // MARK: Pets

        ShotAssignment(
            id: "pet-eye-level",
            title: "Pet at their eye level",
            subject: "A dog or cat, head-on",
            findIt: "Wherever the animal has settled. Don't move them — go to them.",
            steps: [
                "Get your phone down to their eye height. Kneel, or lie down if you have to.",
                "Come in close enough that the head fills a good third of the frame.",
                "Tap their nearest eye to focus on it.",
                "Make a noise just before you shoot to get the ears up and the eyes toward you.",
            ],
            why: "Shooting down at an animal makes them look small and distant. At their level you get their expression instead of the top of their head.",
            framing: {
                var f = FramingTarget.default(for: .pet)
                f.subjectArea = 0.18...0.60
                f.aimTolerance = 0.13
                return f
            }(),
            sceneKinds: [.pet],
            light: [.softDaylight, .goldenHour, .harshDaylight, .unknown],
            context: .either,
            difficulty: 1),

        ShotAssignment(
            id: "pet-texture",
            title: "Fur and texture",
            subject: "A close detail of an animal — paw, nose, ear, coat",
            findIt: "A sleeping or settled pet in soft light.",
            steps: [
                "Get as close as your phone will still focus, usually a hand's width.",
                "Find light raking across the fur from the side so the texture catches.",
                "Fill the frame completely — no background at all.",
                "Hold very still; at this distance the slightest movement blurs it.",
            ],
            why: "Side light across texture is what makes fur, fabric and skin feel touchable rather than flat.",
            framing: {
                var f = FramingTarget.default(for: .pet)
                f.subjectArea = 0.45...0.95
                f.placement = .centered
                f.aimTolerance = 0.12
                return f
            }(),
            sceneKinds: [.pet, .stillLife],
            light: [.softDaylight, .goldenHour, .unknown],
            context: .either,
            difficulty: 2),

        // MARK: Food and drink

        ShotAssignment(
            id: "flat-lay",
            title: "Overhead flat lay",
            subject: "A plate, shot straight down",
            findIt: "A table near a window. Move the plate to the window if you need to.",
            steps: [
                "Stand directly over the plate and hold the phone flat, parallel to the table.",
                "Turn the plate so the light from the window comes across it, not over your own shoulder.",
                "Centre the plate and leave an even margin of table all the way round.",
                "Take anything off the table that isn't part of the picture.",
            ],
            why: "Straight down turns a meal into a graphic, symmetrical shape. It only works if the phone is genuinely flat — a few degrees of tilt reads as a mistake.",
            framing: {
                var f = FramingTarget.default(for: .food)
                f.subjectArea = 0.30...0.72
                f.placement = .centered
                f.aimTolerance = 0.06
                f.targetMedianLuma = 0.54
                return f
            }(),
            sceneKinds: [.food, .stillLife],
            light: [.softDaylight, .harshDaylight, .goldenHour, .unknown],
            context: .either,
            difficulty: 1),

        ShotAssignment(
            id: "diners-view",
            title: "The diner's view",
            subject: "A dish from where you'd actually sit",
            findIt: "Any table with side light from a window.",
            steps: [
                "Drop down to about 30 degrees above the table — roughly the angle you see your own plate from.",
                "Put the window to your left or right so the food is side-lit and has shadows.",
                "Fill two thirds of the frame with the dish, and let the background fall away behind it.",
                "Focus on the nearest edge of the food, not the middle of the plate.",
            ],
            why: "This is the angle that makes food look appetising, because it's the one you see food from before you eat it.",
            framing: {
                var f = FramingTarget.default(for: .food)
                f.subjectArea = 0.30...0.78
                f.placement = .thirds
                f.aimTolerance = 0.09
                return f
            }(),
            sceneKinds: [.food],
            light: [.softDaylight, .harshDaylight, .goldenHour, .unknown],
            context: .either,
            difficulty: 1),

        ShotAssignment(
            id: "backlit-glass",
            title: "Backlit glass",
            subject: "A drink with light coming through it",
            findIt: "A glass or mug on a table, with a window directly behind it.",
            steps: [
                "Put the glass between you and the window so the light passes through the liquid.",
                "Get down level with the glass rather than looking down into it.",
                "Tap the glass on screen to meter for it — the window behind will go bright, and that's fine.",
                "Look for steam or bubbles and shoot while they're there.",
            ],
            why: "Light through a liquid shows its colour and clarity. Light bounced off the front of it just shows reflections of the room.",
            framing: {
                var f = FramingTarget.default(for: .food)
                f.subjectArea = 0.20...0.60
                f.placement = .thirds
                f.targetMedianLuma = 0.48
                return f
            }(),
            sceneKinds: [.food, .stillLife],
            light: [.softDaylight, .harshDaylight, .goldenHour, .unknown],
            context: .indoor,
            difficulty: 2),

        // MARK: Landscape and outdoors

        ShotAssignment(
            id: "foreground-anchor",
            title: "Landscape with a foreground",
            subject: "A wide view with something solid in the near ground",
            findIt: "Any open view — a hill, a shoreline, a field, a long street.",
            steps: [
                "Find the view first, then look down at your feet for something to put in front of it: a rock, a flower, a fence post, a puddle.",
                "Get low and close to that object, within a couple of feet.",
                "Put the horizon on the upper or lower third — never through the middle.",
                "Check all four corners for anything distracting before you shoot.",
            ],
            why: "A wide view with nothing near the camera reads flat. A close foreground object gives the eye a starting point and the picture depth.",
            framing: {
                var f = FramingTarget.default(for: .landscape)
                f.subjectArea = 0.10...0.50
                f.horizon = .upperThird
                f.placement = .lowerThirdHorizontal
                return f
            }(),
            sceneKinds: [.landscape],
            light: [.goldenHour, .softDaylight, .blueHour, .harshDaylight],
            context: .outdoor,
            difficulty: 2),

        ShotAssignment(
            id: "minimal-horizon",
            title: "Minimal horizon",
            subject: "Almost nothing — sky, water, land, one small subject",
            findIt: "A beach, a big field, a flat view with an uncluttered sky.",
            steps: [
                "Put the horizon hard on the lower third and give the sky the rest.",
                "Find one small subject — a person, a tree, a boat — and place it well off centre.",
                "Make sure nothing else breaks the horizon line.",
                "Get the horizon dead level; at this simplicity any tilt is glaring.",
            ],
            why: "When you take almost everything out, the one thing left carries the whole picture. Empty space is the subject as much as the object is.",
            framing: {
                var f = FramingTarget.default(for: .landscape)
                f.subjectArea = 0.01...0.12
                f.horizon = .lowerThird
                f.placement = .thirds
                f.aimTolerance = 0.08
                return f
            }(),
            sceneKinds: [.landscape],
            light: [.goldenHour, .blueHour, .softDaylight, .harshDaylight],
            context: .outdoor,
            difficulty: 3),

        ShotAssignment(
            id: "golden-side-light",
            title: "Golden side light",
            subject: "Anything with texture, raked by low sun",
            findIt: "Outside within an hour of sunrise or sunset. Stand so the sun is 90 degrees to your left or right.",
            steps: [
                "Face a direction at right angles to the sun.",
                "Look for long shadows stretching across your subject — grass, brick, sand, bark.",
                "Include the shadows in the frame; they're the point, not a side effect.",
                "Keep the sun itself out of the frame to stop flare washing out the contrast.",
            ],
            why: "Low side light makes every texture stand up in relief. The same scene at noon has no shadows and looks like nothing.",
            framing: {
                var f = FramingTarget.default(for: .landscape)
                f.subjectArea = 0.15...0.70
                f.horizon = .avoidCentre
                return f
            }(),
            sceneKinds: [.landscape, .street, .architecture, .flora],
            light: [.goldenHour],
            context: .outdoor,
            difficulty: 1),

        // MARK: Street and architecture

        ShotAssignment(
            id: "leading-lines",
            title: "Leading lines",
            subject: "A line that runs from your feet into the distance",
            findIt: "A pavement, road markings, railings, a row of columns, a staircase, a fence.",
            steps: [
                "Stand so the line starts at the bottom edge of your frame.",
                "Centre yourself on the line and point straight down it.",
                "Put something at the far end for the line to arrive at — a person, a door, a tree.",
                "Hold the phone upright and level so the line doesn't skew.",
            ],
            why: "The eye follows a line whether you want it to or not. Aim it at your subject and the composition does itself.",
            framing: {
                var f = FramingTarget.default(for: .street)
                f.placement = .centered
                f.wantsLevelVerticals = true
                f.aimTolerance = 0.10
                return f
            }(),
            sceneKinds: [.street, .architecture, .interior],
            light: [.softDaylight, .goldenHour, .harshDaylight, .blueHour, .night, .unknown],
            context: .either,
            difficulty: 2),

        ShotAssignment(
            id: "symmetry",
            title: "Symmetry",
            subject: "Something that mirrors itself",
            findIt: "A building face, a tiled floor, a tunnel, a still puddle, a shop front.",
            steps: [
                "Find the centre line of the subject and put yourself exactly on it.",
                "Hold the phone square to the surface — not tilted up, down or sideways.",
                "Line the subject's centre up with the centre of the frame.",
                "Shuffle left and right an inch at a time until both halves genuinely match.",
            ],
            why: "Symmetry only works when it's exact. Nearly symmetrical looks like a mistake; perfectly symmetrical looks deliberate.",
            framing: {
                var f = FramingTarget.default(for: .architecture)
                f.placement = .centered
                f.wantsLevelVerticals = true
                f.aimTolerance = 0.05
                f.subjectArea = 0.25...0.95
                return f
            }(),
            sceneKinds: [.architecture, .interior, .street],
            light: [.softDaylight, .harshDaylight, .goldenHour, .blueHour, .night, .unknown],
            context: .either,
            difficulty: 2),

        ShotAssignment(
            id: "plumb-facade",
            title: "Straight-on facade",
            subject: "The flat face of a building",
            findIt: "A building you can stand well back from — across a street or a square.",
            steps: [
                "Back up until you can fit the whole face in without tipping the phone upward.",
                "Hold the phone perfectly upright. The app will tell you when it's plumb.",
                "Square yourself to the wall so its verticals run parallel to the frame edges.",
                "Fill the frame with the wall and let it run off all four edges if it will.",
            ],
            why: "Tilt the phone up at a building and its verticals converge, so it looks like it's falling over. Held plumb, they stay parallel.",
            framing: {
                var f = FramingTarget.default(for: .architecture)
                f.subjectArea = 0.35...0.98
                f.wantsLevelVerticals = true
                f.placement = .centered
                return f
            }(),
            sceneKinds: [.architecture],
            light: [.softDaylight, .goldenHour, .harshDaylight, .blueHour, .unknown],
            context: .outdoor,
            difficulty: 2),

        ShotAssignment(
            id: "frame-within-frame",
            title: "Frame within a frame",
            subject: "Your subject seen through an opening",
            findIt: "A doorway, an arch, a window, a gap in a hedge, between two parked cars.",
            steps: [
                "Find the opening first, then move until your subject sits inside it.",
                "Get close enough to the opening that its edges reach the sides of your frame.",
                "Let the near edges go dark — that frame of shadow is what isolates the subject.",
                "Tap the subject to expose for it, not for the dark surround.",
            ],
            why: "An opening in the foreground walls off everything distracting and points straight at what's inside it.",
            framing: {
                var f = FramingTarget.default(for: .street)
                f.placement = .centered
                f.subjectArea = 0.08...0.50
                f.aimTolerance = 0.08
                return f
            }(),
            sceneKinds: [.street, .architecture, .portrait, .interior],
            light: [.softDaylight, .harshDaylight, .goldenHour, .unknown],
            context: .either,
            difficulty: 3),

        ShotAssignment(
            id: "hard-shadow",
            title: "Hard shadow graphics",
            subject: "The shadow itself, not the thing casting it",
            findIt: "A sunlit wall or pavement in the middle of the day — railings, plants, a bike, a person.",
            steps: [
                "Look for a strong shadow falling across a plain, bright surface.",
                "Fill the frame with the surface so the shadow becomes the whole picture.",
                "Shoot square to the surface so the shadow stays a clean shape.",
                "Let the bright areas go bright and the shadow go properly dark — the contrast is the point.",
            ],
            why: "Hard midday sun is terrible for faces and brilliant for graphics. It's the one time of day you get shadows this crisp.",
            framing: {
                var f = FramingTarget.default(for: .stillLife)
                f.subjectArea = 0.20...0.90
                f.placement = .thirds
                f.targetMedianLuma = 0.42
                return f
            }(),
            sceneKinds: [.street, .architecture, .stillLife],
            light: [.harshDaylight],
            context: .outdoor,
            difficulty: 2),

        // MARK: Still life, detail, plants

        ShotAssignment(
            id: "negative-space",
            title: "One thing, lots of space",
            subject: "A single object on an empty background",
            findIt: "Any plain surface — a bare table, a painted wall, a sheet of paper, a pavement.",
            steps: [
                "Put one object on the plain surface and take everything else away.",
                "Place it well off centre, on a third.",
                "Leave the rest of the frame genuinely empty.",
                "Light it from one side so it has a shadow to sit in.",
            ],
            why: "Emptiness is what gives a single object weight. Fill the space and it becomes just another thing on a table.",
            framing: {
                var f = FramingTarget.default(for: .stillLife)
                f.subjectArea = 0.05...0.25
                f.placement = .thirds
                f.aimTolerance = 0.07
                return f
            }(),
            sceneKinds: [.stillLife, .flora, .food],
            light: [.softDaylight, .goldenHour, .harshDaylight, .unknown],
            context: .either,
            difficulty: 2),

        ShotAssignment(
            id: "close-texture",
            title: "Close texture",
            subject: "A surface, filling the whole frame",
            findIt: "Peeling paint, rust, bark, stone, fabric, water, cracked earth.",
            steps: [
                "Get close enough that the surface runs off all four edges.",
                "Find light coming across it from the side rather than straight on.",
                "Hold the phone parallel to the surface so it's sharp corner to corner.",
                "Brace against something — at this distance focus is unforgiving.",
            ],
            why: "Take away any sense of scale and a surface stops being an object and becomes a pattern.",
            framing: {
                var f = FramingTarget.default(for: .stillLife)
                f.subjectArea = 0.60...1.0
                f.placement = .centered
                f.aimTolerance = 0.15
                return f
            }(),
            sceneKinds: [.stillLife, .architecture, .flora],
            light: [.softDaylight, .goldenHour, .harshDaylight, .unknown],
            context: .either,
            difficulty: 1),

        ShotAssignment(
            id: "single-stem",
            title: "A single stem",
            subject: "One flower or leaf, lit from behind",
            findIt: "A plant on a windowsill, a garden, a verge, a bunch in a vase.",
            steps: [
                "Get the light behind the petal or leaf so it glows through.",
                "Crouch until you're level with the bloom instead of looking down on it.",
                "Pick an angle where the background is far away and plain — sky or deep shade.",
                "Fill a good third of the frame with the stem and leave the rest quiet.",
            ],
            why: "Leaves and petals are translucent. Light through them shows the veins and the colour; light on them just shows the surface.",
            framing: {
                var f = FramingTarget.default(for: .flora)
                f.subjectArea = 0.15...0.55
                f.placement = .thirds
                return f
            }(),
            sceneKinds: [.flora, .stillLife],
            light: [.goldenHour, .softDaylight, .harshDaylight, .unknown],
            context: .either,
            difficulty: 2),

        // MARK: Low light

        ShotAssignment(
            id: "pool-of-light",
            title: "Pool of light",
            subject: "Whatever is standing in the only bright patch",
            findIt: "After dark — under a streetlight, a shop window, a doorway, a lit sign.",
            steps: [
                "Find a single light source with darkness around it.",
                "Put your subject inside the lit patch and yourself in the dark.",
                "Tap the lit area to meter for it, and let everything else go black.",
                "Brace the phone against a wall or railing before you shoot.",
            ],
            why: "At night, don't fight the darkness — use it. One light with black around it does the isolating for you.",
            framing: {
                var f = FramingTarget.default(for: .nightScene)
                f.subjectArea = 0.10...0.55
                f.placement = .thirds
                f.targetMedianLuma = 0.24
                return f
            }(),
            sceneKinds: [.nightScene, .street, .portrait],
            light: [.night, .blueHour],
            context: .either,
            difficulty: 2),

        ShotAssignment(
            id: "blue-hour-window",
            title: "Blue hour windows",
            subject: "Lit windows against a deep blue sky",
            findIt: "Outside, twenty to forty minutes after sunset. A street of houses, a block of flats, a cafe front.",
            steps: [
                "Wait until the sky is deep blue but not yet black, and the interior lights are on.",
                "Find a building where the warm window light reads against the cool sky.",
                "Hold the phone plumb so the building's verticals stay straight.",
                "Expose so the sky keeps its colour — let the windows go a little bright.",
            ],
            why: "For about half an hour the sky and artificial light are the same brightness, so you can hold both. Before or after, one of them is gone.",
            framing: {
                var f = FramingTarget.default(for: .architecture)
                f.subjectArea = 0.25...0.85
                f.wantsLevelVerticals = true
                f.targetMedianLuma = 0.32
                return f
            }(),
            sceneKinds: [.architecture, .nightScene, .street],
            light: [.blueHour],
            context: .outdoor,
            difficulty: 2),

        ShotAssignment(
            id: "reflection-puddle",
            title: "Reflection",
            subject: "A scene doubled in water or glass",
            findIt: "A puddle after rain, a still pond, a polished floor, a shop window.",
            steps: [
                "Get the phone right down to the surface — almost touching it.",
                "Move until the reflection shows what you want, which is rarely where you'd normally stand.",
                "Decide whether to put the waterline through the centre for a mirror, or on a third to favour one half.",
                "Keep the phone level so the reflection doesn't skew.",
            ],
            why: "A reflection gives you two of the subject and a composition that's symmetrical for free. The whole trick is getting low enough.",
            framing: {
                var f = FramingTarget.default(for: .street)
                f.placement = .centered
                f.horizon = .centred
                f.aimTolerance = 0.08
                f.subjectArea = 0.15...0.80
                return f
            }(),
            sceneKinds: [.street, .architecture, .landscape, .nightScene],
            light: [.blueHour, .night, .goldenHour, .softDaylight, .harshDaylight, .unknown],
            context: .either,
            difficulty: 3),
    ]
}
