import Foundation
import TelegramShell

/// A hundred days with Yuliya, so the timeline has something to zoom through. Deterministic (seeded): a few days that
/// stand out (a boat trip, her birthday, five days offline in the mountains, the dumpling place, the move, a Figma
/// meetup, fur coats for sale), with photos, among ordinary days of small talk that doesn't repeat itself. It ends on
/// the day the film scans came back: that is the conversation the chat opens on.
enum History {
    static let span = 100

    /// The conversation plus a summary for every day in it, written the way an on-device summarizer would: what
    /// happened, in a sentence or three, addressed to the reader.
    static func make() -> (chat: DemoChat, summaries: [Date: DaySummary]) {
        var rng = SeededRandom(seed: 14)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var messages: [DemoMessage] = []
        var summaries: [Date: DaySummary] = [:]
        var recent: [Int] = []
        var used = Set<Int>()
        for offset in stride(from: span, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            if let event = events[offset] {
                messages += place(event.blocks, on: day, rng: &rng)
                if let summary = event.summary { summaries[day] = summary }
            } else {
                let (blocks, summary) = ordinaryDay(weekday: calendar.component(.weekday, from: day), recent: &recent, used: &used, rng: &rng)
                messages += place(blocks, on: day, rng: &rng)
                if let summary { summaries[day] = summary }
            }
        }
        return (DemoChat(peer: DemoData.yuliya, messages: messages), summaries)
    }

    /// Day offsets the scenario playback visits: the Figma meetup and the fur coats on Vestiaire.
    static let figmaMeetupOffset = 24
    static let furCoatsOffset = 8

    // MARK: Days that stand out (key: days ago)

    /// A line of the chat. Text starting with "photo:" is a photo message (files in App/Photos; "photo:a.jpg,b.jpg"
    /// is an album).
    typealias Line = (out: Bool, text: String)
    typealias Block = (time: String, lines: [Line])

