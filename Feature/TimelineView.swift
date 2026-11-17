import UIKit
import TelegramShell

/// The zoomable timeline over the chat. `zoom`: 0 = messages (the chat itself), 1 = days, 2 = Telegram's calendar.
///
/// Days look like a group chat in which every day sent one message about itself: an avatar with the day's number, the
/// weekday as the sender, the summary as the text; weeks under date pills. Pinch out of a chat and each day's bubbles
/// flow together into that one bubble (a liquid shader, Goo.metal), while the day's date pill rounds up into its avatar.
/// Pinch out again and the bubbles fold into their avatars, which fly to their days in Telegram's own calendar. Days
/// that stand out keep a colored circle there; ordinary ones a quiet one. Taps go back down: a calendar day to its week,
/// a day to its first message.
///
/// Everything is placed in screen coordinates by `render()`, a pure function of `zoom` and one scroll offset per level.
/// A pinch drives `zoom` directly; on release a spring settles it on the nearest level. Before a zoom starts every level
/// is scrolled so the day under the fingers maps onto itself: the zoom has a fixed point, like a camera.
@MainActor
final class TimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private unowned let chat: ChatViewController
    private let summaryProvider: (Date) -> DaySummary?
    private let calendar = Calendar.current

    // Model: the days that have messages, grouped into weeks.
    private struct Day {
        let date: Date
        var messages: [Int] = []
        var week = 0
    }
    private struct Week {
        let start: Date
        var days: [Int] = []
    }
    private var days: [Day] = []
    private var weeks: [Week] = []
    private var messageDay: [Int] = []
    private var builtForCount = -1

    /// Level 1, in content coordinates.
    private struct DayLayout {
        /// The bubble with its tail column, its rounded body, and the avatar at its bottom left.
        var bubble: CGRect = .zero
        var body: CGRect = .zero
        var avatar: CGRect = .zero
    }
    private var dayLayouts: [DayLayout] = []
    private var weekPills: [CGRect] = []
    private var daysHeight: CGFloat = 0
    /// Level 2: each day's circle in the calendar's content coordinates.
    private var circles: [CGRect] = []

    private let calendarBackground = UIView()
    private let goo = GooView()
    private let calendarView = CalendarView()
    private let calendarChrome = CalendarChromeView()
    /// The week being scrolled through, stuck under the header on glass (like the chat's floating date).
    private let floatingWeek = GlassView()
    private let floatingWeekLabel = UILabel()
    /// The sheet's edges: content fades into the background under the header and the home indicator.
    private let calendarTopEdge = CAGradientLayer()
    private let calendarBottomEdge = CAGradientLayer()
    /// Under the calendar's labels: the colored avatars, which become calendar days.
    private let avatarLayer = UIView()
    private let overlay = UIView()
    private var bubbleViews: [DayBubbleView] = []
    /// Avatars of the days that stand out (nil for ordinary days, whose circle is the liquid layer's).
    private var avatarViews: [AvatarCircle?] = []
    /// Per day: thumbnails of the photos sent that day.
    private var dayPhotos: [[UIImage]] = []
    private var numberLabels: [UILabel] = []
    /// The chat's date pill text of each day, shown while the pill rounds up into the avatar.
    private var pillLabels: [UILabel] = []
    private var weekLabels: [UILabel] = []
    private var incomingColor = SIMD4<Float>(1, 1, 1, 1)
    private var outgoingColor = SIMD4<Float>(1, 1, 1, 1)

    private(set) var zoom: CGFloat = 0
    /// Per level: content y at screen y 0 (level 0 is the chat's own scroll view).
    private var offsets: [CGFloat] = [0, 0, 0]
    private var animatedMessages: [Int] = []
    /// Per animated message: its place among the animated messages of its day (index, count).
    private var slices: [Int: (index: Int, count: Int)] = [:]
    /// Per animated day: its span in the chat's content, from the date pill to the last bubble.
    private var daySpans: [Int: ClosedRange<CGFloat>] = [:]
    private var restLevel = 0
    private var shownLevel = 0
    private var pinchStartZoom: CGFloat = 0
    private var isAdjustingScroller = false
    private var restingSubtitle: (text: String?, color: UIColor?) = (nil, nil)
    /// The chat's own edge effects (top, bottom), to restore after a zoom reshapes them for the days.
    private var restingEdges: (top: CGRect, bottom: CGRect)?

    private let scroller = UIScrollView()
    private let spring = Spring()
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    static let pillBlock = Metrics.dateHeaderHeight
    static let pillRadius = Metrics.datePillHeight / 2
    /// ChatMessageBubblelessMetrics.swift: chatMessageAvatarHeaderSize, chatMessageAvatarHeaderInset;
    /// ChatMessageItemCommon.swift: avatarInset = 34 + 4.
    static let avatarSize: CGFloat = 34
    static let avatarLeft: CGFloat = 7
    static let avatarInset: CGFloat = 38
    static let daySpacing: CGFloat = 6
    /// A day stands out from this salience up.
    static let notableSalience = 4
    /// Zoom levels per halving of the pinch scale.
    static let pinchGain: CGFloat = 1.4

    init(chat: ChatViewController, summary: @escaping (Date) -> DaySummary?) {
        self.chat = chat
        self.summaryProvider = summary
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        calendarBackground.isUserInteractionEnabled = false
        overlay.isUserInteractionEnabled = false
        scroller.delegate = self
        scroller.alwaysBounceVertical = true
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.isHidden = true
        avatarLayer.isUserInteractionEnabled = false
        [avatarLayer, calendarView, overlay, scroller].forEach(addSubview)
        calendarBackground.isHidden = true
        calendarView.isHidden = true
        goo.isHidden = true
        layer.insertSublayer(calendarTopEdge, above: calendarView.layer)
        layer.insertSublayer(calendarBottomEdge, above: calendarView.layer)
        scroller.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        spring.onChange = { [weak self] value in
            self?.zoom = value
            self?.render()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            // The chat switches its theme in its own trait handler; read it after that.
            Task { @MainActor in
                self.applyTheme()
                self.render()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The liquid layer and the calendar's background go under the chat's messages (`messages`, in the same
    /// coordinates as this view): a bubble dissolves over its drop instead of the drop covering it.
    func installUnderlays(in container: UIView, below messages: UIView) {
        container.insertSubview(calendarBackground, belowSubview: messages)
        container.insertSubview(goo, belowSubview: messages)
        // The floating week goes over the wallpaper's edge effects, under the header.
        floatingWeek.isHidden = true
        floatingWeek.isUserInteractionEnabled = false
        floatingWeekLabel.font = Metrics.datePillFont
        floatingWeekLabel.textAlignment = .center
        floatingWeek.contentView.addSubview(floatingWeekLabel)
        container.insertSubview(floatingWeek, belowSubview: chat.headerView)
        // The calendar's own navigation bar goes over the chat's header, which it replaces at that level.
        calendarChrome.isHidden = true
        calendarChrome.onClose = { [weak self] in self?.closeCalendar() }
        container.addSubview(calendarChrome)
    }

    /// A tap on a week's pill: from the days to the calendar, as a tap on a date pill opens it in a chat.
    func openCalendar(at point: CGPoint) {
        guard restLevel == 1 else { return }
        start(at: point)
        beginTransition()
        animate(to: 2, velocity: 0, response: 0.9, dampingRatio: 1)
    }

    /// The calendar's close button: back to the chat, at the day in the middle of the screen.
    func closeCalendar() {
        guard restLevel == 2 else { return }
        offsets[2] = scroller.contentOffset.y
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        prepare(anchor(at: point, level: 2), focalY: point.y, from: 2)
        beginTransition()
        animate(to: 0, velocity: 0, response: 1.1, dampingRatio: 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroller.frame = bounds
        calendarBackground.frame = bounds
        goo.frame = bounds
        overlay.frame = bounds
        avatarLayer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        calendarTopEdge.frame = CGRect(x: 0, y: 0, width: bounds.width, height: chat.headerView.frame.maxY + 16)
        calendarBottomEdge.frame = CGRect(x: 0, y: bounds.height - safeAreaInsets.bottom - 16, width: bounds.width, height: safeAreaInsets.bottom + 16)
        CATransaction.commit()
    }

    // MARK: Model

    private func rebuildIfNeeded() {
        let views = chat.messageViews
        guard views.count != builtForCount else { return }
        builtForCount = views.count
        days = []
        weeks = []
        messageDay = []
        for (i, view) in views.enumerated() {
            let date = calendar.startOfDay(for: view.message.date)
            if days.last?.date != date {
                let week = calendar.dateInterval(of: .weekOfYear, for: date)!.start
                if weeks.last?.start != week { weeks.append(Week(start: week)) }
                weeks[weeks.count - 1].days.append(days.count)
                days.append(Day(date: date, week: weeks.count - 1))
            }
            days[days.count - 1].messages.append(i)
            messageDay.append(days.count - 1)
        }
        overlay.subviews.forEach { $0.removeFromSuperview() }
        avatarLayer.subviews.forEach { $0.removeFromSuperview() }
        func label(_ text: String?, font: UIFont) -> UILabel {
            let label = UILabel()
            label.font = font
            label.textAlignment = .center
            label.text = text
            label.sizeToFit()
            return label
        }
        weekLabels = weeks.map { label(weekTitle($0.start), font: Metrics.datePillFont) }
        pillLabels = days.indices.map { k in
            label(k < chat.dateHeaderViews.count ? chat.dateHeaderViews[k].label.text : nil, font: Metrics.datePillFont)
        }
        // ChatMessageDateHeader.swift: avatarPlaceholderFont(size: 16), rounded bold.
        let numberFont = UIFont(descriptor: UIFont.systemFont(ofSize: 16, weight: .bold).fontDescriptor.withDesign(.rounded)!, size: 16)
        numberLabels = days.map { label("\(calendar.component(.day, from: $0.date))", font: numberFont) }
        bubbleViews = days.map { _ in DayBubbleView() }
        // Thumbnails once, at the size the strip and the calendar show them.
        var cache: [String: UIImage] = [:]
        dayPhotos = days.map { day in
            day.messages.flatMap { chat.messageViews[$0].message.photos }.compactMap { name in
                if let cached = cache[name] { return cached }
                let thumbnail = Graphics.photo(name).flatMap { image in
                    let scale = 220 / min(image.size.width, image.size.height)
                    return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale))
                }
                cache[name] = thumbnail
                return thumbnail
            }
        }
        avatarViews = days.indices.map { k in
            dayPhotos[k].first.map { AvatarCircle(photo: $0) } ?? (isNotable(k) ? AvatarCircle(photo: nil) : nil)
        }
        for view in avatarViews.compactMap({ $0 }) {
            view.isHidden = true
            avatarLayer.addSubview(view)
        }
        for view in bubbleViews as [UIView] + numberLabels + pillLabels + weekLabels {
            view.isHidden = true
            overlay.addSubview(view)
        }
    }

    private func isNotable(_ k: Int) -> Bool { summary(k).salience >= Self.notableSalience }

    /// The day as a sender's name: "Today", "Yesterday" or the weekday.
    private func dayName(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return Self.formatter("EEEE").string(from: date)
    }

    private func summary(_ k: Int) -> DaySummary {
        summaryProvider(days[k].date)
            ?? DaySummary(title: nil, text: days[k].messages.lazy.map { self.chat.messageViews[$0].message.text }.first { !$0.isEmpty } ?? "Photos", salience: 0)
    }

    /// "November 9 – 15", or "October 26 – November 1" across months.
    private func weekTitle(_ start: Date) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start)!
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        return Self.formatter("MMMM d").string(from: start) + " – " + Self.formatter(sameMonth ? "d" : "MMMM d").string(from: end)
    }

    private func applyTheme() {
        let theme = chat.theme
        goo.setMaterial(theme, gradient: chat.wallpaperView.dimmedGradientImage)
        incomingColor = GooView.vector(theme.incoming.fill[0])
        outgoingColor = GooView.vector(theme.outgoing.fill[0])
        let sheetColor: UIColor = theme.isDark ? .black : .white // list.plainBackgroundColor
        calendarBackground.backgroundColor = sheetColor
        calendarChrome.apply(theme)
        // Dark enough to stay readable over the days it floats above (the chat's floating date has its own fill too).
        floatingWeek.tint = theme.isDark ? UIColor(rgb: 0x1f1f1f, alpha: 0.6) : UIColor(white: 0, alpha: 0.28)
        floatingWeekLabel.textColor = theme.serviceText

        calendarTopEdge.colors = [sheetColor.cgColor, sheetColor.cgColor, sheetColor.withAlphaComponent(0).cgColor]
        calendarTopEdge.locations = [0, 0.75, 1]
        calendarBottomEdge.colors = [sheetColor.withAlphaComponent(0).cgColor, sheetColor.cgColor]
        for label in weekLabels + pillLabels { label.textColor = theme.serviceText }
        numberLabels.forEach { $0.textColor = .white }
        // The widest an incoming bubble gets next to an avatar.
        let maxBodyWidth = Metrics.maxBubbleWidth(for: bounds.width) - Self.avatarInset - Metrics.tailWidth
        for (k, view) in bubbleViews.enumerated() {
            view.configure(name: dayName(days[k].date), summary: summary(k), count: days[k].messages.count, photos: dayPhotos[k],
                           notable: isNotable(k), maxBodyWidth: maxBodyWidth, theme: theme)
        }
        if let first = days.first {
            calendarView.build(first: first.date, days: Set(days.map(\.date)), width: bounds.width, calendar: calendar, theme: theme)
        }
        computeLayouts()
    }

    private static var formatters: [String: DateFormatter] = [:]
    private static func formatter(_ format: String) -> DateFormatter {
        if let cached = formatters[format] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = format
        formatters[format] = formatter
        return formatter
    }

    func dayIndex(daysAgo: Int) -> Int? {
        guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) else { return nil }
        return days.firstIndex { $0.date == date }
    }

    // MARK: Layouts (content coordinates)

    private func computeLayouts() {
        guard bubbleViews.count == days.count else { return }
        let width = bounds.width
        dayLayouts = Array(repeating: DayLayout(), count: days.count)
        weekPills = []
        var y: CGFloat = 0
        for (w, week) in weeks.enumerated() {
            // The week's pill sits where a date header would (ChatMessageDateHeader: 34pt block, 22pt pill).
            let pillWidth = ceil(weekLabels[w].bounds.width) + 6 * 2 + 2
            weekPills.append(CGRect(x: floor((width - pillWidth) / 2), y: y + floor((Self.pillBlock - Metrics.datePillHeight) / 2),
                                    width: pillWidth, height: Metrics.datePillHeight))
            y += Self.pillBlock
            for k in week.days {
                let size = bubbleViews[k].bubbleSize
                let bubble = CGRect(x: Metrics.bubbleEdgeInset + Self.avatarInset, y: y, width: size.width, height: size.height)
                let body = CGRect(x: bubble.minX + Metrics.tailWidth, y: y, width: size.width - Metrics.tailWidth, height: size.height)
                let avatar = CGRect(x: Self.avatarLeft, y: bubble.maxY - Self.avatarSize, width: Self.avatarSize, height: Self.avatarSize)
                dayLayouts[k] = DayLayout(bubble: bubble, body: body, avatar: avatar)
                y = bubble.maxY + Self.daySpacing
            }
            y += 2
        }
        daysHeight = y
        circles = days.map { calendarView.circles[$0.date] ?? .zero }
    }

    private var topInset: CGFloat { chat.headerView.frame.maxY + 8 }
    /// Where content starts at each level: the days leave room for the floating week under the header, the calendar
    /// for its first month's title to clear the sheet's top edge.
    private func topInset(_ level: Int) -> CGFloat { chat.headerView.frame.maxY + (level == 2 ? 24 : 6) }

    private func contentHeight(_ level: Int) -> CGFloat { level == 1 ? daysHeight : calendarView.height }
    /// With the input panel gone, the days and the calendar run down to the home indicator.
    private func bottomInset(_ level: Int) -> CGFloat { safeAreaInsets.bottom + (level == 2 ? 16 : 10) }

    /// Allowed offsets. Content shorter than the screen sits at the bottom, like the chat (recent days near the thumb).
    private func offsetRange(_ level: Int) -> ClosedRange<CGFloat> {
        let height = contentHeight(level)
        let bottom = bottomInset(level)
        if height <= bounds.height - topInset(level) - bottom {
            let offset = height - (bounds.height - bottom)
            return offset...offset
        }
        return -topInset(level)...(height - bounds.height + bottom)
    }

    private func clampOffset(_ level: Int, _ offset: CGFloat) -> CGFloat {
        let range = offsetRange(level)
        return min(max(offset, range.lowerBound), range.upperBound)
    }

    // MARK: Screen geometry

    private func onScreen1(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: -offsets[1]) }
    private func circle(_ k: Int) -> CGRect { circles[k].offsetBy(dx: 0, dy: -offsets[2]) }

    /// A view of the chat's content where it is on screen, ignoring any transform we gave it.
    private func naturalFrame(_ view: UIView) -> CGRect {
        let offset = chat.scrollView.contentOffset
        return CGRect(x: view.center.x - view.bounds.width / 2 - offset.x, y: view.center.y - view.bounds.height / 2 - offset.y,
                      width: view.bounds.width, height: view.bounds.height)
    }

    /// The chat's date pill of day `k`, on screen or not (the chat has one date header per day, in order).
    private func chatPill(_ k: Int) -> CGRect? {
        guard k < chat.dateHeaderViews.count, let pill = chat.dateHeaderViews[k].label.superview else { return nil }
        let header = naturalFrame(chat.dateHeaderViews[k])
        return pill.frame.offsetBy(dx: header.minX, dy: header.minY)
    }

    /// Day `k` in the chat's content: from its date header to its last bubble.
    private func chatSpan(_ k: Int) -> ClosedRange<CGFloat> {
        if let span = daySpans[k] { return span }
        let top = k < chat.dateHeaderViews.count ? chat.dateHeaderViews[k].frame.minY : 0
        let last = chat.messageViews[days[k].messages.last!]
        return top...(last.center.y + last.bounds.height / 2)
    }

    // MARK: Anchoring

    /// The point being zoomed: which day it is in, and where inside it (0 = top, 1 = bottom).
    private struct Anchor {
        var day: Int
        var inDay: CGFloat
    }

    private func anchor(at point: CGPoint, level: Int) -> Anchor {
        switch level {
        case 0:
            var best = (k: days.count - 1, distance: CGFloat.infinity)
            for k in days.indices {
                let span = chatSpan(k)
                let top = span.lowerBound - chat.scrollView.contentOffset.y, bottom = span.upperBound - chat.scrollView.contentOffset.y
                let distance = point.y < top ? top - point.y : max(0, point.y - bottom)
                if distance < best.distance { best = (k, distance) }
            }
            let span = chatSpan(best.k)
            return Anchor(day: best.k, inDay: clamp01((point.y + chat.scrollView.contentOffset.y - span.lowerBound) / (span.upperBound - span.lowerBound)))
        case 1:
            let y = point.y + offsets[1]
            let k = days.indices.min { distance(y, block($0)) < distance(y, block($1)) } ?? 0
            let block = block(k)
            return Anchor(day: k, inDay: clamp01((y - block.lowerBound) / (block.upperBound - block.lowerBound)))
        default:
            let k = days.indices.min { hypot(circle($0).midX - point.x, circle($0).midY - point.y) < hypot(circle($1).midX - point.x, circle($1).midY - point.y) } ?? 0
            return Anchor(day: k, inDay: 0.5)
        }
    }

    /// Day `k`'s row at the days level, in content coordinates.
    private func block(_ k: Int) -> ClosedRange<CGFloat> { dayLayouts[k].bubble.minY...dayLayouts[k].bubble.maxY }

    private func distance(_ y: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        y < range.lowerBound ? range.lowerBound - y : max(0, y - range.upperBound)
    }

    /// Scrolls every level other than `level` so the anchor sits at `focal.y`, and remembers what will move.
    private func prepare(_ anchor: Anchor, focalY: CGFloat, from level: Int, chatAtTop: Bool = false) {
        if level != 1 {
            let block = block(anchor.day)
            offsets[1] = clampOffset(1, block.lowerBound + anchor.inDay * (block.upperBound - block.lowerBound) - focalY)
        }
        if level != 2 {
            offsets[2] = clampOffset(2, circles[anchor.day].midY - focalY)
        }
        if level != 0 {
            let scrollView = chat.scrollView
            let span = chatSpan(anchor.day)
            let target = chatAtTop
                ? span.lowerBound - (chat.headerView.frame.maxY + 4)
                : span.lowerBound + anchor.inDay * (span.upperBound - span.lowerBound) - focalY
            let minOffset = -scrollView.contentInset.top
            let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset.y = min(max(target, minOffset), maxOffset)
        }
        for i in animatedMessages {
            chat.messageViews[i].transform = .identity
            chat.messageViews[i].alpha = 1
            chat.messageViews[i].layer.allowsGroupOpacity = true
        }
        animatedMessages = chat.messageViews.indices.filter { naturalFrame(chat.messageViews[$0]).intersects(bounds) }
        // A fading bubble doesn't need an offscreen pass per frame: its parts can fade on their own.
        for i in animatedMessages { chat.messageViews[i].layer.allowsGroupOpacity = false }
        daySpans = [:]
        for k in Set(animatedMessages.map { messageDay[$0] }) { daySpans[k] = chatSpan(k) }
        slices = [:]
        for messages in Dictionary(grouping: animatedMessages, by: { messageDay[$0] }).values {
            for (index, i) in messages.sorted().enumerated() { slices[i] = (index, messages.count) }
        }
    }

    // MARK: Transitions

    /// Builds the views ahead of the first pinch, so the zoom starts on the first frame.
    func prewarm() {
        setupForZoom()
        render()
        goo.warmUp()
    }

    private func setupForZoom() {
        let rebuilt = builtForCount != chat.messageViews.count
        rebuildIfNeeded()
        if rebuilt || dayLayouts.count != days.count { applyTheme() }
    }

    private func beginTransition() {
        spring.stop()
        if restLevel == 0 {
            restingSubtitle = (chat.headerView.subtitleLabel.text, chat.headerView.subtitleLabel.textColor)
            if chat.topEdgeOverride == nil { restingEdges = (chat.topEdgeView.frame, chat.bottomEdgeView.frame) }
        }
        restLevel = -1
        isUserInteractionEnabled = true
        scroller.isScrollEnabled = false
        chat.scrollView.isScrollEnabled = false
        chat.inputPanel.isUserInteractionEnabled = false
        chat.view.endEditing(true)
        haptic.prepare()
    }

    private func settle(at level: Int) {
        zoom = CGFloat(level)
        render()
        restLevel = level
        let interactive = level > 0
        isUserInteractionEnabled = interactive
        chat.scrollView.isScrollEnabled = !interactive
        chat.inputPanel.isUserInteractionEnabled = !interactive
        scroller.isHidden = !interactive
        scroller.isScrollEnabled = interactive
        guard interactive else { return }
        isAdjustingScroller = true
        let range = offsetRange(level)
        scroller.contentInset = UIEdgeInsets(top: -range.lowerBound, left: 0, bottom: bottomInset(level), right: 0)
        scroller.verticalScrollIndicatorInsets = UIEdgeInsets(top: topInset(level), left: 0, bottom: bottomInset(level), right: 0)
        scroller.contentSize = CGSize(width: bounds.width, height: contentHeight(level))
        scroller.contentOffset = CGPoint(x: 0, y: offsets[level])
        isAdjustingScroller = false
    }

    /// After a pinch: a touch of overshoot. Without a gesture (taps, scenario playback): critically damped and slower.
    private func animate(to level: Int, velocity: CGFloat, response: CGFloat = 0.55, dampingRatio: CGFloat = 0.85,
                         completion: (() -> Void)? = nil) {
        spring.animate(from: zoom, to: CGFloat(level), velocity: velocity, response: response, dampingRatio: dampingRatio) { [weak self] in
            self?.settle(at: level)
            completion?()
        }
    }

    private func start(at point: CGPoint) {
        setupForZoom()
        if restLevel > 0 { offsets[restLevel] = scroller.contentOffset.y }
        prepare(anchor(at: point, level: restLevel), focalY: point.y, from: restLevel)
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            if !spring.isRunning, restLevel >= 0 { start(at: gesture.location(in: self)) }
            beginTransition()
            pinchStartZoom = zoom
        case .changed:
            let raw = pinchStartZoom - log2(max(gesture.scale, 0.01)) * Self.pinchGain
            zoom = Self.rubberBand(raw)
            render()
        case .ended, .cancelled, .failed:
            let velocity = -gesture.velocity / max(gesture.scale, 0.01) / log(2) * Self.pinchGain
            let projected = zoom + velocity * 0.15
            animate(to: Int(min(2, max(0, projected.rounded()))), velocity: velocity)
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if restLevel == 1 {
            let y = point.y + offsets[1]
            // A week's pill, in the list or stuck under the header (with a finger-sized target around it).
            let onPill = (!floatingWeek.isHidden && floatingWeek.frame.insetBy(dx: -12, dy: -10).contains(point))
                || weekPills.contains { onScreen1($0).insetBy(dx: -12, dy: -8).contains(point) }
            if onPill {
                openCalendar(at: point)
            } else if let k = days.indices.first(where: { block($0).contains(y) }) { open(day: k) }
        } else if restLevel == 2, let k = days.indices.first(where: { circle($0).insetBy(dx: -3, dy: -3).contains(point) }) {
            openChat(atDay: k)
        }
    }

    /// From the days: the chat expands out of day `k`, starting at the top of that day.
    func open(day k: Int, completion: (() -> Void)? = nil) {
        guard restLevel == 1 else { return }
        offsets[1] = scroller.contentOffset.y
        prepare(Anchor(day: k, inDay: 0), focalY: onScreen1(dayLayouts[k].bubble).minY, from: 1, chatAtTop: true)
        beginTransition()
        animate(to: 0, velocity: 0, response: 0.9, dampingRatio: 1, completion: completion)
    }

    /// From the calendar into the chat at day `k`, as a day in Telegram's calendar does, in two steps: the circle
    /// opens into its day's row (a beat to read what the day was about), the row into its messages. Straight from 2
    /// to 0 the rows pass by empty and half-formed.
    func openChat(atDay k: Int, completion: (() -> Void)? = nil) {
        openWeek(ofDay: k) { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.7))
                self?.open(day: k, completion: completion)
            }
        }
    }

    /// The days (or the calendar) scrolled so day `k` sits at `fraction` of the screen's height, as a finger would
    /// scroll it (scenario playback).
    func scroll(toDay k: Int, at fraction: CGFloat = 0.45, duration: TimeInterval = 1.2) async {
        guard let target = offset(showingDay: k, at: fraction) else { return }
        await ScrollAnimator.run(scroller, to: target, duration: duration)
    }

    /// The days' (or the calendar's) scroll offset that puts day `k` at `fraction` of the screen's height.
    func offset(showingDay k: Int, at fraction: CGFloat) -> CGFloat? {
        guard restLevel > 0 else { return nil }
        let y = restLevel == 1 ? (block(k).lowerBound + block(k).upperBound) / 2 : circles[k].midY
        return clampOffset(restLevel, y - bounds.height * fraction)
    }

    /// The scroll view of the level at rest (days or calendar), for scenario playback.
    var levelScroller: UIScrollView { scroller }

    /// The point of day `k` on screen at the current level, for taps.
    func dayPoint(_ k: Int) -> CGPoint? {
        switch restLevel {
        case 1: let r = onScreen1(dayLayouts[k].bubble); return CGPoint(x: r.midX, y: r.midY)
        case 2: return CGPoint(x: circle(k).midX, y: circle(k).midY)
        default: return nil
        }
    }

    /// From the calendar: day `k`'s circle opens back into its service message, among the rest of its week.
    func openWeek(ofDay k: Int, completion: (() -> Void)? = nil) {
        guard restLevel == 2 else { return }
        offsets[2] = scroller.contentOffset.y
        let focal = min(max(circle(k).midY, topInset + 120), bounds.height - bottomInset(1) - 120)
        prepare(Anchor(day: k, inDay: 0.5), focalY: focal, from: 2)
        beginTransition()
        animate(to: 1, velocity: 0, response: 0.9, dampingRatio: 1, completion: completion)
    }

    /// One level out as two fingers would pinch it (scenario playback): `zoom` follows the fingers for `duration`, as
    /// handlePinch drives it, and they let go still moving, into the release spring of a real pinch. `fingers` gets the
    /// pinch scale on every frame; `released` is called as they lift.
    func pinchOut(at point: CGPoint, travel: CGFloat = 0.7, duration: TimeInterval = 0.5,
                  fingers: ((CGFloat) -> Void)? = nil, released: (() -> Void)? = nil) async {
        guard restLevel >= 0, restLevel < 2 else { return }
        let target = restLevel + 1
        start(at: point)
        beginTransition()
        let from = zoom
        await FrameDriver.run(duration: duration) { [self] t in
            // Half smoothstep, half linear: the fingers speed up, then lift at half their top speed.
            let e = 0.5 * t * t * (3 - 2 * t) + 0.5 * t
            zoom = Self.rubberBand(from + travel * e)
            render()
            fingers?(pow(2, -travel * e / Self.pinchGain))
        }
        released?()
        let velocity = 0.5 * travel / CGFloat(duration)
        await withCheckedContinuation { continuation in
            animate(to: target, velocity: velocity) { continuation.resume() }
        }
    }

    func circleCenter(day k: Int) -> CGPoint? {
        guard restLevel == 2 else { return nil }
        return CGPoint(x: circle(k).midX, y: circle(k).midY)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingScroller, restLevel > 0 else { return }
        offsets[restLevel] = scrollView.contentOffset.y
        render()
    }

    private static func rubberBand(_ z: CGFloat) -> CGFloat {
        let c: CGFloat = 0.15
        if z < 0 { return -c * (1 - exp(z / c)) }
        if z > 2 { return 2 + c * (1 - exp(-(z - 2) / c)) }
        return z
    }

    // MARK: Render

    private func updateLevelChrome() {
        let level = min(2, max(0, Int(zoom.rounded())))
        guard level != shownLevel else { return }
        shownLevel = level
        haptic.impactOccurred()
        let label = chat.headerView.subtitleLabel
        UIView.transition(with: label, duration: 0.2, options: .transitionCrossDissolve) {
            switch level {
            case 0:
                label.text = self.restingSubtitle.text
                label.textColor = self.restingSubtitle.color
            case 1:
                label.text = self.weeks.count == 1 ? "1 week" : "\(self.weeks.count) weeks"
                label.textColor = self.chat.theme.secondaryControlColor
            default:
                label.text = "Calendar"
                label.textColor = self.chat.theme.secondaryControlColor
            }
        }
    }

    func render() {
        guard !days.isEmpty, dayLayouts.count == days.count else { return }
        updateLevelChrome()
        let visible = bounds.insetBy(dx: -40, dy: -60)
        let a = clamp01(zoom)
        let b = clamp01(zoom - 1)
        let toDays = zoom <= 1
        var shapes: [GooShape] = []
        // How liquid things are: 0 at rest (shapes keep their edges), swelling mid-way.
        let swell = toDays ? sin(.pi * a) : sin(.pi * b)
        let groupK = 6 + 10 * swell
        let gooK = (toDays ? 4 : 8) * swell
        let weekGroup = 2 * days.count

        chat.inputPanel.alpha = 1 - smooth(0, 0.5, a)
        if chat.downButtonSuppressed != (zoom > 0) { chat.downButtonSuppressed = zoom > 0 }
        // Past the days level nothing of the chat may show (bubbles left over from an earlier zoom included).
        chat.scrollView.isHidden = zoom >= 1
        for header in chat.dateHeaderViews { header.alpha = a > 0 ? 0 : 1 }

        // The chat: every bubble slims down, travels to its slice of the day's bubble and merges there.
        for i in animatedMessages {
            let view = chat.messageViews[i]
            let k = messageDay[i]
            guard a > 0, zoom < 1, let slice = slices[i] else {
                view.transform = .identity
                view.alpha = 1
                continue
            }
            let frame = naturalFrame(view)
            let body = view.bodyFrame.offsetBy(dx: frame.minX, dy: frame.minY)
            let day = onScreen1(dayLayouts[k].body)
            // Its place in the day's bubble: the day's chat in miniature, squeezed to the bubble's size, so the
            // drops keep their sides and proportions on the way in.
            let height = day.height / CGFloat(slice.count)
            let width = max(height, day.width * body.width / bounds.width)
            let target = CGRect(x: view.message.isOutgoing ? day.maxX - width : day.minX, y: day.minY + CGFloat(slice.index) * height,
                                width: width, height: height)
            // They stay bubbles for most of the way and clump together, shrinking only as they arrive.
            let size = smooth(0.3, 0.95, a), t = ease(a)
            let center = CGPoint(x: lerp(body.midX, target.midX, t), y: lerp(body.midY, target.midY, t))
            let blobSize = CGSize(width: lerp(body.width, target.width, size), height: lerp(body.height, target.height, size))
            let blob = CGRect(x: center.x - blobSize.width / 2, y: center.y - blobSize.height / 2, width: blobSize.width, height: blobSize.height)
            // The bubble follows its drop and dissolves over it (the liquid layer is under the messages).
            let viewCenter = CGPoint(x: frame.midX, y: frame.midY)
            let sx = blob.width / body.width, sy = blob.height / body.height
            view.transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                               tx: blob.midX - viewCenter.x - sx * (body.midX - viewCenter.x),
                                               ty: blob.midY - viewCenter.y - sy * (body.midY - viewCenter.y))
            view.alpha = 1 - smooth(0.12, 0.5, a)
            if blob.intersects(visible) {
                let own = view.message.isOutgoing ? outgoingColor : incomingColor
                let mix = Float(smooth(0.2, 0.7, a))
                // Gone just before the real bubble settles on top, so no drop peeks out from behind its outline.
                let present = smooth(0, 0.08, a) * (1 - smooth(0.86, 0.94, a))
                shapes.append(GooShape(blob, radius: min(Metrics.maxCornerRadius, blob.height / 2), shrink: (1 - present) * blob.height / 2,
                                       group: 2 * k + 1, color: own + (incomingColor - own) * mix))
            }
        }

        // Weeks: date pills that grow in between the days. The week being scrolled through sticks under the header
        // and turns to glass there; the next week's pill pushes it out, as the chat's floating date does.
        let stickY = topInset(1)
        let stuck = zoom > 0 ? weeks.indices.last { onScreen1(weekPills[$0]).minY <= stickY } : nil
        let levelAlpha = toDays ? smooth(0.8, 1, a) : 1 - smooth(0, 0.3, b)
        var glassAlpha: CGFloat = 0
        for (w, label) in weekLabels.enumerated() {
            var pill = onScreen1(weekPills[w])
            var material: CGFloat = 1
            if w == stuck {
                let natural = pill.minY
                var y = stickY
                if w + 1 < weeks.count { y = min(y, onScreen1(weekPills[w + 1]).minY - pill.height - 6) }
                pill.origin.y = y
                glassAlpha = smooth(0, 8, stickY - natural) * levelAlpha
                material = 1 - glassAlpha
                floatingWeek.frame = pill
                floatingWeekLabel.frame = CGRect(origin: .zero, size: pill.size)
                floatingWeekLabel.text = label.text
            }
            let grown = toDays ? smooth(0.4, 0.9, a) : 1 - smooth(0, 0.35, b)
            let shown = zoom > 0 && grown > 0.001 && pill.intersects(visible)
            if shown, material > 0.01 {
                shapes.append(GooShape(pill, radius: Self.pillRadius, shrink: (1 - grown) * Self.pillRadius, group: weekGroup + w))
            }
            label.isHidden = !shown || material <= 0.01
            label.center = CGPoint(x: pill.midX, y: pill.midY)
            label.alpha = (toDays ? smooth(0.6, 1, a) : 1 - smooth(0, 0.25, b)) * material
        }
        floatingWeek.isHidden = glassAlpha <= 0.01
        floatingWeek.alpha = glassAlpha

        for k in days.indices {
            let layout = dayLayouts[k]
            let bubbleView = bubbleViews[k], number = numberLabels[k], pillLabel = pillLabels[k], avatarView = avatarViews[k]
            guard zoom > 0 else {
                [bubbleView, number, pillLabel].forEach { $0.isHidden = true }
                avatarView?.isHidden = true
                continue
            }
            let bubble = onScreen1(layout.bubble), body = onScreen1(layout.body)
            let restAvatar = onScreen1(layout.avatar)

            // Avatar. From the chat: the day's own date pill rounds up into it (a day whose pill is off screen just
            // grows in). To the calendar: it flies to the day's circle.
            var avatar = restAvatar
            var avatarShrink: CGFloat = 0
            var pillAlpha: CGFloat = 0
            if toDays {
                if daySpans[k] != nil, let pill = chatPill(k) {
                    avatar = lerp(pill, restAvatar, ease(a))
                    pillAlpha = 1 - smooth(0, 0.4, a)
                } else {
                    avatarShrink = (1 - smooth(0.3, 0.8, a)) * Self.avatarSize / 2
                }
            } else {
                avatar = lerp(restAvatar, circle(k), ease(b))
            }
            let avatarShown = avatar.intersects(visible) && avatarShrink < Self.avatarSize / 2
            if avatarShown {
                shapes.append(GooShape(avatar, radius: avatar.height / 2, shrink: avatarShrink, group: 2 * k))
            }
            if let avatarView {
                avatarView.isHidden = !avatarShown
                avatarView.place(avatar.insetBy(dx: avatarShrink, dy: avatarShrink))
                avatarView.alpha = toDays ? smooth(0.4, 0.9, a) : 1
            }
            number.isHidden = !avatarShown
            number.center = CGPoint(x: avatar.midX, y: avatar.midY)
            // In the calendar the day's own number (CalendarView.marked) takes over.
            number.alpha = toDays ? smooth(0.5, 1, a) : 1 - smooth(0.3, 0.7, b)
            pillLabel.isHidden = pillAlpha <= 0.001 || !avatar.intersects(visible)
            pillLabel.center = CGPoint(x: avatar.midX, y: avatar.midY)
            pillLabel.alpha = pillAlpha

            // Bubble. From the chat: the liquid forms its body, then the real bubble (tail, outline, text) settles on
            // top. To the calendar: it folds into the avatar.
            var bodyShape = body
            var bodyShrink: CGFloat = 0
            var backgroundAlpha: CGFloat = 1, contentAlpha: CGFloat = 1
            if toDays {
                let grown = daySpans[k] != nil ? smooth(0.5, 0.88, a) : smooth(0.3, 0.8, a)
                bodyShrink = (1 - grown) * body.height / 2
                backgroundAlpha = smooth(0.82, 0.95, a)
                contentAlpha = smooth(0.6, 1, a)
            } else {
                bodyShape = lerp(body, avatar, smooth(0, 0.6, b))
                bodyShrink = smooth(0.25, 0.6, b) * bodyShape.height / 2
                backgroundAlpha = 1 - smooth(0, 0.15, b)
                contentAlpha = 1 - smooth(0, 0.25, b)
            }
            // At rest the real bubble stands alone (its outline is a hair off the liquid's edge).
            if bodyShape.intersects(visible), bodyShrink < bodyShape.height / 2, backgroundAlpha < 1 {
                shapes.append(GooShape(bodyShape, radius: min(Metrics.maxCornerRadius, bodyShape.height / 2), shrink: bodyShrink,
                                       group: 2 * k + 1, color: incomingColor))
            }
            bubbleView.isHidden = !bubble.intersects(visible) || max(backgroundAlpha, contentAlpha) <= 0.001
            bubbleView.frame.origin = bubble.origin
            bubbleView.background.alpha = backgroundAlpha
            bubbleView.content.alpha = contentAlpha
        }
        // Group order matters for the shader (consecutive shapes of a group merge with groupK).
        shapes.sort { $0.group < $1.group }

        // The wallpaper's edge effects at the days level.
        if let edges = restingEdges {
            if zoom <= 0 {
                chat.topEdgeOverride = nil
                chat.bottomEdgeOverride = nil
            } else {
                let f = toDays ? ease(a) : 1
                let base: CGFloat = chat.theme.wallpaper.plainColor != nil ? 0.85 : 0.75
                // The top one keeps the chat's look and only reaches lower, past the floating week.
                var top = edges.top
                top.size.height += 28 * f
                chat.topEdgeOverride = .init(frame: top, fade: 80, alpha: base)
                // The bottom one belongs to the input panel: without it the days just run off the screen.
                chat.bottomEdgeOverride = .init(frame: edges.bottom, fade: 60, alpha: base * (1 - f))
            }
        }

        // The calendar: Telegram's sheet fades in under the circles.
        let sheet = smooth(0.15, 0.6, b)
        calendarBackground.alpha = sheet
        calendarBackground.isHidden = sheet <= 0
        chat.topEdgeView.alpha = 1 - sheet
        chat.bottomEdgeView.alpha = 1 - sheet
        calendarView.isHidden = b <= 0
        // The sheet brings its own navigation bar: the chat's header gives way to it.
        chat.headerView.alpha = 1 - smooth(0.15, 0.55, b)
        calendarChrome.isHidden = b <= 0
        calendarChrome.alpha = smooth(0.45, 0.85, b)
        if b > 0 {
            calendarChrome.frame = bounds
            calendarChrome.layout(row: chat.headerView.convert(chat.headerView.backButton.frame, to: chat.view), width: bounds.width)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        calendarTopEdge.opacity = Float(sheet)
        calendarBottomEdge.opacity = Float(sheet)
        CATransaction.commit()
        calendarView.frame = CGRect(x: 0, y: -offsets[2], width: bounds.width, height: calendarView.height)
        calendarView.plain.alpha = smooth(0.45, 1, b)
        calendarView.marked.alpha = smooth(0.6, 1, b)

        goo.draw(zoom > 0 ? shapes : [], groupK: groupK, gooK: gooK)
    }
}

