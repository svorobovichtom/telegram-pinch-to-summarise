import UIKit
import TelegramShell

/// What a day was about. In Telegram this would come from a summarizer over the day's messages
/// (on device, like Apple's Foundation Models); the demo passes precomputed ones.
struct DaySummary {
    /// A short name for a day that stands out ("Boat trip"); nil for ordinary days.
    var title: String?
    /// What happened, in a sentence or three.
    var text: String
    /// How much the day stands out (a summarizer's own rating).
    var salience: Int = 5
}

/// Text laid out and drawn once (TextKit), so the bubble can be measured the way Telegram does it: the status goes
/// on the last line when it fits.
struct TextLayout {
    let image: UIImage
    let size: CGSize
    let lastLineWidth: CGFloat

    init(_ text: NSAttributedString, maxWidth: CGFloat) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        var last: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, usedRect, _, _, _ in
            last = usedRect.maxX
        }
        lastLineWidth = ceil(last)
        size = CGSize(width: ceil(used.maxX), height: ceil(used.maxY))
        image = UIGraphicsImageRenderer(size: size).image { _ in
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
        }
    }
}

/// A day at the days level, drawn as an incoming message in a group chat (ChatMessageBubbleItemNode): the bubble with
/// its tail, the "sender" (the weekday) in semibold 14, the summary in the message font, and a status in the corner
/// (how many messages the day had, where a message has its time). A day with photos shows them in a strip above the
/// text. Days that stand out get a bold lead and the accent color; ordinary days stay quiet.
final class DayBubbleView: UIView {
    let background = BubbleBackgroundView(incoming: true, position: .single)
    let content = UIView()
    private let nameLabel = UILabel()
    private let textView = UIImageView()
    private let statusLabel = UILabel()
    private var thumbnails: [UIView] = []
    /// The bubble's size, tail column included.
    private(set) var bubbleSize: CGSize = .zero

    static let nameFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    static let thumbnailSize: CGFloat = 62
    static let thumbnailSpacing: CGFloat = 3
    static let maxThumbnails = 4

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        nameLabel.font = Self.nameFont
        statusLabel.font = Metrics.dateFont
        [nameLabel, textView, statusLabel].forEach(content.addSubview)
        // Faded every frame of a transition: no offscreen pass needed, the parts don't overlap.
        content.layer.allowsGroupOpacity = false
        background.layer.allowsGroupOpacity = false
        addSubview(background)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The frame of the rounded body (without the tail column) in this view.
    var bodyFrame: CGRect { CGRect(x: Metrics.tailWidth, y: 0, width: bubbleSize.width - Metrics.tailWidth, height: bubbleSize.height) }

    func configure(name: String, summary: DaySummary, count: Int, photos: [UIImage], notable: Bool, maxBodyWidth: CGFloat, theme: Theme) {
        let bubble = theme.incoming
        background.apply(bubble)
        nameLabel.text = name
        nameLabel.textColor = notable ? bubble.accent : bubble.secondaryText
        statusLabel.text = count == 1 ? "1 message" : "\(count) messages"
        statusLabel.textColor = bubble.secondaryText

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = floor(Metrics.messageFont.pointSize * Metrics.lineSpacingFactor)
        let text = NSMutableAttributedString()
        if notable, let title = summary.title {
            text.append(NSAttributedString(string: title + ". ", attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: bubble.text, .paragraphStyle: paragraph,
            ]))
        }
        text.append(NSAttributedString(string: summary.text, attributes: [
            .font: Metrics.messageFont, .foregroundColor: bubble.text, .paragraphStyle: paragraph,
        ]))
        let insets = Metrics.textInsets
        let maxTextWidth = maxBodyWidth - insets.left - insets.right
        let layout = TextLayout(text, maxWidth: maxTextWidth)
        textView.image = layout.image