    static let events: [Int: (summary: DaySummary?, blocks: [Block])] = [
        96: (DaySummary(title: "Boat trip", text: "You left from Pier 3 at 10 with the sandwiches Yuliya packed. Dolphins swam right up to the boat and she sent the video. Both of you came back sunburnt and agreed to do it again in September."), [
            ("08:10", [(false, "Boat day!! ⛵️"), (true, "Captain says we leave at 10 sharp"), (false, "I packed sandwiches for an army"), (true, "Good, the army is hungry")]),
            ("09:42", [(false, "Where are you?"), (true, "Parking. Pier 3, the white one with the blue stripe"), (false, "I see you! 👋")]),
            ("11:20", [(true, "photo:boat-1.jpg"), (false, "That's us from the pier?? Send it to mom")]),
            ("13:05", [(false, "photo:dolphin-1.jpg,dolphin-2.jpg"), (false, "I'M STILL SCREAMING 🐬"), (true, "Best day of the summer"), (false, "Of the year")]),
            ("17:30", [(true, "photo:boat-2.jpg"), (false, "Frame this one")]),
            ("19:48", [(false, "Sunburnt but happy"), (true, "Same. Aloe is in the bathroom"), (false, "Let's do it again in September"), (true, "Booking it tomorrow")]),
            ("22:30", [(false, "photo:sunset-2.jpg"), (true, "Framing it. Seriously"), (false, "❤️")]),
        ]),
        57: (DaySummary(title: "Yuliya's birthday", text: "Flowers and croissants were waiting for her in the kitchen. Her mom called in tears and Lena sent a video from all the girls. Dinner at 8 at the table by the window; she called it her best birthday ever."), [
            ("00:00", [(true, "Happy birthday, Yuliya 🎂"), (true, "Wake up, there's a surprise in the kitchen")]),
            ("07:31", [(false, "photo:flowers.jpg"), (false, "FLOWERS??"), (false, "And croissants 🥐"), (false, "You're impossible"), (true, "Only on your birthday")]),
            ("12:15", [(false, "Mom called, she cried"), (false, "Lena sent a video from all the girls"), (true, "Dinner at 8, dress nicely"), (false, "Where are we going?"), (true, "Secret")]),
            ("20:02", [(false, "Leaving now"), (true, "Table by the window")]),
            ("22:10", [(true, "photo:cake.jpg"), (false, "I can't believe they brought the cake out with ALL the candles")]),
            ("23:40", [(false, "Best birthday ever. Thank you ❤️"), (true, "Happy birthday again"), (false, "🥹")]),
        ]),
        45: (DaySummary(title: "Off to the mountains", text: "Yuliya left for five days in the mountains with no signal. She promised to text from every peak that has Wi-Fi."), [
            ("09:00", [(false, "Going offline for 5 days, no signal up there 🏔"), (true, "Text me from every peak with Wi-Fi"), (false, "Promise")]),
            ("18:20", [(false, "Last bar of signal. Love you"), (true, "Love you. Be careful")]),
        ]),
        44: (nil, []), 43: (nil, []), 42: (nil, []), 41: (nil, []), 40: (nil, []),
        39: (DaySummary(title: "Back from the mountains", text: "Yuliya came back with 2,000 photos and sent the view from the top. You put the kettle on. Next time you're going together."), [
            ("17:12", [(false, "Back!!"), (false, "I took 2,000 photos"), (true, "Show me ALL of them"), (false, "Coming home, kettle on?"), (true, "Already on")]),
            ("21:00", [(false, "photo:mountain-1.jpg,mountain-2.jpg"), (false, "The view from the top 🤍"), (true, "Unreal"), (false, "Next time you're coming"), (true, "Deal")]),
        ]),
        30: (DaySummary(title: "The dumpling place", text: "You finally went to the dumpling place Yuliya had been talking about. She ordered three kinds and declared the soup ones the winner. You're going back with Lena."), [
            ("12:40", [(false, "Dumplings today. No excuses 🥟"), (true, "I skipped breakfast for this"), (false, "Professional")]),
            ("14:15", [(false, "photo:dumplings.jpg"), (true, "Three kinds?"), (false, "Research"), (true, "And the verdict?"), (false, "The soup ones. Not even close")]),
            ("19:30", [(true, "Still thinking about those dumplings"), (false, "We're taking Lena next week"), (true, "She'll never leave")]),
        ]),
        24: (DaySummary(title: "Figma meetup", text: "You came back from the Figma meetup with two shirts and a pile of stickers. Yuliya claimed the blue shirt at once. The talk on variables was the best of the evening."), [
            ("18:40", [(true, "At the Figma meetup, don't wait up 🎨"), (false, "Bring me something 👀")]),
            ("22:15", [(true, "photo:figma-merch.jpg"), (false, "You robbed them 😂"), (true, "Two shirts, a pile of stickers and one Sprite"), (false, "The blue one is mine now 💙"), (true, "Knew it 🙄")]),
            ("22:31", [(false, "How were the talks?"), (true, "The one on variables was great. The rest was pizza"), (false, "So a perfect evening")]),
        ]),
        8: (DaySummary(title: "Fur coats on Vestiaire", text: "Yuliya is selling both fur coats on Vestiaire: there's no room for them in the new place. You picked the shots from the coast for the listing, and it goes up tonight."), [
            ("13:02", [(false, "Putting both coats on Vestiaire 🧥🧥"), (false, "Help me pick photos for the listing"), (false, "photo:fur-1.jpg,fur-2.jpg"), (true, "Selling both? 😮"), (false, "Both. No room in the new place 📦")]),
            ("13:10", [(true, "These two. The sea does half the selling 🌊"), (false, "Listing goes up tonight ✨"), (true, "Gone in an hour, watch ⏱")]),
        ]),
        3: (DaySummary(title: "Sunset at the bay", text: "You went to the spot on the far side of the bay for the sunset. Yuliya brought the camera and you finished the roll of film there. It goes to the lab next."), [
            ("15:20", [(false, "Sunset spot at 7? I'll bring the camera 📷"), (true, "And I'll finish the roll"), (false, "Six frames left, make them count")]),
            ("19:48", [(false, "photo:sunset-1.jpg"), (false, "Worth every minute 🌅"), (true, "Last frame was you against that sky"), (false, "Take it to the lab already")]),
        ]),
        1: (DaySummary(title: nil, text: "You dropped the roll of film at the lab; the scans are due before noon tomorrow. Yuliya is counting the hours.", salience: 3), [
            ("17:36", [(true, "Dropped the roll at the lab"), (false, "Finally!! When?"), (true, "Tomorrow before noon"), (false, "I'm counting the hours ⏳")]),
        ]),
        0: (DaySummary(title: "Film scans", text: "The scans came back from the lab. Yuliya says her portrait in the fur coat looks like a movie poster, and she's proud of the one she took of you. Prints of both go on the fridge and the wall."), [
            ("09:12", [(true, "The scans are back from the lab 🎞✨"), (true, "photo:film-1.jpg,film-2.jpg"), (true, "The first one is your masterpiece 📸")]),
            ("09:14", [(false, "WAIT 😳"), (false, "Is that me?? I look like a movie poster 🎬"), (false, "And the one of you came out SO good 🥹")]),
            ("09:15", [(true, "Ordering prints. 10×15?")]),
            ("09:16", [(false, "Bigger. The fridge AND the wall 🖼❤️")]),
        ]),
        18: (DaySummary(title: "Moving day", text: "You got the keys at 8; the movers showed up 40 minutes late. The green armchair went by the window and the cat claimed it at once. Pizza on the floor among the boxes, then the first night in your own home."), [
            ("08:05", [(true, "Keys are ours 🔑"), (false, "AAAAA"), (false, "Coming right after work")]),
            ("10:30", [(true, "photo:boxes.jpg"), (true, "Movers are 40 minutes late"), (false, "Of course they are")]),
            ("13:12", [(true, "Where do you want the green armchair?"), (false, "By the window, where the sun is"), (true, "photo:cat.jpg"), (true, "The cat already took it"), (false, "Then it's his now 😂")]),
            ("16:40", [(false, "Leaving work, need anything?"), (true, "Pizza. Lots of pizza"), (false, "And wine"), (true, "And light bulbs, the hallway is dark")]),
            ("19:55", [(false, "Here!")]),
            ("21:10", [(false, "photo:pizza.jpg"), (true, "Fine dining on the floor")]),
            ("23:58", [(false, "First night in our home"), (true, "Our home ❤️"), (false, "Boxes everywhere and I'm so happy")]),
        ]),
    ]

