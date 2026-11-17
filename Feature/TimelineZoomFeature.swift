import UIKit
import TelegramShell

/// Timeline Zoom: pinch out in a chat and each day's messages melt into one service message saying what the day was
/// about, grouped by week; pinch out again and the days drop into Telegram's calendar. Tap a calendar day to open the
/// chat there (through its day's row), tap a day to land at its first message. An answer to scrolling for "that day we talked about the boat": today
/// it is the calendar sheet, which knows dates and media but not what the day was about.
///
/// Launch with `-scenario` to play the demo without touching the screen (Yuliya's reply comes in, a little scroll,
/// out to the days, up to the Figma meetup, out to the calendar, into the fur coats' day, back to the latest), or with
/// `-reply` for the reply alone (xcrun simctl launch booted concept.timeline-zoom -scenario). Every motion is driven
/// per frame, so a recording is as smooth as the display; `-touches` draws the fingers. For a recording,
/// `-reply-on-signal -scenario` waits with both for `notifyutil -p concept.timeline-zoom.reply`.
@MainActor
final class TimelineZoomFeature: ChatFeature {
    private let summary: (Date) -> DaySummary?
    private var timeline: TimelineView?

    /// `summary`: what each day (start of day) was about.
    init(summary: @escaping (Date) -> DaySummary?) {
        self.summary = summary
    }

