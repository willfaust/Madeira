// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  What a setting in a game's .ini file does, for the ⓘ in Game details ›
//  Settings files and the names offered by "Add setting". All texts are our
//  own words.
//
//  Three steps, best first:
//  1. a list of settings by name (Unreal Engine 4 and 5, Unreal Engine 3,
//     Bethesda's Gamebryo and Creation games, RPG Maker, CryEngine, Source,
//     id Tech 3 and 4, Godot, Unity's boot.config), with a plain title;
//  2. a group a name starts with (r.Lumen., r.Shadow., sg., mat_, sys_spec_, ...);
//  3. words in the name that most games use the same way (VSync, Fullscreen,
//     ShadowQuality, ...), said as a guess.
//  A setting none of these know says so, and shows its name split into words.
//
//  Foundation only: tests/host/check-ini-editor.py compiles it with the model
//  part of GameIniFiles.swift.
//

import Foundation

/// What the ⓘ shows for one setting.
struct IniSettingInfo: Equatable {
    /// A short plain name ("Texture memory (MB)"); nil when no list knows the setting.
    let title: String?
    /// What the setting does.
    let text: String
    /// True when the text was worked out from the words in the name.
    let guessed: Bool
    /// False when nothing at all is known about the setting.
    let known: Bool
}

enum IniSettingHelp {
    struct Entry {
        /// As games write it; "[Game]Title" applies only in that section.
        let key: String
        let title: String
        let text: String
        /// The key without its section.
        var name: String {
            guard key.hasPrefix("["), let close = key.firstIndex(of: "]") else { return key }
            return String(key[key.index(after: close)...])
        }
    }

    /// The setting's description, or nil when nothing is known about it.
    static func describe(key: String, section: String = "") -> String? {
        let found = info(key: key, section: section)
        return found.known ? found.text : nil
    }

    static func info(key: String, section: String = "", value: String? = nil) -> IniSettingInfo {
        let name = plainKey(key)
        if let entry = known["[\(section.lowercased())]" + name.lowercased()] ?? known[name.lowercased()] {
            return IniSettingInfo(title: entry.title, text: entry.text, guessed: false, known: true)
        }
        let readable = readableName(name)
        let typeNote = kind(name, value: value).map { " " + $0 } ?? ""
        if let group = group(name) {
            return IniSettingInfo(title: nil, text: group + " No notes for this exact setting yet. Its name reads as “\(readable)”." + typeNote,
                                  guessed: false, known: true)
        }
        if let guess = guess(name) {
            let text = guess.text.prefix(1).uppercased() + guess.text.dropFirst()
            return IniSettingInfo(title: guess.title, text: "A guess from its name: " + text + typeNote, guessed: true, known: true)
        }
        return IniSettingInfo(title: nil, text: "No notes for this setting yet. Its name reads as “\(readable)”." + typeNote,
                              guessed: false, known: false)
    }

    /// Unreal's array lines start with + - . or !; the setting is the rest.
    static func plainKey(_ key: String) -> String {
        var name = key.trimmingCharacters(in: .whitespaces)
        while let first = name.first, "+-.!".contains(first), name.count > 1 { name.removeFirst() }
        return name
    }

    /// "r.Streaming.MaxTempMemoryAllowed" -> "Streaming › Max Temp Memory Allowed";
    /// "iSize W" -> "Size W"; "bUseThreadedAI" -> "Use Threaded AI".
    static func readableName(_ key: String) -> String {
        var name = plainKey(key)
        // Bethesda's type letter (bName, iName, fName...).
        let chars = Array(name)
        if chars.count > 2, "bifusS".contains(chars[0]), chars[1].isUppercase { name.removeFirst() }
        var parts = name.split(whereSeparator: { $0 == "." || $0 == "/" }).map(String.init)
        if parts.count > 1, let first = parts.first, first.count <= 2 { parts.removeFirst() }
        return parts.map { words($0).joined(separator: " ") }.joined(separator: " › ")
    }