    // MARK: Ordinary days

    /// Small talk: how much each exchange says about the day (logistics like the taxi only make it into a summary
    /// when nothing else happened), and the sentence a summarizer would write about it.
    static let exchanges: [(weight: Int, summary: String, lines: [Line])] = [
        (0, "Good morning texts over coffee.", [(false, "Good morning ☀️"), (true, "Morning! Coffee first")]),
        (1, "Pasta for dinner, again.", [(false, "What do you want for dinner?"), (true, "Pasta?"), (false, "Pasta again 😅"), (true, "Pasta forever")]),
        (0, "You picked up bread on the way home.", [(true, "Leaving work now"), (false, "Grab some bread on the way?"), (true, "Ok")]),
        (2, "Yuliya met a cat that looks exactly like Bublik.", [(false, "You should see the cat I just met"), (true, "Let me guess. Looks exactly like Bublik"), (false, "I almost took him home")]),
        (0, "Yuliya asked when you'd be home.", [(false, "Are you home?"), (true, "10 min")]),
        (1, "Yuliya reminded you to call her mom about Sunday.", [(false, "Call mom tonight, she asked about Sunday"), (true, "Will do")]),
        (1, "Your meeting ran late; Yuliya was at the gym anyway.", [(true, "Meeting ran late, sorry"), (false, "No worries, I'm at the gym anyway")]),
        (1, "You booked the dentist for 9 the next morning.", [(false, "Did you book the dentist?"), (true, "Tomorrow at 9"), (false, "Proud of you")]),
        (2, "The song from the café was stuck in Yuliya's head all day.", [(false, "This song is stuck in my head all day"), (true, "Which one"), (false, "The one from the café")]),
        (2, "Movie night: you settled on Paddington 2.", [(true, "Movie tonight?"), (false, "Something light please"), (true, "Paddington 2 then"), (false, "Perfect 🧸")]),
        (1, "Yuliya went to the market; you asked for tomatoes and the good cheese.", [(false, "I'm at the market, need anything?"), (true, "Tomatoes and the good cheese")]),
        (0, "It rained again.", [(false, "Rain again 🌧"), (true, "Take the umbrella, it's by the door")]),
        (1, "You missed each other.", [(false, "Miss you"), (true, "Miss you more ❤️")]),
        (1, "The plants got watered, even the sad one.", [(false, "Plants watered?"), (true, "All of them. Even the sad one")]),
        (2, "Yuliya asked for the photos from Saturday.", [(false, "Can you send me the photos from Saturday?"), (true, "Sending now"), (false, "The third one is going on the fridge")]),
        (0, "Yuliya ran 15 minutes late, so you ordered for her.", [(false, "Running 15 min late"), (true, "Ordered for you already"), (false, "You're the best")]),
        (2, "You went for a walk in the park at 7.", [(true, "Walk after work?"), (false, "Yes, park at 7?"), (true, "I'll bring the good headphones")]),
        (3, "Your design review went well.", [(true, "Design review went well 🎉"), (false, "Told you!"), (true, "They want it in the next release")]),
        (0, "Laundry got done.", [(false, "Laundry is done"), (true, "I'll fold it, promise")]),
        (0, "Yuliya took a taxi.", [(false, "Taxi is here"), (true, "Coming down")]),
        (2, "You found the dumpling place Yuliya liked and planned to go on Saturday.", [(true, "Found the place with the dumplings you liked"), (false, "Saturday?"), (true, "Saturday")]),
        (3, "Lena is coming over on Friday, and you're making the lasagna.", [(false, "Lena is coming over on Friday"), (true, "I'll make the lasagna"), (false, "She'll bring the wine")]),
        (3, "Yuliya got two tickets for the concert on the 14th, right at the front.", [(false, "Guess who got tickets 🎟"), (true, "No way. For the 14th?"), (false, "Two, standing, right at the front"), (true, "You're a hero")]),
        (2, "You got a flat tire and pushed the bike to work.", [(true, "Got a flat on the way to work"), (false, "Oh no. Walking?"), (true, "Pushing the bike like a sad cowboy")]),
        (1, "Yuliya asked for your mom's borscht recipe.", [(false, "Send me your mom's borscht recipe?"), (true, "She guards it with her life. I'll ask"), (false, "Tell her it's for science")]),
        (0, "Your headphones arrived and Yuliya opened the package.", [(false, "A package came for you"), (true, "The headphones! Don't open it"), (false, "Too late 🙈")]),
        (2, "Yuliya finished the book you recommended, and the ending wrecked her.", [(false, "Finished the book. I'm destroyed"), (true, "Told you the ending hurts"), (false, "You could have warned me properly")]),
        (3, "You planned Sunday at the lake, if the weather holds.", [(true, "Lake on Sunday if the weather holds?"), (false, "Yes! I'll bring the thermos"), (true, "And the blanket with the foxes")]),
        (3, "Yuliya was offered the team lead role and has until Friday to decide.", [(false, "They offered me the team lead role"), (true, "WHAT. Congratulations!!"), (false, "I said I'd think until Friday"), (true, "Champagne either way")]),
        (0, "Yuliya's keys turned up on the shelf by the door.", [(false, "Did I leave my keys at yours?"), (true, "On the shelf by the door"), (false, "Phew")]),
        (1, "Yuliya had a headache; you prescribed tea and no screens.", [(false, "Headache all day"), (true, "Tea, dark room, no screens. Doctor's orders"), (false, "Yes doctor")]),
        (2, "You decided to give Lena a ceramics class for her birthday.", [(false, "What do we get Lena for her birthday?"), (true, "The ceramics class she keeps mentioning?"), (false, "Genius")]),
        (2, "You booked the train for the 3rd, window seats.", [(true, "Booked the train for the 3rd, 8:40"), (false, "Window seats?"), (true, "Obviously")]),
        (2, "You burned the rice, so it was sushi for dinner.", [(true, "I burned the rice"), (false, "How do you burn rice"), (true, "Talent"), (false, "Ordering sushi")]),
        (0, "The neighbours were drilling again.", [(false, "The neighbours are drilling again"), (true, "On a Sunday?"), (false, "On a Sunday")]),
        (2, "Yuliya hit a new deadlift record: 80 kg.", [(false, "New record on the deadlift 💪"), (true, "How much?"), (false, "80!"), (true, "I'm slightly afraid of you now")]),
        (1, "You found a new coffee place near the office.", [(true, "New coffee place by the office is great"), (false, "Take me Saturday")]),
        (0, "You forgot your charger; Yuliya lent you hers.", [(true, "Forgot my charger at home"), (false, "Top drawer at my desk, take mine")]),
        (1, "You stayed up late for one more episode.", [(false, "One more episode?"), (true, "It's 1 am"), (false, "So that's a yes")]),
        (2, "Bublik has a vet appointment on Thursday at 6; you're taking him.", [(false, "Bublik's vet appointment is Thursday at 6"), (true, "I'll take him"), (false, "He will hate you forever")]),
        (3, "Yuliya passed her driving theory test on the first try.", [(false, "PASSED 🚗"), (true, "First try?!"), (false, "First try. 2 mistakes"), (true, "Dinner's on me")]),
        (2, "You fixed the leaking kitchen tap yourself.", [(true, "Fixed the tap"), (false, "Yourself??"), (true, "With a video and a wrench"), (false, "My hero plumber")]),
        (3, "Your parents invited you both for the weekend of the 20th.", [(true, "Mom wants us over the weekend of the 20th"), (false, "Yes! I'll bake the plum cake"), (true, "She asked for it specifically")]),
        (2, "Yuliya's flight was delayed by two hours; you moved the pickup.", [(false, "Flight delayed 2 hours 🙄"), (true, "I'll move the pickup"), (false, "Gate B14, I live here now")]),
        (2, "You argued about the thermostat and settled on 21 degrees.", [(false, "Who set the heating to 24?"), (true, "I was cold"), (false, "21. Final offer"), (true, "Deal, but I get the blanket")]),
        (3, "Yuliya's sister had her baby: a girl, 3.4 kg.", [(false, "She's here!! A girl, 3.4 kg 💗"), (true, "Congratulations, auntie!"), (false, "I'm crying in the corridor")]),
        (2, "You tried the new ramen place: too salty, back to the old one.", [(true, "Ramen verdict?"), (false, "Too salty. 6/10"), (true, "Back to the old place then")]),
        (2, "Yuliya left her umbrella on the tram, the third one this year.", [(false, "I left the umbrella on the tram"), (true, "The third one this year"), (false, "I'm keeping the tram company in business")]),
        (3, "Your bonus came through and went into the trip fund.", [(true, "Bonus came through 💸"), (false, "Trip fund?"), (true, "Trip fund")]),
        (2, "Yuliya signed up for pottery on Tuesdays at 7.", [(false, "Signed up for pottery, Tuesdays at 7"), (true, "I expect a mug"), (false, "You'll get a lopsided bowl and like it")]),
        (2, "The car wouldn't start; a neighbour jump-started the battery.", [(true, "Car won't start"), (false, "Battery?"), (true, "Battery. The neighbour is jump-starting it")]),
        (2, "You picked the paint for the bedroom: the pale green.", [(false, "Pale green or the sand one?"), (true, "Pale green"), (false, "Buying two cans")]),
        (3, "Yuliya's presentation went well and the client signed.", [(false, "They signed!!"), (true, "I knew it. How was the presentation?"), (false, "I didn't even look at my notes")]),
        (2, "You watched the meteor shower from the roof; Yuliya counted 14.", [(true, "Meteor shower tonight, roof at 11?"), (false, "Bringing blankets and tea"), (false, "I counted 14!")]),
        (2, "Yuliya cracked her phone screen and booked the repair for Thursday.", [(false, "Dropped my phone. The screen is a spiderweb"), (true, "Repair place on Thursday?"), (false, "Booked")]),
        (2, "The surprise for Lena's birthday is ready: balloons are hidden in the car.", [(true, "Lena suspects nothing"), (false, "Balloons are hidden in the car"), (true, "Operation Ceramics is go")]),
        (3, "You booked flights to Lisbon for March 12 to 17.", [(true, "Lisbon in March. Flights are cheap right now"), (false, "BOOK IT"), (true, "Booked. 12th to the 17th")]),
        (2, "Yuliya ran her first 10K in 58 minutes.", [(false, "10K done! 58 minutes"), (true, "Under an hour!!"), (false, "My legs have filed a complaint")]),
        (2, "The elevator broke, so you carried the groceries up six floors.", [(true, "Elevator is dead"), (false, "With all the groceries?"), (true, "Six floors. I am a changed man")]),
        (2, "Yuliya bought a monstera to keep the sad plant company.", [(false, "I may have bought a monstera"), (true, "Where will it live"), (false, "Next to the sad one. For moral support")]),
        (2, "Yuliya's university friend Katya is in town; coffee on Wednesday.", [(false, "Katya is in town!"), (true, "The one from university?"), (false, "Coffee on Wednesday, you're coming")]),
        (3, "You both had a cold and spent the day on the couch with soup.", [(false, "I think I caught your cold"), (true, "Soup is on the stove"), (false, "Couch, blanket, soup. Perfect day actually")]),
    ]