    func chatDidLoad(_ chat: ChatViewController) {
        let timeline = TimelineView(chat: chat, summary: summary)
        timeline.frame = chat.view.bounds
        timeline.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Over the messages, under the glass header and input panel.
        chat.view.insertSubview(timeline, aboveSubview: chat.scrollView)
        timeline.installUnderlays(in: chat.view, below: chat.scrollView)
        let pinch = UIPinchGestureRecognizer(target: timeline, action: #selector(TimelineView.handlePinch(_:)))
        pinch.delegate = timeline
        chat.view.addGestureRecognizer(pinch)
        self.timeline = timeline
        Task { @MainActor in timeline.prewarm() }

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-reply-on-signal") {
            // For screen recordings: the reply waits for `xcrun simctl spawn booted notifyutil -p
            // concept.timeline-zoom.reply`, so the app can launch before the recording starts.
            Self.signalled = (chat, Self.holdReply(chat))
            if arguments.contains("-scenario") {
                Self.afterSignal = { [weak self] in await self?.scenario(chat, timeline) }
            }
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                Task { @MainActor in
                    guard let (chat, reply) = TimelineZoomFeature.signalled else { return }
                    TimelineZoomFeature.signalled = nil
                    await TimelineZoomFeature.playReply(chat, reply, after: 0)
                    await TimelineZoomFeature.afterSignal?()
                }
            }, "concept.timeline-zoom.reply" as CFString, nil, .deliverImmediately)
        } else if arguments.contains("-scenario") || arguments.contains("-reply") {
            // Hidden from the first frame; it arrives once the chat has settled after launch.
            let reply = Self.holdReply(chat)
            Task { @MainActor in
                await Self.playReply(chat, reply)
                if arguments.contains("-scenario") { await self.scenario(chat, timeline) }
            }
        }
    }

    private func scenario(_ chat: ChatViewController, _ timeline: TimelineView) async {
        let fingers = ProcessInfo.processInfo.arguments.contains("-touches") ? chat.view.window.map(ScenarioFingers.init) : nil
        try? await Task.sleep(for: .seconds(1.2))
        // A little up: the album in full and yesterday above it. The finger drags the chat down with it.
        let grab = CGPoint(x: 200, y: 380), distance: CGFloat = 200
        fingers?.down(at: grab)
        try? await Task.sleep(for: .seconds(0.1))
        await ScrollAnimator.run(chat.scrollView, to: chat.scrollView.contentOffset.y - distance, duration: 0.9) { e in
            fingers?.move(to: CGPoint(x: grab.x, y: grab.y + distance * e))
        }
        fingers?.up()
        try? await Task.sleep(for: .seconds(0.9))
        let center = CGPoint(x: timeline.bounds.midX, y: timeline.bounds.height * 0.54)
        await pinch(timeline, at: center, fingers)
        try? await Task.sleep(for: .seconds(1.4))
        guard let figma = timeline.dayIndex(daysAgo: History.figmaMeetupOffset),
              let fur = timeline.dayIndex(daysAgo: History.furCoatsOffset) else { return }
        // Up through the weeks to the Figma meetup: two flicks.
        if let target = timeline.offset(showingDay: figma, at: 0.42) {
            let scroller = timeline.levelScroller
            let from = scroller.contentOffset.y
            await flick(scroller, to: from + (target - from) * 0.55, fingers)
            try? await Task.sleep(for: .seconds(0.2))
            await flick(scroller, to: target, fingers)
        }
        try? await Task.sleep(for: .seconds(2.0))
        await pinch(timeline, at: timeline.dayPoint(figma) ?? center, fingers)
        try? await Task.sleep(for: .seconds(1.3))
        if let point = timeline.dayPoint(fur) { await fingers?.tap(at: point) }
        timeline.openChat(atDay: fur)
        // The day's row, a beat, the chat; then time to read it. (A critically damped spring takes a while to call
        // itself done; the eye is done much sooner.)
        try? await Task.sleep(for: .seconds(4.6))
        let button = chat.downButton
        await fingers?.tap(at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        chat.scrollToBottom(animated: true)
    }

    /// Two fingers on a diagonal around `point` close in; `zoom` follows them out one level.
    private func pinch(_ timeline: TimelineView, at point: CGPoint, _ fingers: ScenarioFingers?) async {
        let radius: CGFloat = 120, axis = CGPoint(x: 0.6, y: 0.8)
        func contact(_ side: CGFloat, _ scale: CGFloat) -> CGPoint {
            CGPoint(x: point.x + side * axis.x * radius * scale, y: point.y + side * axis.y * radius * scale)
        }
        fingers?.down(0, at: contact(-1, 1))
        fingers?.down(1, at: contact(1, 1))
        try? await Task.sleep(for: .seconds(0.12))
        await timeline.pinchOut(at: point, fingers: { scale in
            fingers?.move(0, to: contact(-1, scale))
            fingers?.move(1, to: contact(1, scale))
        }, released: {
            fingers?.up(0)
            fingers?.up(1)
        })
    }

    /// A throw: the finger streaks down and lifts, the list carries on and decelerates to `target`.
    private func flick(_ scroller: UIScrollView, to target: CGFloat, _ fingers: ScenarioFingers?) async {
        let start = CGPoint(x: 210, y: 330), streak: CGFloat = 220, contact: CGFloat = 0.12, duration: TimeInterval = 1.1
        let from = scroller.contentOffset.y
        fingers?.down(at: start)
        try? await Task.sleep(for: .seconds(0.06))
        var lifted = false
        await FrameDriver.run(duration: duration) { t in
            scroller.contentOffset.y = from + (target - from) * (1 - pow(1 - t, 3))
            let f = t * CGFloat(duration) / contact
            if f < 1 {
                fingers?.move(to: CGPoint(x: start.x, y: start.y + streak * f))
            } else if !lifted {
                lifted = true
                fingers?.move(to: CGPoint(x: start.x, y: start.y + streak))
                fingers?.up()
            }
        }
    }

    private static func bottomOffset(_ chat: ChatViewController) -> CGFloat {
        let scrollView = chat.scrollView
        return max(-scrollView.contentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
    }

    private static var signalled: (ChatViewController, (view: MessageView, shift: CGFloat)?)?
    private static var afterSignal: (@MainActor () async -> Void)?

    /// Yuliya's last message, held back: hidden, and the chat scrolled up by its height, as before it arrived.
    static func holdReply(_ chat: ChatViewController) -> (view: MessageView, shift: CGFloat)? {
        guard chat.messageViews.count > 1, let reply = chat.messageViews.last, !reply.message.isOutgoing else { return nil }
        let previous = chat.messageViews[chat.messageViews.count - 2]
        let shift = reply.frame.maxY - previous.frame.maxY
        chat.scrollView.contentOffset.y = bottomOffset(chat) - shift
        reply.alpha = 0
        // The insets settle over the first layout passes (the input panel finds the keyboard guide): line up again.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if reply.alpha == 0 { chat.scrollView.contentOffset.y = bottomOffset(chat) - shift }
        }
        return (reply, shift)
    }

    /// The held reply arrives: "typing" in the header, then the bubble rises in as the chat scrolls to it
    /// (ChatViewController.insert's incoming animation, on a message that is already in the history).
    static func playReply(_ chat: ChatViewController, _ held: (view: MessageView, shift: CGFloat)?, after delay: TimeInterval = 1.0) async {
        guard let (reply, shift) = held else { return }
        try? await Task.sleep(for: .seconds(delay))
        let bottom = bottomOffset(chat)
        // A layout pass at launch may have scrolled back to the bottom.
        if abs(chat.scrollView.contentOffset.y - (bottom - shift)) > 1 { chat.scrollView.contentOffset.y = bottom - shift }

        let label = chat.headerView.subtitleLabel
        let resting = (label.text, label.textColor)
        label.textColor = chat.theme.onlineColor
        for i in 0..<8 {
            label.text = "typing" + String(repeating: ".", count: i % 4)
            try? await Task.sleep(for: .seconds(0.22))
        }
        label.text = resting.0
        label.textColor = resting.1

        reply.transform = CGAffineTransform(translationX: 0, y: 20)
        UIView.animate(springDuration: 0.42, bounce: 0.08) {
            chat.scrollView.contentOffset.y = bottom
            reply.transform = .identity
            reply.alpha = 1
        }
        try? await Task.sleep(for: .seconds(0.45))
    }
}