        let nameSize = nameLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 20))
        let statusSize = statusLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 20))
        // The status shares the last line when it fits next to it; otherwise it gets its own.
        let inline = layout.lastLineWidth + 10 + statusSize.width <= maxTextWidth
        // Photos: up to four thumbnails; with more, the last one says how many are left.
        thumbnails.forEach { $0.removeFromSuperview() }
        thumbnails = []
        let shown = min(photos.count, Self.maxThumbnails)
        for (n, photo) in photos.prefix(shown).enumerated() {
            let view = UIImageView(image: photo)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 8
            view.layer.cornerCurve = .continuous
            if n == shown - 1, photos.count > shown {
                let more = UILabel()
                more.text = "+\(photos.count - shown + 1)"
                more.font = .systemFont(ofSize: 17, weight: .semibold)
                more.textColor = .white
                more.textAlignment = .center
                more.backgroundColor = UIColor(white: 0, alpha: 0.45)
                more.frame = CGRect(x: 0, y: 0, width: Self.thumbnailSize, height: Self.thumbnailSize)
                view.addSubview(more)
            }
            content.addSubview(view)
            thumbnails.append(view)
        }
        let stripWidth = shown == 0 ? 0 : CGFloat(shown) * Self.thumbnailSize + CGFloat(shown - 1) * Self.thumbnailSpacing
        let stripHeight = shown == 0 ? 0 : Self.thumbnailSize + 5

        let contentWidth = max(ceil(nameSize.width), layout.size.width, stripWidth, inline ? layout.lastLineWidth + 10 + ceil(statusSize.width) : ceil(statusSize.width))
        let nameHeight: CGFloat = 17
        let stripTop = insets.top + nameHeight + 4
        let textTop = insets.top + nameHeight + 1 + (shown == 0 ? 0 : stripHeight + 3)
        let height = textTop + layout.size.height + (inline ? 0 : 13) + insets.bottom + 1
        bubbleSize = CGSize(width: Metrics.tailWidth + insets.left + contentWidth + insets.right, height: ceil(height))

        let left = Metrics.tailWidth + insets.left
        nameLabel.frame = CGRect(x: left, y: insets.top - 1, width: ceil(nameSize.width), height: nameHeight)
        for (n, view) in thumbnails.enumerated() {
            view.frame = CGRect(x: left + CGFloat(n) * (Self.thumbnailSize + Self.thumbnailSpacing), y: stripTop,
                                width: Self.thumbnailSize, height: Self.thumbnailSize)
        }
        textView.frame = CGRect(origin: CGPoint(x: left, y: textTop), size: layout.size)
        statusLabel.frame = CGRect(x: left + contentWidth - ceil(statusSize.width), y: bubbleSize.height - insets.bottom - ceil(statusSize.height) + 1,
                                   width: ceil(statusSize.width), height: ceil(statusSize.height))
        bounds.size = bubbleSize
        background.frame = CGRect(origin: .zero, size: bubbleSize)
        content.frame = background.frame
    }
}

/// The avatar of a day that has photos or stands out. With photos: the day's first photo under a 20% black
/// overlay, the way Telegram's calendar shows a day with media (CalendarMessageScreen, DayComponent). Otherwise
/// Telegram's letter-avatar gradient (AvatarNode `gradientColors`, blue). Ordinary days without photos get a circle
/// of the service material from the liquid layer instead.
final class AvatarCircle: UIView {
    private let imageView = UIImageView()
    private let overlay = UIView()
    private let gradient = CAGradientLayer()