private func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
private func smooth(_ from: CGFloat, _ to: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = clamp01((x - from) / (to - from))
    return t * t * (3 - 2 * t)
}
private func ease(_ t: CGFloat) -> CGFloat { smooth(0, 1, t) }
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

/// Calls `step` with linear progress 0...1 on every display frame for `duration` (scenario playback: driven per frame,
/// as a finger would drive it, so the motion is as smooth as the display).
@MainActor
final class FrameDriver: NSObject {
    private let duration: TimeInterval
    private let step: (CGFloat) -> Void
    private var start: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var done: CheckedContinuation<Void, Never>?

    private init(duration: TimeInterval, step: @escaping (CGFloat) -> Void) {
        self.duration = max(duration, 0.001)
        self.step = step
    }

    static func run(duration: TimeInterval, _ step: @escaping (CGFloat) -> Void) async {
        let driver = FrameDriver(duration: duration, step: step)
        await withCheckedContinuation { continuation in
            driver.done = continuation
            driver.start = CACurrentMediaTime()
            step(0)
            let link = CADisplayLink(target: driver, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            driver.link = link
        }
    }

    @objc private func tick() {
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        step(CGFloat(t))
        guard t >= 1 else { return }
        link?.invalidate()
        link = nil
        done?.resume()
        done = nil
    }
}

/// A scroll view's offset eased over `duration`, frame by frame (so its delegate sees every step, as with a finger).
/// `step` gets the eased progress, for a finger drawn along.
@MainActor
enum ScrollAnimator {
    static func run(_ scrollView: UIScrollView, to: CGFloat, duration: TimeInterval,
                    step: ((CGFloat) -> Void)? = nil) async {
        let from = scrollView.contentOffset.y
        await FrameDriver.run(duration: duration) { t in
            // Ease in-out with a long tail, like a drag that lets go.
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            scrollView.contentOffset.y = from + (to - from) * e
            step?(e)
        }
    }
}
