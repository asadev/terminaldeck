import Foundation

/// AGT: the icons an agent can wear — monoline SF Symbols in six groups, and emoji
/// with search words. Every symbol name is checked against the system by a test.
public enum AGTIconCatalog {
    public struct Choice: Identifiable, Equatable, Sendable {
        public var id: String { icon.raw }
        public let icon: AGTIcon
        public let words: String
    }
    public struct Category: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let choices: [Choice]
    }

    private static func symbols(_ id: String, _ title: String, _ names: [(String, String)]) -> Category {
        Category(id: id, title: title, choices: names.map { Choice(icon: .symbol($0.0), words: $0.0.replacingOccurrences(of: ".", with: " ") + " " + $0.1) })
    }

    public static let symbolCategories: [Category] = [
        symbols("people", "People", [
            ("person", "agent user"), ("person.2", "team pair"), ("person.3", "group crew"), ("person.crop.circle", "profile avatar"),
            ("person.crop.square", "profile"), ("person.badge.key", "admin access"), ("person.badge.shield.checkmark", "trusted verified"),
            ("person.wave.2", "speaker"), ("figure.walk", "walker"), ("figure.run", "runner fast"), ("figure.wave", "hello greeter"),
            ("figure.mind.and.body", "calm"), ("brain.head.profile", "thinker ai"), ("brain", "mind ai smart"), ("eye", "watcher observer"),
            ("hand.raised", "stop helper"), ("hand.thumbsup", "approver"), ("face.smiling", "happy friendly"), ("theatermasks", "actor role"),
            ("person.and.background.dotted", "persona"),
        ]),
        symbols("roles", "Roles", [
            ("graduationcap", "teacher student learn"), ("briefcase", "manager business"), ("stethoscope", "doctor health checker"),
            ("paintbrush", "designer artist"), ("paintpalette", "design colour"), ("pencil.and.ruler", "architect planner"),
            ("hammer", "builder developer"), ("wrench.and.screwdriver", "fixer maintenance"), ("magnifyingglass", "researcher search"),
            ("checkmark.seal", "reviewer inspector qa"), ("shield", "guard security"), ("lock.shield", "security safety"),
            ("megaphone", "marketing announcer"), ("chart.bar", "analyst data"), ("chart.line.uptrend.xyaxis", "growth finance"),
            ("dollarsign.circle", "money sales billing"), ("building.columns", "legal bank"), ("scalemass", "law judge balance"),
            ("books.vertical", "librarian knowledge"), ("book", "writer reader docs"), ("newspaper", "news editor"),
            ("camera", "photographer media"), ("music.note", "music"), ("film", "video editor"), ("crown", "leader boss lead"),
            ("flag", "goal milestone"), ("star", "favourite star"), ("rosette", "award quality"), ("trophy", "winner"),
            ("medal", "champion"),
        ]),
        symbols("tools", "Tools", [
            ("terminal", "shell command line"), ("chevron.left.forwardslash.chevron.right", "code developer"), ("curlybraces", "code json"),
            ("ladybug", "debugger bugs"), ("ant", "bugs tester"), ("gearshape", "settings ops"), ("gearshape.2", "automation ops"),
            ("slider.horizontal.3", "tuner config"), ("wand.and.stars", "magic generator"), ("sparkles", "ai creative"),
            ("bolt", "fast power"), ("cpu", "processor engine"), ("memorychip", "memory"), ("server.rack", "server devops deploy"),
            ("externaldrive", "storage backup"), ("cylinder.split.1x2", "database"), ("cloud", "cloud hosting"), ("network", "network infra"),
            ("globe", "web internet"), ("link", "integrations links"), ("doc.text", "documents writer"), ("folder", "files"),
            ("tray.full", "inbox triage"), ("archivebox", "archive"), ("shippingbox", "release package shipping"),
            ("cube", "model 3d"), ("puzzlepiece", "plugin"), ("testtube.2", "tester lab qa"), ("flask", "experiment science"),
            ("scissors", "editor cut"), ("ruler", "measure"), ("pencil", "writer edit"), ("highlighter", "highlight notes"),
            ("eyedropper", "colour picker"), ("keyboard", "typing"), ("command", "shortcut mac"), ("function", "math function"),
            ("number", "numbers"), ("list.bullet.clipboard", "planner checklist"), ("checklist", "tasks todo"),
            ("calendar", "scheduler planner"), ("clock", "time"), ("timer", "timer"), ("hourglass", "waiting"),
            ("bell", "alerts notifications"), ("envelope", "email mail"), ("paperplane", "sender messages"),
            ("bubble.left.and.bubble.right", "chat support"), ("phone", "calls support"),
            ("antenna.radiowaves.left.and.right", "broadcast signal"),
        ]),
        symbols("devices", "Devices", [
            ("desktopcomputer", "computer mac"), ("laptopcomputer", "laptop"), ("iphone", "phone mobile ios"), ("ipad", "tablet"),
            ("applewatch", "watch"), ("display", "screen monitor"), ("printer", "print"), ("tv", "television"),
            ("headphones", "listener audio"), ("speaker.wave.2", "speaker sound"), ("mic", "voice microphone"),
            ("gamecontroller", "games player"), ("airplane", "travel"), ("car", "driver"), ("bicycle", "bike"), ("tram", "transit"),
        ]),
        symbols("nature", "Nature", [
            ("leaf", "green eco"), ("tree", "tree"), ("flame", "fire hot"), ("drop", "water"), ("snowflake", "cold ice"),
            ("sun.max", "sun day"), ("moon", "night"), ("cloud.sun", "weather"), ("tornado", "storm"), ("mountain.2", "mountain"),
            ("globe.americas", "world earth"), ("hare", "rabbit fast"), ("tortoise", "turtle slow"), ("bird", "bird owl"),
            ("fish", "fish"), ("pawprint", "animal pet"), ("lizard", "lizard"), ("teddybear", "bear toy"), ("cat", "cat"),
            ("dog", "dog"), ("atom", "science atom"),
        ]),
        symbols("objects", "Objects", [
            ("lightbulb", "idea"), ("key", "keys access"), ("lock", "lock private"), ("bag", "shop"), ("cart", "shopping store"),
            ("gift", "present"), ("house", "home"), ("building.2", "office company"), ("map", "map guide"), ("mappin", "location"),
            ("binoculars", "scout explorer"), ("eyeglasses", "reader reviewer"), ("umbrella", "cover insurance"), ("tent", "camp"),
            ("bookmark", "saved"), ("tag", "label"), ("paperclip", "attach"), ("pin", "pinned"), ("cup.and.saucer", "coffee break"),
            ("fork.knife", "food"), ("dice", "random game"), ("airplane.departure", "launch"), ("target", "aim goal"),
            ("scope", "focus"), ("square.stack.3d.up", "layers stack"),
        ]),
    ]

    private static func emoji(_ list: [(String, String)]) -> [Choice] { list.map { Choice(icon: .emoji($0.0), words: $0.1) } }

    public static let emojiChoices: [Choice] = emoji([
        ("🤖", "robot bot ai"), ("🦉", "owl hoot wise"), ("🧠", "brain smart"), ("👩‍💻", "developer coder woman"), ("👨‍💻", "developer coder man"),
        ("🧑‍💻", "developer coder"), ("🧑‍🔬", "scientist research"), ("🧑‍🎨", "artist designer"), ("🧑‍🏫", "teacher"), ("🧑‍⚖️", "judge legal"),
        ("🧑‍🔧", "mechanic fixer"), ("🧑‍🚀", "astronaut explorer"), ("🧑‍✈️", "pilot lead"), ("🕵️", "detective investigator"), ("👷", "builder worker"),
        ("🧙", "wizard magic"), ("🦸", "hero"), ("🥷", "ninja stealth"), ("👑", "king queen boss"), ("🎩", "manager top hat"),
        ("🚀", "rocket launch ship"), ("⚡", "fast power"), ("🔥", "fire hot"), ("✨", "sparkle magic"), ("💡", "idea"),
        ("🎯", "target goal"), ("🛠️", "tools build"), ("🔧", "wrench fix"), ("🔨", "hammer build"), ("⚙️", "gear settings"),
        ("🧪", "test lab"), ("🔬", "microscope research"), ("🔭", "telescope explore"), ("🧬", "dna biology"), ("🧲", "magnet"),
        ("💻", "laptop computer"), ("🖥️", "desktop computer"), ("📱", "phone mobile"), ("⌨️", "keyboard"), ("🖱️", "mouse"),
        ("🗄️", "database cabinet"), ("💾", "save disk"), ("📦", "package release"), ("🧩", "puzzle plugin"), ("🔌", "plug integration"),
        ("🛡️", "shield security"), ("🔒", "lock private"), ("🔑", "key access"), ("🕹️", "joystick game"), ("📡", "satellite signal"),
        ("📊", "chart analytics"), ("📈", "growth"), ("💰", "money"), ("💳", "payments card"), ("🧾", "receipt billing"),
        ("📝", "notes writer"), ("📚", "books docs"), ("📖", "reader"), ("✏️", "pencil edit"), ("🖊️", "pen"),
        ("📣", "megaphone marketing"), ("📢", "announce"), ("✉️", "email"), ("💬", "chat"), ("🗣️", "speaker voice"),
        ("📅", "calendar plan"), ("⏰", "alarm time"), ("⏳", "hourglass wait"), ("✅", "done check review"), ("📌", "pin"),
        ("🔍", "search find"), ("🧭", "compass guide"), ("🗺️", "map plan"), ("🏗️", "construction build"), ("🏛️", "institution legal"),
        ("🏠", "home"), ("🏢", "office company"), ("🌍", "world global"), ("🌐", "web internet"), ("☁️", "cloud"),
        ("🌙", "night moon"), ("☀️", "sun day"), ("⭐", "star"), ("🌈", "rainbow"), ("❄️", "cold snow"),
        ("🌱", "seedling grow"), ("🌳", "tree"), ("🍀", "luck clover"), ("🌸", "flower"), ("🌊", "wave ocean"),
        ("🐙", "octopus multitask"), ("🦊", "fox clever"), ("🐝", "bee busy"), ("🐢", "turtle slow"), ("🐇", "rabbit fast"),
        ("🦅", "eagle"), ("🐺", "wolf"), ("🦁", "lion leader"), ("🐯", "tiger"), ("🐻", "bear"),
        ("🐼", "panda"), ("🐨", "koala"), ("🐸", "frog"), ("🐧", "penguin"), ("🦄", "unicorn"),
        ("🐶", "dog"), ("🐱", "cat"), ("🐭", "mouse"), ("🦋", "butterfly"), ("🐞", "ladybug bugs"),
        ("🐛", "bug debug"), ("🦖", "dinosaur"), ("🐉", "dragon"), ("🦈", "shark"), ("🐬", "dolphin"),
        ("🎨", "art design"), ("🎬", "film video"), ("🎵", "music"), ("📷", "camera photo"), ("🎮", "game"),
        ("🎲", "dice random"), ("🏆", "trophy winner"), ("🥇", "first medal"), ("🎓", "graduate learn"), ("🧳", "travel"),
        ("☕", "coffee"), ("🍕", "pizza"), ("🍎", "apple"), ("🧁", "cupcake"), ("🍩", "donut"),
        ("👀", "eyes watch"), ("👋", "wave hello"), ("👍", "thumbs up approve"), ("🙌", "celebrate"), ("💪", "strong"),
        ("😀", "smile happy"), ("😎", "cool"), ("🤓", "nerd"), ("🧐", "inspector monocle"), ("🤠", "cowboy"),
        ("👻", "ghost"), ("👽", "alien"), ("💎", "gem diamond"), ("🔮", "crystal ball predict"), ("🪄", "magic wand"),
    ])

    public static var all: [Choice] { symbolCategories.flatMap(\.choices) + emojiChoices }

    public static func search(_ query: String, in choices: [Choice]) -> [Choice] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty else { return choices }
        return choices.filter { $0.words.lowercased().contains(words) }
    }

    /// A sensible icon from the name and role, so a fresh install never shows blanks.
    public static func defaultIcon(name: String, role: String, provider: String?, session: Bool = false) -> AGTIcon {
        let rules: [([String], String)] = [
            (["review", "inspect", "qa", "verif", "audit"], "checkmark.seal"),
            (["mobile", "ios ", "ios-", "iphone", "android", "phone"], "iphone"),
            (["secur", "guard", "safety"], "lock.shield"),
            (["test"], "testtube.2"),
            (["design", "ux "], "paintpalette"),
            (["research", "search", "scout", "investig"], "magnifyingglass"),
            (["doc", "writ", "copy", "content"], "doc.text"),
            (["data", "analy", "metric", "report"], "chart.bar"),
            (["deploy", "ops", "server", "infra", "release"], "server.rack"),
            (["support", "chat", "customer"], "bubble.left.and.bubble.right"),
            (["plan", "lead", "manag", "commander", "orchestr", "boss"], "crown"),
                        (["market", "sales", "growth"], "megaphone"),
            (["finance", "billing", "money"], "dollarsign.circle"),
            (["debug", "bug", "fix"], "ladybug"),
            (["build", "develop", "engineer", "code", "coder", "backend", "frontend"], "hammer"),
        ]
        // The name says the most ("iOS engineer"); the role only when the name says nothing.
        for text in [name.lowercased(), role.lowercased()] {
            for (keys, symbol) in rules where keys.contains(where: { text.contains($0) }) { return .symbol(symbol) }
        }
        if session {
            switch (provider ?? "").lowercased() {
            case "codex": return .symbol("chevron.left.forwardslash.chevron.right")
            case "gemini": return .symbol("sparkles")
            default: return .symbol("terminal")
            }
        }
        return .symbol("person.crop.circle")
    }
}