    /// "MaxTempMemoryAllowed" -> ["Max", "Temp", "Memory", "Allowed"]; "LODBias" -> ["LOD", "Bias"].
    static func words(_ part: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(part)
        for (i, c) in chars.enumerated() {
            if c == "_" || c == " " || c == "-" {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            if let last = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = last.isLowercase && c.isUppercase
                let acronymEnd = last.isUppercase && c.isUppercase && (next?.isLowercase ?? false)
                let letterDigit = last.isLetter != c.isLetter && (last.isNumber || c.isNumber)
                if lowerToUpper || acronymEnd || letterDigit { out.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The key with places a long name may wrap: after dots and underscores,
    /// so "r.Streaming.MaxTempMemoryAllowed" never has to end in "…".
    static func breakable(_ key: String) -> String {
        var out = ""
        for c in key {
            out.append(c)
            if c == "." || c == "_" { out.append("\u{200B}") }
        }
        return out
    }

    /// The Bethesda naming habit (one letter for the type, then the name), or a
    /// value that is plainly a switch. Added after a description, never alone.
    static func kind(_ key: String, value: String? = nil) -> String? {
        let chars = Array(key)
        if chars.count > 1, chars[1].isUppercase {
            switch chars[0] {
            case "b": return "Its value is a switch: 1 is on, 0 is off."
            case "i": return "Its value is a whole number."
            case "u": return "Its value is a whole number, 0 or more."
            case "f": return "Its value can have a decimal point."
            default: break
            }
        }
        if let value = value?.lowercased(), value == "true" || value == "false" {
            return "Its value is a switch: True is on, False is off."
        }
        return nil
    }

    /// Known settings whose name starts with `prefix` (any case), for "Add setting".
    static func suggestions(_ prefix: String, limit: Int = 30) -> [Entry] {
        let typed = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        let starts = entries.filter { $0.name.lowercased().hasPrefix(typed) }
        let inside = entries.filter { !$0.name.lowercased().hasPrefix(typed) &&
            ($0.name.lowercased().contains(typed) || $0.title.lowercased().contains(typed)) }
        return Array((starts + inside).prefix(limit))
    }

    // MARK: Groups and words

    private static func group(_ key: String) -> String? {
        let lower = key.lowercased()
        for (prefix, text) in groups where lower.hasPrefix(prefix) { return text }
        return nil
    }

    /// Longest first where one prefix starts another (r.shadow.virtual. before r.shadow.).
    static let groups: [(String, String)] = [
        ("r.lumen.", "Part of Unreal 5's Lumen lighting (bounced light and reflections), which costs a lot of speed."),
        ("r.nanite.", "Part of Unreal 5's Nanite, which draws very detailed models."),
        ("r.shadow.virtual.", "Part of Unreal 5's virtual shadow maps, its most detailed (and slowest) shadows."),
        ("r.shadow.", "Part of how Unreal draws shadows."),
        ("r.streaming.", "Part of texture streaming: how Unreal loads textures into memory as you get near them."),
        ("r.ssr.", "Part of screen space reflections (shiny floors and water)."),
        ("r.ambientocclusion", "Part of ambient occlusion: soft shadows in corners."),
        ("r.volumetricfog", "Part of volumetric fog: fog that light shines through."),
        ("r.volumetriccloud", "Part of Unreal's volumetric clouds."),
        ("r.raytracing", "Part of ray tracing, which needs a graphics card made for it and costs a lot of speed."),
        ("r.dynamicres.", "Part of dynamic resolution: lowering the resolution when frames run slow."),
        ("r.shaderpipelinecache.", "Part of the shader cache, which prepares shaders ahead of time to cut stutter."),
        ("r.psoprecache", "Part of preparing shaders ahead of time to cut stutter."),
        ("r.tsr.", "Part of TSR, Unreal 5's own upscaler and anti-aliasing."),
        ("r.temporalaa", "Part of temporal anti-aliasing (TAA), which smooths edges over several frames."),
        ("r.taa", "Part of temporal anti-aliasing (TAA), which smooths edges over several frames."),
        ("r.translucency", "Part of how see-through things (glass, smoke, water) are drawn."),
        ("r.water.", "Part of how Unreal draws water."),
        ("r.landscape.", "Part of how Unreal draws the ground (landscape)."),
        ("r.hlod", "Part of HLOD: simple merged models used for things far away."),
        ("r.skylight", "Part of the sky light, the soft light from the sky."),
        ("r.skyatmosphere", "Part of how Unreal draws the sky."),
        ("r.dof.", "Part of depth of field (background blur)."),
        ("r.bloom", "Part of bloom, the glow around bright lights."),
        ("r.motionblur", "Part of motion blur."),
        ("r.tonemapper", "Part of the tonemapper, the last step that sets the picture's colors and contrast."),
        ("r.postprocess", "Part of post processing, the effects added after the scene is drawn."),
        ("r.fidelityfx", "Part of AMD FidelityFX (FSR), an upscaler."),
        ("r.ngx.", "Part of NVIDIA DLSS, which needs an NVIDIA RTX card."),
        ("r.xess", "Part of Intel XeSS, an upscaler."),
        ("r.vt.", "Part of virtual textures, which load parts of very large textures."),
        ("r.d3d12.", "A DirectX 12 setting."),
        ("r.d3d11.", "A DirectX 11 setting."),
        ("r.vulkan.", "A Vulkan setting."),
        ("r.mobile.", "A setting for Unreal's phone renderer; Windows games usually ignore it."),
        ("r.gpuskin", "Part of how characters' models bend as they move."),
        ("r.", "An Unreal Engine graphics setting."),
        ("sg.", "One of the game's quality groups: 0 low, 1 medium, 2 high, 3 epic, 4 cinematic. Lower is faster."),
        ("foliage.", "An Unreal setting for trees and plants."),
        ("grass.", "An Unreal setting for grass."),
        ("fx.", "An Unreal setting for effects such as sparks, smoke and fire."),
        ("niagara.", "An Unreal setting for effects such as sparks, smoke and fire."),
        ("a.", "An Unreal setting for animation."),
        ("p.", "An Unreal setting for physics."),
        ("au.", "An Unreal setting for sound."),
        ("s.", "An Unreal setting for loading levels and files."),
        ("gc.", "An Unreal setting for garbage collection: freeing memory the game no longer uses."),
        ("t.", "An Unreal setting for timing and frame rate."),
        ("net.", "An Unreal setting for online play."),
        ("tick.", "An Unreal setting for how often things update."),
        ("sys_spec_", "One of CryEngine's quality groups: 1 low, 2 medium, 3 high, 4 very high. Lower is faster."),
        ("sys_", "A CryEngine or engine system setting."),
        ("r_", "A graphics setting (Source, CryEngine or id Tech)."),
        ("e_", "A CryEngine setting for how the world is drawn."),
        ("mat_", "A Source graphics setting."),
        ("cl_", "A setting for your side of the game: view, screen and online play."),
        ("cg_", "An id Tech setting for the view and on-screen display."),
        ("com_", "An id Tech engine setting."),
        ("snd_", "A sound setting."),
        ("s_", "A sound setting."),
        ("m_", "A mouse setting."),
        ("in_", "An input setting (mouse, keyboard or controller)."),
        ("joy_", "A controller setting."),
        ("net_", "An online play setting."),
        ("sv_", "A server setting; it matters when you host a game."),
        ("mp_", "A multiplayer rule; it matters when you host a game."),
        ("g_", "A game rule."),
        ("hud_", "A setting for the on-screen display."),
        ("ui_", "An interface setting."),
        ("vid_", "A screen setting."),
        ("gl_", "An OpenGL graphics setting."),
        ("gmod_", "A Garry's Mod setting."),
        ("window/", "A Godot window setting."),
        ("renderer/", "A Godot graphics setting."),
        ("rendering_device/", "A Godot graphics setting."),
        ("anti_aliasing/", "A Godot anti-aliasing setting."),
        ("scaling_3d/", "A Godot render scale setting."),
        ("textures/", "A Godot texture setting."),
        ("lights_and_shadows/", "A Godot lighting and shadow setting."),
        ("environment/", "A Godot setting for sky, fog and lighting effects."),
        ("run/", "A Godot setting for how the game runs."),
        ("gfx-", "A Unity graphics setting read at start."),
        ("gc-", "A Unity setting for freeing memory the game no longer uses."),
        ("job-", "A Unity setting for its worker threads."),
        ("texturegroup_", "Texture group: the smallest and largest size (MinLODSize, MaxLODSize) and LODBias for one kind of texture. A lower MaxLODSize or a higher LODBias saves memory and looks blurrier."),
    ]

    /// Words most games use the same way. A word of 5 letters or fewer must be a
    /// whole word of the name; a longer one may be inside it ("MaxFPS", "bUseVSync").
    static let guesses: [(words: [String], title: String, text: String)] = [
        (["vsync", "verticalsync", "waitforvblank", "waitforvsync", "presentinterval"], "V-sync",
         "V-sync. On (1 or True) waits for the screen and stops tearing; off does not."),
        (["borderless"], "Borderless window", "A window without edges that fills the screen."),
        (["fullscreen", "full screen"], "Full screen", "Full screen (1 or True) or a window (0 or False)."),
        (["windowed", "windowmode"], "Window", "Runs the game in a window when on."),
        (["resolutionx", "resx", "screenwidth", "windowwidth", "sizex", "width"], "Width (pixels)",
         "the game's width in pixels. Madeira's display size is set per game in Display; keep them the same."),
        (["resolutiony", "resy", "screenheight", "windowheight", "sizey", "height"], "Height (pixels)",
         "the game's height in pixels. Madeira's display size is set per game in Display; keep them the same."),
        (["resolution"], "Resolution", "the size the game draws at, often written like 1280x720. Lower is faster."),
        (["renderscale", "screenpercentage", "resolutionscale", "resscale"], "Render scale",
         "the size the game draws at compared with the screen. Lower is faster and blurrier."),
        (["maxfps", "fpslimit", "fpscap", "framelimit", "frameratelimit", "targetfps", "framerate", "fps"], "Frame rate cap",
         "the highest frame rate. 0 often means no cap; 30 saves battery and heat."),
        (["refreshrate"], "Refresh rate", "how many times a second the screen updates (Hz)."),
        (["msaa", "multisample", "multisampling"], "Anti-aliasing (MSAA)",
         "smooths jagged edges. 0 or 1 is off and fastest; 2, 4 or 8 cost a lot of speed."),
        (["antialias", "fxaa", "smaa", "taa"], "Anti-aliasing", "smooths jagged edges. Off is faster."),
        (["anisotropy", "anisotropic", "aniso"], "Texture sharpness at an angle",
         "anisotropic filtering, usually 0 to 16. Higher looks sharper on floors and roads; lower is a little faster."),
        (["shadowdistance", "shadowrange", "shadowdist"], "Shadow distance", "how far away shadows are drawn. Lower is faster."),
        (["shadowresolution", "shadowmapsize", "shadowmapresolution", "shadowsize", "shadowres"], "Shadow detail",
         "the size of shadow textures. Lower (512 or 1024) is faster and blurrier."),
        (["shadow", "shadows"], "Shadows", "a shadow setting. Lower or off is usually faster."),
        (["texturequality", "texturedetail", "textureresolution", "texturesize", "texturefilter"], "Texture quality",
         "how detailed textures are. Lower saves memory and speed but looks blurrier."),
        (["motionblur"], "Motion blur", "blur when moving fast. Off is faster and sharper."),
        (["depthoffield", "dof"], "Depth of field", "blurs the background. Off is faster and sharper."),
        (["bloom"], "Bloom", "the glow around bright lights. Off is faster."),
        (["ambientocclusion", "ssao", "hbao", "gtao"], "Ambient occlusion", "soft shadows in corners. Off is faster."),
        (["reflection", "reflections", "ssr"], "Reflections", "reflections on water and shiny floors. Lower or off is faster."),
        (["volumetric", "godrays", "lightshaft", "lightshafts"], "Light rays and fog", "rays of light and fog that light shines through. Off is faster."),
        (["viewdistance", "drawdistance", "renderdistance", "farclip", "lodfactor"], "View distance",
         "how far away things are drawn. Lower is faster."),
        (["lodbias", "lod"], "Detail level", "how detailed models are, often by distance. Simpler (a higher LOD bias) is faster."),
        (["grass", "foliage", "vegetation", "plants", "trees"], "Plants", "how many plants are drawn. Lower is faster."),
        (["particle", "particles", "effects", "vfx"], "Effects", "smoke, sparks and similar effects. Lower is faster."),
        (["tessellation"], "Tessellation", "extra detail added to surfaces. Off is faster."),
        (["raytracing", "rtx"], "Ray tracing", "very costly lighting that needs a graphics card made for it. Off is faster."),
        (["dlss", "fsr", "xess", "upscal", "upscaling", "upscaler"], "Upscaling",
         "draws at a lower size and scales the picture up. Faster, a little softer."),
        (["sharpen", "sharpness", "sharpening"], "Sharpening", "sharpens the picture."),
        (["gamma", "brightness"], "Brightness", "how bright the picture is."),
        (["contrast"], "Contrast", "the difference between dark and bright parts."),
        (["hdr"], "HDR", "high dynamic range output. Off is the safe choice."),
        (["fieldofview", "fov"], "Field of view", "how wide the camera sees, usually in degrees."),
        (["sensitivity"], "Sensitivity", "how fast the camera turns with the mouse or stick."),
        (["invert"], "Invert", "flips a direction, usually looking up and down."),
        (["subtitle", "subtitles"], "Subtitles", "shows the words that are spoken."),
        (["language", "lang", "locale", "culture"], "Language", "the language of the game's text or voices."),
        (["volume"], "Volume", "how loud this sound is."),
        (["mute"], "Mute", "silences this sound when on."),
        (["monitor", "adapter", "displayindex", "gpuindex"], "Screen or graphics card",
         "which screen or graphics card the game uses. 0 is usually the first one."),
        (["uiscale", "hudscale", "interfacescale", "textscale", "fontscale"], "Interface size", "the size of menus and text on screen."),
        (["skipintro", "skipintros", "intro", "logos", "splash"], "Intro videos", "the logos and videos at start; skipping them starts faster."),
        (["difficulty"], "Difficulty", "how hard the game is."),
        (["quality", "detail"], "Quality", "one of the game's quality settings. Lower is usually faster."),
        (["texture", "textures"], "Textures", "a texture setting. Lower saves memory."),
        (["thread", "threads", "threaded", "worker", "workers", "cores"], "Threads",
         "how the game uses the processor's cores."),
        (["memory", "pool", "poolsize", "cache", "budget"], "Memory",
         "a memory size. Lower can save memory on iPhone and iPad but can cause stutter or blurry textures."),
        (["controller", "gamepad", "joystick", "joypad", "xinput"], "Controller", "a controller setting."),
        (["mouse"], "Mouse", "a mouse setting."),
        (["sound", "audio", "music"], "Sound", "a sound setting."),
        (["debug", "log", "logging", "verbose", "trace"], "Developer setting", "for the game's developers; usually best left as it is."),
        (["path", "dir", "directory", "folder", "file"], "Location", "a file or folder location. Leave it unless you know where it should point."),
        (["autosave", "save", "saves"], "Saving", "how or where the game saves."),
        (["telemetry", "analytics", "crashreport"], "Data sent to the developer", "sends usage or crash data. Off is fine."),
    ]

    private static func guess(_ key: String) -> (title: String, text: String)? {
        let parts = readableName(key).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let whole = parts.joined()
        // Every run of neighbouring words, so "Full Screen" and "Shadow Map Size" are found too.
        var runs = Set(parts)
        for i in parts.indices { var run = parts[i]; for j in parts.indices where j > i { run += parts[j]; runs.insert(run) } }
        for rule in guesses {
            for word in rule.words.map({ $0.replacingOccurrences(of: " ", with: "") }) {
                if word.count <= 5 ? runs.contains(word) : whole.contains(word) { return (rule.title, rule.text) }
            }
        }
        return nil
    }

    // MARK: The list

    /// Every entry, in the list's order.
    static let entries: [Entry] = table.split(separator: "\n").compactMap { (line: Substring) -> Entry? in
        let fields = line.components(separatedBy: " | ")
        guard fields.count == 3, !line.hasPrefix("#") else { return nil }
        return Entry(key: fields[0].trimmingCharacters(in: .whitespaces), title: fields[1], text: fields[2])
    }

    /// By lower-case key; the first entry wins when two engines share a name.
    static let known: [String: Entry] = {
        var all: [String: Entry] = [:]
        for entry in entries where all[entry.key.lowercased()] == nil { all[entry.key.lowercased()] = entry }
        return all
    }()

    /// key | title | text. A key "[Section]Name" applies only in that section.
    /// Lines starting with # are notes.
    static let table = """
    # Unreal Engine 4 and 5: Engine.ini [SystemSettings] or [ConsoleVariables]
    r.Streaming.PoolSize | Texture memory (MB) | How much memory, in MB, textures may use. Lower saves memory on iPhone and iPad, but textures can look blurry or load late. 400 to 1000 is a good range.
    r.Streaming.LimitPoolSizeToVRAM | Keep texture memory under graphics memory | 1 stops texture memory from going over the graphics memory the game thinks it has. 1 is safer for memory.
    r.Streaming.MaxTempMemoryAllowed | Texture loading memory (MB) | Extra memory, in MB, used while textures load. Lower saves a little memory.
    r.Streaming.UseFixedPoolSize | Fixed texture memory | 1 keeps texture memory at exactly r.Streaming.PoolSize instead of letting the game change it.
    r.Streaming.FullyLoadUsedTextures | Load textures in full | 1 loads every texture in view at full quality straight away. Sharper sooner, but uses more memory.
    r.Streaming.MipBias | Texture quality drop | Makes streamed textures less detailed: 0 is normal, 1 is half size, 2 a quarter. Higher saves memory.
    r.Streaming.FramesForFullUpdate | Texture update speed | How many frames texture loading is spread over. Lower loads sharp textures sooner but costs more each frame.
    r.TextureStreaming | Texture streaming | 1 loads textures as they are needed (normal). 0 loads everything at full size and uses far more memory.
    r.MipMapLODBias | Texture quality drop | Makes all textures less detailed. 0 is normal; 1 or 2 saves memory and looks blurrier.
    r.Nanite.Streaming.StreamingPoolSize | Nanite memory (MB) | Memory, in MB, for Unreal 5's Nanite models. Lower saves memory; too low makes models look blocky.
    r.ScreenPercentage | Render scale (%) | The size the game draws at, as a percentage of the screen. 100 is full; 50 to 70 is much faster but blurrier.
    r.ViewDistanceScale | View distance | How far away things are drawn. 1 is normal; lower, like 0.5, is faster.
    r.MaxAnisotropy | Texture sharpness at an angle | Anisotropic filtering, 0 to 16. Higher looks sharper on floors and roads; lower is a little faster.
    r.SkeletalMeshLODBias | Character detail drop | Uses simpler models for characters and creatures. 0 is normal; 1 or 2 is faster.
    r.StaticMeshLODDistanceScale | Object detail distance | Higher switches objects to simpler models sooner. 1 is normal; 2 is faster.
    r.ForceLOD | Force detail level | -1 is normal. 0 or more forces every model to that detail level; higher numbers are simpler and faster.
    r.DetailMode | Detail level | 0 low, 1 medium, 2 high (3 epic in newer games). Lower skips small decorations.
    r.MaterialQualityLevel | Material quality | 0 low, 1 high, 2 medium, 3 epic. 0 is fastest.
    r.Lumen.DiffuseIndirect.Allow | Lumen lighting | Unreal 5's bounced light (Lumen). 0 turns it off: much faster, but rooms and caves look flatter.
    r.Lumen.Reflections.Allow | Lumen reflections | Unreal 5's Lumen reflections. 0 turns them off and is faster.
    r.Lumen.HardwareRayTracing | Lumen ray tracing | 0 makes Lumen use its cheaper software mode.
    r.DynamicGlobalIlluminationMethod | Bounced light method | 0 none, 1 Lumen, 2 screen space only. 0 or 2 is much faster than Lumen.
    r.ReflectionMethod | Reflection method | 0 none, 1 Lumen, 2 screen space. 0 or 2 is faster than Lumen.
    r.SSGI.Enable | Screen space bounced light | 1 adds cheap bounced light. 0 is off and faster.
    r.Shadow.Virtual.Enable | Virtual shadow maps | Unreal 5's most detailed shadows. 0 switches to simpler shadows, which is much faster.
    r.Shadow.Virtual.ResolutionLodBiasDirectional | Sun shadow detail drop | Higher makes the sun's virtual shadows blurrier and faster.
    r.Nanite.MaxPixelsPerEdge | Nanite detail | Unreal 5's Nanite models: a higher number draws fewer triangles. 1 is normal; 2 to 4 is faster and a little blockier.
    r.Nanite | Nanite | 0 turns Unreal 5's Nanite models off where the game allows it. Some games then show missing or simple objects.
    r.ShadowQuality | Shadow quality | 0 turns shadows off; 5 is highest. Lower is faster.
    r.Shadow.MaxResolution | Shadow detail | The largest shadow texture, in pixels. 512 or 1024 is faster and blurrier.
    r.Shadow.DistanceScale | Shadow distance | How far away shadows are drawn. 1 is normal; lower is faster.
    r.Shadow.CSM.MaxCascades | Sun shadow layers | How many layers the sun's shadows use. Fewer (1 or 2) is faster.
    r.Shadow.RadiusThreshold | Small shadow cut-off | Skips shadows from small or far objects. Higher skips more and is faster.
    r.ContactShadows | Contact shadows | Small shadows where things touch. 0 is off and faster.
    r.CapsuleShadows | Capsule shadows | Soft shadows under characters. 0 is off and faster.
    r.DistanceFieldShadowing | Distance field shadows | Soft shadows far away. 0 is off and faster.
    r.DistanceFieldAO | Distance field ambient occlusion | Soft large-scale shading. 0 is off and faster.
    r.AmbientOcclusionLevels | Ambient occlusion | Soft shadows in corners. 0 is off and faster; -1 lets the game decide.
    r.SSR.Quality | Screen reflections | Reflections on shiny floors and water. 0 is off and faster; 4 is highest.
    r.VolumetricFog | Volumetric fog | Fog that light shines through. 0 is off and faster.
    r.Fog | Fog | 0 turns fog off.
    r.LightShaftQuality | Light shafts | Rays of sunlight through gaps. 0 is off.
    r.RefractionQuality | Refraction | Heat haze and the bending of light through glass. 0 is off and faster.
    r.EyeAdaptationQuality | Auto exposure | How the picture adjusts between dark and bright places. 0 is off.
    r.PostProcessAAQuality | Anti-aliasing quality | Smooths jagged edges, 0 off to 6 highest. Lower is faster.
    r.AntiAliasingMethod | Anti-aliasing method | 0 none, 1 FXAA, 2 TAA, 3 MSAA, 4 TSR (Unreal 5). 0 or 1 is fastest.
    r.MotionBlurQuality | Motion blur | 0 turns motion blur off; higher blurs more. 0 is faster and sharper.
    r.DepthOfFieldQuality | Depth of field | Background blur. 0 is off and faster.
    r.BloomQuality | Bloom | The glow around bright lights. 0 is off and faster; 5 is highest.
    r.LensFlareQuality | Lens flares | 0 turns lens flares off.
    r.SceneColorFringeQuality | Color fringing | The rainbow edges effect (chromatic aberration). 0 turns it off.
    r.Tonemapper.Sharpen | Sharpening | Sharpens the picture. 0 is off; 0.5 to 1 is a light sharpen.
    r.Upscale.Quality | Upscaling quality | How the picture is stretched back up when the render scale is under 100. Lower is a little faster.
    r.TranslucencyLightingVolumeDim | Glass and smoke lighting detail | Lower (like 32) is faster; 64 is normal.
    r.RayTracing | Ray tracing | Needs a graphics card made for it. 0 turns it off and is much faster.
    r.DynamicRes.OperationMode | Dynamic resolution | 0 off. 1 or 2 lets the game lower its resolution when frames run slow.
    r.VSync | V-sync | 1 waits for the screen and stops tearing; 0 does not.
    r.FullScreenMode | Screen mode | 0 full screen, 1 borderless window, 2 window.
    r.SetRes | Screen size | Size and mode, like 1280x720f (f full screen, wf borderless, w window).
    r.GraphicsAdapter | Graphics card | Which graphics card the game uses. -1 picks it by itself.
    r.OneFrameThreadLag | Frame overlap | 1 lets the game prepare the next frame while this one is drawn. Usually faster; 0 can lower input lag.
    r.FinishCurrentFrame | Wait for each frame | 1 waits for each frame to finish. Lowers input lag but is slower.
    r.ShaderPipelineCache.Enabled | Shader cache | 1 prepares shaders from a saved list ahead of time, which can cut stutter.
    r.DefaultFeature.MotionBlur | Motion blur by default | 0 turns motion blur off unless the game turns it on.
    r.DefaultFeature.Bloom | Bloom by default | 0 turns bloom off unless the game turns it on.
    r.DefaultFeature.AutoExposure | Auto exposure by default | 0 turns automatic brightness changes off unless the game turns them on.
    r.DefaultFeature.AmbientOcclusion | Ambient occlusion by default | 0 turns soft corner shadows off unless the game turns them on.
    r.DefaultFeature.LensFlare | Lens flares by default | 0 turns lens flares off unless the game turns them on.
    r.DefaultFeature.AntiAliasing | Anti-aliasing by default | 0 none, 1 FXAA, 2 TAA, 3 MSAA (4 TSR in Unreal 5).
    foliage.DensityScale | Plant density | How many trees and plants are drawn, from 0 to 1. Lower is faster.
    foliage.LODDistanceScale | Plant detail distance | How far away plants keep their detail. Lower is faster.
    grass.DensityScale | Grass density | How much grass is drawn, from 0 to 1. Lower is faster.
    grass.Enable | Grass | 0 turns grass off.
    t.MaxFPS | Frame rate cap | The highest frame rate. 0 is no cap; 30 saves battery and heat.
    sg.ResolutionQuality | Render scale (%) | The size the game draws at, as a percentage of the screen. 100 is full; lower is faster and blurrier.
    sg.ViewDistanceQuality | View distance quality | 0 low to 3 epic (4 cinematic). Lower draws less far away and is faster.
    sg.AntiAliasingQuality | Anti-aliasing quality | 0 low to 3 epic (4 cinematic). Lower is faster with more jagged edges.
    sg.ShadowQuality | Shadow quality | 0 low to 3 epic (4 cinematic). Lower is faster.
    sg.GlobalIlluminationQuality | Lighting quality | 0 low to 3 epic (4 cinematic). In Unreal 5, 0 or 1 turns Lumen off and is much faster.
    sg.ReflectionQuality | Reflection quality | 0 low to 3 epic (4 cinematic). Lower is faster.
    sg.PostProcessQuality | Effects after drawing | Blur, bloom and similar, 0 low to 3 epic (4 cinematic). Lower is faster.
    sg.TextureQuality | Texture quality | 0 low to 3 epic (4 cinematic). Lower saves memory.
    sg.EffectsQuality | Effects quality | Smoke, fire and sparks, 0 low to 3 epic (4 cinematic). Lower is faster.
    sg.FoliageQuality | Plant quality | 0 low to 3 epic (4 cinematic). Lower is faster.
    sg.ShadingQuality | Shading quality | How detailed surfaces look, 0 low to 3 epic (4 cinematic). Lower is faster.
    # Unreal Engine 4 and 5: GameUserSettings.ini [/Script/Engine.GameUserSettings]
    bUseVSync | V-sync | True waits for the screen and stops tearing; False does not.
    bUseDynamicResolution | Dynamic resolution | True lets the game lower its resolution when frames run slow.
    ResolutionSizeX | Width (pixels) | The game's width in pixels. Madeira's display size is set per game in Display; keep them the same.
    ResolutionSizeY | Height (pixels) | The game's height in pixels. Madeira's display size is set per game in Display; keep them the same.
    LastUserConfirmedResolutionSizeX | Last kept width | The width you last kept in the game's menu. Keep it the same as ResolutionSizeX.
    LastUserConfirmedResolutionSizeY | Last kept height | The height you last kept in the game's menu. Keep it the same as ResolutionSizeY.
    DesiredScreenWidth | Wanted width | The width the game asks for.
    DesiredScreenHeight | Wanted height | The height the game asks for.
    LastUserConfirmedDesiredScreenWidth | Last kept wanted width | The wanted width you last kept in the game's menu.
    LastUserConfirmedDesiredScreenHeight | Last kept wanted height | The wanted height you last kept in the game's menu.
    FullscreenMode | Screen mode | 0 full screen, 1 borderless window, 2 window.
    LastConfirmedFullscreenMode | Last kept screen mode | 0 full screen, 1 borderless window, 2 window.
    PreferredFullscreenMode | Preferred screen mode | 0 full screen, 1 borderless window, 2 window.
    FrameRateLimit | Frame rate cap | The highest frame rate. 0 is no cap; 30 saves battery and heat.
    AudioQualityLevel | Sound quality | 0 is lowest. Lower uses a little less processor.
    WindowPosX | Window position (across) | Where the window opens. -1 centers it.
    WindowPosY | Window position (down) | Where the window opens. -1 centers it.
    bUseHDRDisplayOutput | HDR | True turns HDR on. False is the safe choice.
    HDRDisplayOutputNits | HDR brightness | Peak brightness for HDR, in nits.
    LastCPUBenchmarkResult | Processor test score | A score from the game's own speed test, used to pick settings. -1 means it has not run.
    LastGPUBenchmarkResult | Graphics test score | A score from the game's own speed test, used to pick settings. -1 means it has not run.
    LastRecommendedScreenWidth | Recommended width | The width the game's speed test suggested.
    LastRecommendedScreenHeight | Recommended height | The height the game's speed test suggested.
    [/Script/Engine.GameUserSettings]Version | File version | The settings file's format number. Leave it as it is.
    # Unreal Engine: [/Script/Engine.Engine]
    bSmoothFrameRate | Smooth frame rate | True keeps the frame rate between MinSmoothedFrameRate and MaxSmoothedFrameRate.
    MinSmoothedFrameRate | Lowest smoothed frame rate | Used when bSmoothFrameRate is True.
    MaxSmoothedFrameRate | Frame rate cap | The highest frame rate when bSmoothFrameRate is True. Old Unreal games often cap at 62.
    bUseFixedFrameRate | Fixed frame rate | True runs the game at exactly FixedFrameRate.
    FixedFrameRate | Fixed frame rate | The frame rate used when bUseFixedFrameRate is True.
    # Unreal Engine 3: [SystemSettings] (Borderlands 2, Batman: Arkham, BioShock, Mass Effect, XCOM)
    ResX | Width (pixels) | The game's width in pixels. Madeira's display size is set per game in Display; keep them the same.
    ResY | Height (pixels) | The game's height in pixels. Madeira's display size is set per game in Display; keep them the same.
    Fullscreen | Full screen | True is full screen, False is a window.
    UseVsync | V-sync | True waits for the screen and stops tearing; False does not.
    MaxAnisotropy | Texture sharpness at an angle | Anisotropic filtering, 0 to 16. Higher looks sharper; lower is a little faster.
    MaxMultiSamples | Anti-aliasing (MSAA) | 1 is off; 2, 4 or 8 smooth edges and cost a lot of speed.
    ScreenPercentage | Render scale (%) | The size the game draws at. 100 is full; lower is faster and blurrier.
    UpscaleScreenPercentage | Stretch to the screen | True stretches a lower render scale back to the full screen.
    DynamicShadows | Moving shadows | Shadows from things that move. False is faster.
    LightEnvironmentShadows | Character shadows | False is faster.
    DynamicLights | Moving lights | Lights that move or flicker. False is faster.
    CompositeDynamicLights | Merge small lights | True merges small lights into one, which is faster.
    MotionBlur | Motion blur | False is faster and sharper.
    DepthOfField | Depth of field | Background blur. False is faster.
    AmbientOcclusion | Ambient occlusion | Soft shadows in corners. False is much faster.
    Bloom | Bloom | The glow around bright lights. False is faster.
    UseHighQualityBloom | High quality bloom | False is faster.
    Distortion | Distortion | Heat haze and similar effects. False is faster.
    LensFlares | Lens flares | False turns lens flares off.
    FogVolumes | Fog | False turns fog volumes off and is faster.
    bAllowLightShafts | Light shafts | Rays of sunlight through gaps. False is faster.
    SpeedTreeLeaves | Tree leaves | False draws trees without leaves; faster.
    SpeedTreeFronds | Tree fronds | False draws trees without fronds; faster.
    StaticDecals | Fixed decals | Marks painted on the world. False is faster.
    DynamicDecals | Moving decals | Marks like bullet holes and blood. False is faster.
    DecalCullDistanceScale | Decal distance | How far away marks are drawn. Lower is faster.
    DetailMode | Detail level | 0 low, 1 medium, 2 high. Lower skips small decorations.
    SkeletalMeshLODBias | Character detail drop | Uses simpler character models. 0 is normal; higher is faster.
    ParticleLODBias | Effect detail drop | Uses simpler smoke, fire and sparks. 0 is normal; higher is faster.
    ShadowFilterQualityBias | Shadow softness | Lower is faster with harder shadow edges.
    MinShadowResolution | Smallest shadow detail | The smallest shadow texture, in pixels.
    MaxShadowResolution | Largest shadow detail | The largest shadow texture, in pixels. Lower is faster and blurrier.
    AllowD3D11 | DirectX 11 | True lets the game use DirectX 11 effects. False keeps DirectX 9, which can be faster.
    bAllowD3D9MSAA | Anti-aliasing in DirectX 9 | False is faster.
    OneFrameThreadLag | Frame overlap | True lets the game prepare the next frame while this one is drawn. Usually faster.
    [TextureStreaming]PoolSize | Texture memory (MB) | How much memory, in MB, textures may use. Lower saves memory.
    # Bethesda (Gamebryo and Creation): Fallout 3, New Vegas, Fallout 4, Oblivion, Skyrim
    iSize W | Width (pixels) | The game's width in pixels. Madeira's display size is set per game in Display; keep them the same.
    iSize H | Height (pixels) | The game's height in pixels. Madeira's display size is set per game in Display; keep them the same.
    bFull Screen | Full screen | Full screen (1) or a window (0).
    bBorderless | Borderless window | 1 shows a window without edges that fills the screen.
    iMultiSample | Anti-aliasing | Smooths jagged edges. 0 is off and fastest; 2, 4 or 8 look smoother but cost a lot of speed.
    iMaxAnisotropy | Texture sharpness at an angle | Anisotropic filtering, from 0 to 16. Higher looks sharper and costs a little speed.
    iPresentInterval | V-sync | 1 waits for the screen and stops tearing, 0 does not.
    iVSyncPresentInterval | V-sync | 1 waits for the screen and stops tearing, 0 does not. Skyrim and Fallout 4 physics can go wrong over 60 frames a second.
    bFXAAEnabled | FXAA anti-aliasing | Cheap edge smoothing. 1 is on.
    iTexMipMapSkip | Texture quality | 0 is full, 1 is half size, 2 is a quarter. Higher saves memory and speed.
    iShadowMapResolution | Shadow detail | The size of shadow textures. Lower (512 or 1024) is faster and blurrier.
    fShadowDistance | Shadow distance | How far away shadows are drawn. Lower is faster.
    iActorShadowCountExt | Outdoor character shadows | How many characters cast shadows outdoors. Lower is faster.
    iActorShadowCountInt | Indoor character shadows | How many characters cast shadows indoors. Lower is faster.
    bShadowsOnGrass | Grass shadows | Grass gets shadows. Off is faster.
    bDoDepthOfField | Depth of field | Blurs the background. Off is faster and sharper.
    bSAOEnable | Ambient occlusion | Soft shadows in corners. Off is faster.
    bVolumetricLightingEnable | Light rays | Rays of light through fog and trees. Off is faster.
    bUseWaterReflections | Water reflections | Water reflects the world. Off is faster.
    fLODFadeOutMultObjects | Object distance | How far away objects stay visible. Lower is faster.
    fLODFadeOutMultItems | Item distance | How far away small items stay visible. Lower is faster.
    fLODFadeOutMultActors | Character distance | How far away characters stay visible. Lower is faster.
    uLargeRefLODGridSize | Large object distance | How many cells away big buildings and rocks show in full detail. Higher is slower.
    fDefaultFOV | Field of view | How wide the camera sees, in degrees.
    fGamma | Brightness | How bright the picture is.
    sD3DDevice | Graphics card name | The graphics card the game last saw. Madeira keeps it in step with the Older NVIDIA card setting; changing it by hand makes the game reopen its launcher.
    fGrassStartFadeDistance | Grass distance | How far away grass is drawn. Lower is faster.
    iMinGrassSize | Grass spacing | Higher means less grass and more speed.
    uGridsToLoad | Full detail area | How many cells (blocks of world) around you load in full detail. 5 is normal; higher is much slower and can crash.
    uGridDistantTreeRange | Distant trees | How many cells away distant trees are drawn.
    uGridDistantCount | Distant landscape | How many cells away the distant landscape and buildings are drawn.
    uInterior Cell Buffer | Indoor areas kept | How many indoor areas stay in memory after you leave them.
    uExterior Cell Buffer | Outdoor areas kept | How many outdoor cells stay in memory after you leave them.
    iPreloadSizeLimit | Preload memory | Memory, in bytes, set aside for loading things ahead of time.
    bPreemptivelyUnloadCells | Free areas early | Frees areas from memory as soon as you leave them. Can lower memory use.
    iNumHWThreads | Processor threads | How many processor threads the game plans for.
    bUseThreadedAI | Threaded AI | Runs characters' AI on its own thread.
    bAlwaysActive | Keep running in the background | 1 keeps the game running when it is not in front.
    iSaveGameBackupCount | Save backups | How many backup copies of a save are kept when you save over it.
    bAllowScriptedAutosave | Quest autosaves | Lets quests save the game automatically.
    bDisplayMissingContentDialogue | Missing content warning | Warns when a save needs a mod or add-on that is missing.
    sSaveGameSafeCellID | Safe spot | Where the game puts you if a save cannot load your spot. Leave it as it is.
    sLanguage | Language | The language the game's text is in.
    sIntroSequence | Intro videos | The videos played at start. Empty skips them.
    bLoadFaceGenHeadEGTFiles | Face colors (New Vegas) | Loads the files that color characters' faces. On fixes faces that do not match their necks; it uses more memory.
    bEnableFileSelection | Allow mods (Fallout 4) | In [Launcher]: 1 lets Fallout 4 load mods from its Data folder.
    bInvalidateOlderFiles | Use loose files | 1 lets loose files in Data replace the game's packed files. Many mods need it.
    sResourceDataDirsFinal | Loose file folders | Empty, with bInvalidateOlderFiles=1, lets loose mod files replace the game's own.
    bUseJoystick | Controller | Controller support: 1 on, 0 off.
    bInvertYValues | Invert looking | Inverts looking up and down.
    fMouseHeadingSensitivity | Mouse sensitivity | How fast the mouse turns the camera.
    # CryEngine: system.cfg / user.cfg (Crysis, Kingdom Come: Deliverance, Prey, Hunt)
    sys_spec | Overall quality | 1 low, 2 medium, 3 high, 4 very high. Lower is faster.
    r_Width | Width (pixels) | The game's width in pixels. Madeira's display size is set per game in Display; keep them the same.
    r_Height | Height (pixels) | The game's height in pixels. Madeira's display size is set per game in Display; keep them the same.
    r_Fullscreen | Full screen | 1 full screen, 0 a window.
    r_VSync | V-sync | 1 waits for the screen and stops tearing; 0 does not.
    sys_MaxFPS | Frame rate cap | The highest frame rate. 30 saves battery and heat.
    r_MotionBlur | Motion blur | 0 turns it off; faster and sharper.
    r_DepthOfField | Depth of field | Background blur. 0 turns it off.
    r_SSAO | Ambient occlusion | Soft shadows in corners. 0 turns it off and is faster.
    r_AntialiasingMode | Anti-aliasing | 0 is off and fastest; other numbers pick the game's smoothing modes.
    r_TexturesStreaming | Texture streaming | 1 loads textures as they are needed, which saves memory.
    r_TexturesStreamPoolSize | Texture memory (MB) | How much memory, in MB, streamed textures may use. Lower saves memory.
    r_MultiThreaded | Render thread | 1 draws on its own thread (normal). 0 can help a game that crashes.
    r_Gamma | Brightness | How bright the picture is. 1 is normal.
    e_ViewDistRatio | View distance | How far away objects are drawn. Lower is faster.
    e_LodRatio | Detail distance | How far away objects keep their detail. Lower is faster.
    e_ShadowsMaxTexRes | Shadow detail | The largest shadow texture, in pixels. Lower is faster and blurrier.
    cl_fov | Field of view | How wide the camera sees, in degrees.
    # Source (Valve): autoexec.cfg / config.cfg (Half-Life 2, Portal, Garry's Mod, Left 4 Dead, TF2)
    fps_max | Frame rate cap | The highest frame rate. 0 is no cap; 30 or 60 saves battery and heat.
    mat_vsync | V-sync | 1 waits for the screen and stops tearing; 0 does not.
    mat_queue_mode | Multicore drawing | -1 lets the game choose, 0 one core, 2 several cores (usually faster).
    mat_picmip | Texture quality drop | 0 or -1 is full detail; 1 or 2 is blurrier and saves memory.
    mat_antialias | Anti-aliasing (MSAA) | 0 or 1 is off; 2, 4 or 8 smooth edges and cost speed.
    mat_forceaniso | Texture sharpness at an angle | Anisotropic filtering, 0 to 16. Higher looks sharper.
    mat_hdr_level | HDR lighting | 0 off, 1 simple, 2 full. Lower is faster.
    mat_motion_blur_enabled | Motion blur | 0 turns it off.
    mat_disable_bloom | Bloom off | 1 turns off the glow around bright lights.
    mat_dxlevel | DirectX level | The DirectX level the game draws with, like 90 or 95. Lower levels drop effects; changing it can reset other graphics settings.
    mat_monitorgamma | Brightness | How bright the picture is. 2.2 is normal.
    cl_showfps | Show frame rate | 1 shows the frame rate on screen.
    net_graph | Connection graph | 1 shows the frame rate and connection details on screen.
    sensitivity | Mouse sensitivity | How fast the mouse turns the camera.
    m_rawinput | Raw mouse input | 1 reads the mouse directly, without Windows' mouse speed.
    viewmodel_fov | Weapon field of view | How wide the view of your own weapon and hands is.
    fov_desired | Field of view | How wide the camera sees, in degrees.
    cl_forcepreload | Preload | 1 loads everything when a map starts: longer loading, fewer hitches.
    cl_threaded_bone_setup | Threaded animation | 1 spreads animation work over more cores.
    r_threaded_particles | Threaded effects | 1 spreads effects work over more cores.
    r_threaded_renderables | Threaded drawing | 1 spreads drawing work over more cores.
    gmod_mcore_test | Multicore (Garry's Mod) | 1 turns on Garry's Mod's multicore mode. Often faster; some addons break with it.
    r_decals | Decals | How many marks (bullet holes, blood) stay on the world. Lower is faster.
    cl_cmdrate | Updates sent | How many updates a second you send to the server.
    cl_updaterate | Updates received | How many updates a second you ask the server for.
    rate | Online speed | The most data a second the game uses online.
    volume | Volume | The main volume, from 0 to 1.
    developer | Developer messages | 1 shows developer messages on screen. 0 is normal.
    # id Tech 3 and 4: q3config.cfg / DoomConfig.cfg (seta lines; Quake 3, Doom 3, Wolfenstein, Call of Duty 1 and 2, Jedi Academy)
    r_mode | Screen size | A number from the game's list of sizes. -1 uses r_customwidth and r_customheight.
    r_customwidth | Width (pixels) | Used when r_mode is -1. Madeira's display size is set per game in Display; keep them the same.
    r_customheight | Height (pixels) | Used when r_mode is -1. Madeira's display size is set per game in Display; keep them the same.
    com_maxfps | Frame rate cap | The highest frame rate. In Quake 3 games movement changes with it; 125 is a common choice.
    r_picmip | Texture quality drop | 0 is full detail; higher is blurrier and faster.
    r_swapInterval | V-sync | 1 waits for the screen and stops tearing; 0 does not.
    cg_fov | Field of view | How wide the camera sees, in degrees.
    cg_drawFPS | Show frame rate | 1 shows the frame rate on screen.
    s_volume | Volume | Sound effects volume, from 0 to 1.
    r_texturemode | Texture filtering | GL_LINEAR_MIPMAP_LINEAR is smooth; GL_NEAREST looks blocky.
    r_ext_texture_filter_anisotropic | Anisotropic filtering | 1 makes textures sharper at an angle.
    r_ext_max_anisotropy | Anisotropic level | 2 to 16. Higher looks sharper.
    r_ext_compressed_textures | Compressed textures | 1 uses less memory for textures.
    r_multiSamples | Anti-aliasing (MSAA) | 0 is off; 2, 4 or 8 smooth edges and cost speed.
    r_vertexLight | Simple lighting | 1 uses cheaper lighting; faster, flatter.
    r_displayRefresh | Refresh rate | How many times a second the screen updates. 0 lets the game pick.
    com_hunkMegs | Game memory (MB) | Memory the game sets aside at start. Too little can stop big maps from loading.
    # Godot: override.cfg next to the game's exe ([section] then name=value)
    [display]window/size/viewport_width | Width (pixels) | The size the game is laid out for.
    [display]window/size/viewport_height | Height (pixels) | The size the game is laid out for.
    [display]window/size/mode | Window mode | 0 window, 2 maximized, 3 full screen, 4 exclusive full screen.
    [display]window/vsync/vsync_mode | V-sync | 0 off, 1 on, 2 adaptive, 3 mailbox.
    [rendering]renderer/rendering_method | Renderer | "forward_plus" (full), "mobile" (lighter) or "gl_compatibility" (OpenGL, lightest). gl_compatibility let Slay the Spire 2 draw in Madeira when the others did not.
    [rendering]rendering_device/driver.windows | Graphics API | "vulkan" or "d3d12", for the forward_plus and mobile renderers.
    [application]run/max_fps | Frame rate cap | The highest frame rate. 0 is no cap.
    [rendering]scaling_3d/scale | Render scale | 1.0 is full size; 0.5 to 0.8 is faster and blurrier.
    [rendering]scaling_3d/mode | Upscaler | 0 bilinear, 1 FSR 1, 2 FSR 2.
    [rendering]anti_aliasing/quality/msaa_3d | Anti-aliasing (MSAA) | 0 off; 1, 2, 3 are 2x, 4x, 8x and cost speed.
    # Unity: boot.config in <Game>_Data
    gfx-enable-gfx-jobs | Graphics jobs | 1 spreads drawing work over more cores. Can be faster; some games crash with it.
    gfx-enable-native-gfx-jobs | Native graphics jobs | 1 spreads more drawing work over more cores. Same trade as graphics jobs.
    gfx-disable-mt-rendering | Single-thread drawing | 1 draws on the main thread only. Slower, but can stop some crashes.
    job-worker-count | Worker threads | How many worker threads Unity uses.
    gc-max-time-slice | Memory cleanup step (ms) | How long each memory cleanup step may take, in milliseconds.
    wait-for-native-debugger | Wait for a debugger | Leave it 0. 1 makes the game wait at start for a developer tool.
    player-connection-debug | Developer connection | Leave it 0.
    hdr-display-enabled | HDR | 0 off. Off is the safe choice.
    vr-enabled | VR | 0 off.
    single-instance | One copy only | Stops a second copy of the game from starting.
    scripting-runtime-version | Script runtime | Which .NET version the game's scripts use. Leave it as it is.
    # Unity: registry options (Settings files › Unity game options); the _h number is left out
    Screenmanager Resolution Width | Width | The game's width in pixels, used at its next start.
    Screenmanager Resolution Height | Height | The game's height in pixels, used at its next start.
    Screenmanager Fullscreen mode | Window mode | 0 is exclusive full screen, 1 a full screen window, 2 a maximized window, 3 a window.
    Screenmanager Is Fullscreen mode | Full screen | 1 is full screen, 0 a window. Older Unity games use this one.
    Screenmanager Resolution Use Native | Use the screen's own size | 1 uses the screen's size and leaves out the width and height here.
    Screenmanager Resolution Window Width | Window width | The width in pixels when the game is in a window.
    Screenmanager Resolution Window Height | Window height | The height in pixels when the game is in a window.
    Screenmanager Window Position X | Window left edge | Where the window starts from the left, in pixels.
    Screenmanager Window Position Y | Window top edge | Where the window starts from the top, in pixels.
    UnityGraphicsQuality | Quality level | Which of the game's quality levels it uses. 0 is the lowest; how many there are depends on the game. Lower is faster.
    UnitySelectMonitor | Monitor | Which monitor the game uses. Leave it as it is.
    unity.player_sessionid | Session number | Unity's own record of the last play session. Leave it as it is.
    unity.player_session_count | Times played | How many times the game started. Unity's own count; changing it does nothing useful.
    unity.cloud_userid | Unity user id | Unity's own id for this copy of the game. Leave it as it is.
    # GTA V: Documents/Rockstar Games/GTA V/settings.xml
    [graphics]Tessellation | Tessellation | Extra detail on surfaces like trees and rocks. 0 is off; higher looks better and is slower.
    [graphics]LodScale | Detail distance | How far away detailed models are kept. Lower is faster.
    [graphics]PedLodBias | People detail distance | How far away people keep their detail. Lower is faster.
    [graphics]VehicleLodBias | Car detail distance | How far away cars keep their detail. Lower is faster.
    [graphics]ShadowQuality | Shadow quality | The lowest is 0 in GTA V and kSettingLevel_Low in RDR2. Higher is sharper and slower.
    [graphics]ReflectionQuality | Reflection quality | 0 is the lowest. Higher looks better and is slower.
    [graphics]ReflectionMSAA | Reflection anti-aliasing | 0 is off. Higher smooths edges in reflections and is slower.
    [graphics]SSAO | Ambient occlusion | Soft shadows where things meet. 0 is off; higher is slower.
    [graphics]AnisotropicFiltering | Texture sharpness at an angle | Higher looks sharper on roads and floors; lower is a little faster.
    [graphics]MSAA | Anti-aliasing (MSAA) | 0 is off. Higher smooths edges and costs a lot of speed.
    [graphics]FXAA | FXAA | 1 is on, 0 off. Cheap edge smoothing.
    [graphics]TXAA | TXAA | 1 is on, 0 off. Needs MSAA on.
    [graphics]TextureQuality | Texture quality | In GTA V 0 is normal, 1 high, 2 very high; in RDR2 it is a level like kSettingLevel_Medium. Lower uses less graphics memory.
    [graphics]ShaderQuality | Shader quality | 0 is the lowest. Higher looks better and is slower.
    [graphics]ParticleQuality | Particle quality | Smoke, fire and sparks. The lowest is 0 in GTA V and kSettingLevel_Low in RDR2; higher is slower.
    [graphics]WaterQuality | Water quality | The lowest is 0 in GTA V and kSettingLevel_Low in RDR2. Higher is slower.
    [graphics]GrassQuality | Grass quality | 0 is the lowest. Grass is one of the slowest settings; keep it low.
    [graphics]PostFX | Post effects | Bloom and similar effects. 0 is the lowest; higher is slower.
    [graphics]DoF | Depth of field | 1 blurs things out of focus, 0 off.
    [graphics]MotionBlurStrength | Motion blur | 0.0 is off, 1.0 the most.
    [graphics]CityDensity | Population density | 0.0 to 1.0. Lower has fewer people and cars, and is faster.
    [graphics]PedVarietyMultiplier | People variety | 0.0 to 1.0. Lower uses fewer kinds of people and less memory.
    [graphics]VehicleVarietyMultiplier | Car variety | 0.0 to 1.0. Lower uses fewer kinds of cars and less memory.
    [graphics]DX_Version | DirectX version | Which DirectX the game uses. Leave it as it is unless the game will not start.
    [video]ScreenWidth | Width | The game's width in pixels.
    [video]ScreenHeight | Height | The game's height in pixels.
    [video]RefreshRate | Refresh rate | The screen's refresh rate the game asks for, like 60.
    [video]Windowed | Window mode | 0 is full screen. In GTA V, 1 is a window and 2 a borderless window.
    [video]VSync | Vertical sync | 0 is off. On stops tearing and can add a little delay.
    [video]PauseOnFocusLoss | Pause when away | 1 pauses the game when it is not in front.
    [video]AspectRatio | Aspect ratio | 0 is automatic.
    # Red Dead Redemption 2: Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml
    [advancedGraphics]API | Graphics API | kSettingAPI_Vulkan or kSettingAPI_DX12. If the game will not start, try the other one.
    [graphics]lightingQuality | Lighting quality | A level, like kSettingLevel_Medium. Lower is faster.
    [graphics]volumetricsQuality | Fog and light rays quality | A level, like kSettingLevel_Medium. One of the slowest settings; keep it low.
    # RPG Maker XP, VX and VX Ace: Game.ini [Game]
    [Game]Library | Engine library | The RPG Maker file the game runs on (like RGSS104E.dll). Leave it as it is.
    [Game]Scripts | Scripts file | Where the game's scripts are. Leave it as it is.
    [Game]Title | Game title | The name on the game's window.
    [Game]RTP | Run time package | The RPG Maker data pack the game needs. Leave it as it is.
    """
}