    init(photo: UIImage?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        if let photo {
            imageView.image = photo
            imageView.contentMode = .scaleAspectFill
            overlay.backgroundColor = UIColor(white: 0, alpha: 0.2)
            addSubview(imageView)
            addSubview(overlay)
        } else {
            gradient.colors = AvatarView.gradientColors[5].map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer.addSublayer(gradient)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func place(_ frame: CGRect) {
        self.frame = frame
        layer.cornerRadius = min(frame.width, frame.height) / 2
        imageView.frame = bounds
        overlay.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

/// The calendar sheet's own navigation bar, as in Telegram (CalendarMessageScreen: MessageCalendar_Title, the close
/// button, Common_Select): a glass close button, the title, a glass "Select" capsule. It replaces the chat's header at
/// the calendar level. "Select" does nothing in the demo.
final class CalendarChromeView: UIView {
    let closeButton = GlassButton(icon: Graphics.asset("TGNavClose"))
    private let titleLabel = UILabel()
    private let selectGlass = GlassView(interactive: true)
    private let selectLabel = UILabel()
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = "Calendar"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        selectLabel.text = "Select"
        selectLabel.font = .systemFont(ofSize: 17, weight: .medium)
        selectLabel.textAlignment = .center
        selectGlass.isUserInteractionEnabled = false
        selectGlass.contentView.addSubview(selectLabel)
        [closeButton, titleLabel, selectGlass].forEach(addSubview)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        closeButton.glass.tint = theme.glassTint
        closeButton.iconView.tintColor = theme.controlColor
        selectGlass.tint = theme.glassTint
        titleLabel.textColor = theme.controlColor
        selectLabel.textColor = theme.controlColor
    }

    /// `row`: the chat header's button row (the back button's frame), so the bar sits exactly where the header was.
    func layout(row: CGRect, width: CGFloat) {
        closeButton.frame = row
        let selectWidth = ceil(selectLabel.intrinsicContentSize.width) + 2 * 16
        selectGlass.frame = CGRect(x: width - row.minX - selectWidth, y: row.minY, width: selectWidth, height: row.height)
        selectLabel.frame = CGRect(origin: .zero, size: selectGlass.frame.size)
        titleLabel.frame = CGRect(x: row.maxX + 8, y: row.minY, width: width - 2 * (row.maxX + 8), height: row.height)
    }

    /// Only the close button takes touches; everything else falls through to the calendar.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.5, closeButton.frame.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return closeButton
    }
}

/// Telegram's calendar sheet, laid out as CalendarMessageScreen.swift (MonthComponent) does it: months stacked with
/// 16pt between them, a semibold 17 title, regular 10 weekday letters 18pt below it, then rows of 46pt days 14pt below
/// those, 6pt apart, in 7 columns with 14pt side insets. Only labels: the circles of the days with messages are drawn by
/// the liquid layer, in the same material as the service messages they came from.
final class CalendarView: UIView {
    /// Titles, weekdays and the days without messages.
    let plain = UIView()
    /// Numbers of the days with messages (white on their circle, like a day with media in Telegram).
    let marked = UIView()
    private(set) var height: CGFloat = 0
    /// The circle of each day, by its start, in this view's coordinates.
    private(set) var circles: [Date: CGRect] = [:]
    private var builtWidth: CGFloat = 0

    static let sideInset: CGFloat = 14
    static let titleWeekdaysSpacing: CGFloat = 18
    static let weekdayDaySpacing: CGFloat = 14
    static let daySize: CGFloat = 46
    static let daySpacing: CGFloat = 6
    static let monthSpacing: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(plain)
        addSubview(marked)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        plain.frame = bounds
        marked.frame = bounds
    }

    /// Months from `first`'s to today's. `days`: the days with messages.
    func build(first: Date, days: Set<Date>, width: CGFloat, calendar: Calendar, theme: Theme) {
        plain.subviews.forEach { $0.removeFromSuperview() }
        marked.subviews.forEach { $0.removeFromSuperview() }
        circles = [:]
        builtWidth = width
        let today = calendar.startOfDay(for: Date())
        // DefaultDay/DarkPresentationTheme list colors.
        let primary: UIColor = theme.isDark ? .white : .black
        let disabled = theme.isDark ? UIColor(rgb: 0x8f8f8f) : UIColor(rgb: 0x8e8e93)
        let accent: UIColor = theme.isDark ? .white : theme.accent

        let weekdayWidth = floor((width - Self.sideInset * 2) / 7)
        let usableWidth = floor((width - Self.sideInset * 2 - Self.daySpacing * 6) / 7)
        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale(identifier: "en_US")
        titleFormatter.dateFormat = "MMMM yyyy" // Time.MonthOfYear_m*: "November %@"
        // Calendar.Short*, from Saturday (gridDayName's index 0).
        let letters = ["S", "S", "M", "T", "W", "T", "F"]

        var month = calendar.date(from: calendar.dateComponents([.year, .month], from: first))!
        var y: CGFloat = 0
        while month <= today {
            let title = label(titleFormatter.string(from: month), font: .systemFont(ofSize: 17, weight: .semibold), color: primary)
            title.frame.origin = CGPoint(x: floor((width - title.frame.width) / 2), y: y)
            plain.addSubview(title)
            let weekdayY = title.frame.maxY + Self.titleWeekdaysSpacing
            var maxWeekdayY = weekdayY
            for i in 0..<7 {
                let weekday = label(letters[(i + calendar.firstWeekday) % 7], font: .systemFont(ofSize: 10), color: primary)
                weekday.frame.origin = CGPoint(x: Self.sideInset + CGFloat(i) * weekdayWidth + floor((weekdayWidth - weekday.frame.width) / 2), y: weekdayY)
                maxWeekdayY = max(maxWeekdayY, weekday.frame.maxY)
                plain.addSubview(weekday)
            }
            let baseDayY = maxWeekdayY + Self.weekdayDaySpacing
            let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
            let count = calendar.range(of: .day, in: .month, for: month)!.count
            var maxDayY = baseDayY
            for i in 0..<count {
                let day = calendar.date(byAdding: .day, value: i, to: month)!
                let grid = offset + i
                let gridX = Self.sideInset + CGFloat(grid % 7) * weekdayWidth
                let gridY = baseDayY + CGFloat(grid / 7) * (Self.daySize + Self.daySpacing)
                let cell = CGRect(x: gridX + floor((weekdayWidth - usableWidth) / 2), y: gridY, width: usableWidth, height: Self.daySize)
                let diameter = min(cell.width, cell.height)
                let circle = CGRect(x: cell.midX - diameter / 2, y: cell.midY - diameter / 2, width: diameter, height: diameter)
                maxDayY = max(maxDayY, gridY + Self.daySize)
                let hasMessages = days.contains(day)
                let color: UIColor = hasMessages ? .white : day == today ? accent : day > today ? disabled : primary
                let weight: UIFont.Weight = hasMessages || day == today ? .semibold : .regular
                let number = label("\(i + 1)", font: .systemFont(ofSize: 17, weight: weight), color: color)
                number.frame.origin = CGPoint(x: floor(cell.midX - number.frame.width / 2), y: floor(cell.midY - number.frame.height / 2))
                if hasMessages {
                    circles[day] = circle
                    marked.addSubview(number)
                } else {
                    plain.addSubview(number)
                }
            }
            y = maxDayY + Self.monthSpacing
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        height = y - Self.monthSpacing
    }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.sizeToFit()
        label.frame.size = CGSize(width: ceil(label.frame.width), height: ceil(label.frame.height))
        return label
    }
}

/// Drives a value with a damped spring on the display link (UIView springs can't animate `render()`).
@MainActor
final class Spring: NSObject {
    var onChange: ((CGFloat) -> Void)?
    private var link: CADisplayLink?
    private var value: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var stiffness: CGFloat = 0
    private var damping: CGFloat = 0
    private var lastTime: CFTimeInterval = 0
    private var completion: (() -> Void)?

    var isRunning: Bool { link != nil }

    func animate(from: CGFloat, to: CGFloat, velocity: CGFloat, response: CGFloat, dampingRatio: CGFloat, completion: @escaping () -> Void) {
        stop()
        value = from
        target = to
        self.velocity = velocity
        let omega = 2 * .pi / response
        stiffness = omega * omega
        damping = 2 * dampingRatio * omega
        self.completion = completion
        lastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var remaining = min(now - lastTime, 1.0 / 30)
        lastTime = now
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            let acceleration = -stiffness * (value - target) - damping * velocity
            velocity += acceleration * h
            value += velocity * h
            remaining -= h
        }
        if abs(value - target) < 0.0005 && abs(velocity) < 0.005 {
            value = target
            onChange?(value)
            let done = completion
            stop()
            done?()
            return
        }
        onChange?(value)
    }
}