    static func ordinaryDay(weekday: Int, recent: inout [Int], used: inout Set<Int>, rng: inout SeededRandom) -> ([Block], DaySummary?) {
        if rng.next(below: 10) == 0 { return ([], nil) }
        let weekend = weekday == 1 || weekday == 7
        let count = weekend ? 2 + rng.next(below: 3) : 1 + rng.next(below: 3)
        let hours = (0..<count).map { _ in min(23, 8 + rng.next(below: 15)) }.sorted()
        // Real chats don't loop: news (weight 2 and up) happens once; routine comes back, but not for a while.
        let routine = exchanges.indices.filter { exchanges[$0].weight < 2 }.count
        var picks: [Int] = []
        for _ in hours {
            var pick = rng.next(below: exchanges.count)
            var tries = 0
            while tries < exchanges.count, recent.contains(pick) || used.contains(pick) {
                pick = (pick + 1) % exchanges.count
                tries += 1
            }
            picks.append(pick)
            if exchanges[pick].weight >= 2 {
                used.insert(pick)
            } else {
                recent.append(pick)
                if recent.count > routine - 6 { recent.removeFirst() }
            }
        }
        let blocks = zip(hours, picks).map { hour, pick in
            (String(format: "%02d:%02d", hour, rng.next(below: 50)), exchanges[pick].lines)
        }
        // What a summarizer would say: the two things that say the most about the day. Logistics only if that's all.
        let ranked = picks.sorted { exchanges[$0].weight > exchanges[$1].weight }
        let top = exchanges[ranked[0]].weight > 0 ? ranked.filter { exchanges[$0].weight > 0 }.prefix(2) : ranked.prefix(1)
        let summary = DaySummary(title: nil, text: top.map { exchanges[$0].summary }.joined(separator: " "),
                                 salience: exchanges[ranked[0]].weight)
        return (blocks, summary)
    }

    static func place(_ blocks: [Block], on day: Date, rng: inout SeededRandom) -> [DemoMessage] {
        var result: [DemoMessage] = []
        var last = day
        for block in blocks {
            let parts = block.time.split(separator: ":").compactMap { Int($0) }
            var time = max(last, day.addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60)))
            for line in block.lines {
                if line.text.hasPrefix("photo:") {
                    let names = line.text.dropFirst(6).split(separator: ",").map(String.init)
                    result.append(DemoMessage(text: "", isOutgoing: line.out, date: time, photos: names))
                } else {
                    result.append(DemoMessage(text: line.text, isOutgoing: line.out, date: time))
                }
                time = time.addingTimeInterval(TimeInterval(30 + rng.next(below: 120)))
            }
            last = time
        }
        return result
    }
}

/// SplitMix64: the same history on every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
}
