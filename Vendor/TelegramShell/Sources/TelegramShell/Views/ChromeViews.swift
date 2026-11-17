import UIKit

// MARK: - Date header

/// "Today" pill: 22pt capsule, 13pt medium white text over the wallpaper gradient at saturation 1.7 + black 0.2.
/// Source: submodules/TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift
public final class DateHeaderView: UIView {
    public let label = UILabel()
    private let pill = UIView()
    private let portalView = UIImageView()
    private let dimView = UIView()

    public init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        pill.clipsToBounds = true
        addSubview(pill)
        portalView.contentMode = .scaleToFill
        pill.addSubview(portalView)
        pill.addSubview(dimView)
        label.font = Metrics.datePillFont
        label.text = text
        label.textAlignment = .center
        pill.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: Theme, wallpaper: WallpaperView) {
        label.textColor = theme.serviceText
        dimView.backgroundColor = theme.serviceDim
        portalView.image = wallpaper.dimmedGradientImage
        if theme.wallpaper.intensity < 0 {
            portalView.image = nil
            pill.backgroundColor = UIColor(rgb: 0x1f1f1f) // Night service fill
        } else {
            pill.backgroundColor = .clear
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = ceil(label.intrinsicContentSize.width)
        let size = CGSize(width: textWidth + 6 * 2 + 2, height: Metrics.datePillHeight)
        pill.frame = CGRect(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height)
        pill.layer.cornerRadius = size.height / 2
        dimView.frame = pill.bounds
        label.frame = pill.bounds
    }

    /// Keeps the gradient "portal" aligned with the wallpaper while scrolling.
    func updatePortal(wallpaper: WallpaperView) {
        portalView.frame = pill.convert(wallpaper.bounds, from: wallpaper)
    }
}

// MARK: - Chat header (glass navigation bar)

/// Back button (glass circle), title capsule (name + status), avatar.
/// Sources: NavigationBarNode.swift (60pt bar, row at +2+8, 16pt side insets), NavigationBarComponent.swift (44pt back capsule),
///          ChatTitleComponent.swift (44pt capsule, semibold 17 / regular 12, +28 width), ChatAvatarNavigationNode.swift (38pt avatar).
public final class ChatHeaderView: UIView {
    public let backButton: GlassButton
    public let titleCapsule: GlassView
    public let titleLabel = UILabel()
    public let subtitleLabel = UILabel()
    public let avatarView: AvatarView
    public var onBack: (() -> Void)?

    public private(set) var peer: DemoPeer

    public init(peer: DemoPeer) {
        self.peer = peer
        backButton = GlassButton(icon: Graphics.backChevron)
        titleCapsule = GlassView(interactive: true)
        avatarView = AvatarView(peer: peer)
        super.init(frame: .zero)
        addSubview(backButton)
        addSubview(titleCapsule)
        titleLabel.font = Metrics.titleFont
        titleLabel.textAlignment = .center
        subtitleLabel.font = Metrics.subtitleFont
        subtitleLabel.textAlignment = .center
        titleCapsule.contentView.addSubview(titleLabel)
        titleCapsule.contentView.addSubview(subtitleLabel)
        addSubview(avatarView)
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        titleLabel.text = peer.name
        subtitleLabel.text = peer.status
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        backButton.glass.tint = theme.glassTint
        backButton.iconView.tintColor = theme.controlColor
        titleCapsule.tint = theme.glassTint
        titleLabel.textColor = theme.controlColor
        subtitleLabel.textColor = peer.status == "online" ? theme.onlineColor : theme.secondaryControlColor
    }

    /// Height of the bar below the status bar.
    public static let barHeight: CGFloat = 60

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: safeAreaInsets.top + Self.barHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let rowY = safeAreaInsets.top + Metrics.navTopOffset
        let h = Metrics.navRowHeight
        let side = Metrics.navSideInset + safeAreaInsets.left
        backButton.frame = CGRect(x: side, y: rowY, width: h, height: h)
        avatarView.frame = CGRect(x: bounds.width - side - h + 3, y: rowY + 3, width: Metrics.navAvatarSize, height: Metrics.navAvatarSize)

        let titleSize = titleLabel.intrinsicContentSize
        let subtitleSize = subtitleLabel.intrinsicContentSize
        let maxContent = bounds.width - 2 * (side + h + 8) - 28
        let content = min(maxContent, max(ceil(max(titleSize.width, subtitleSize.width)), 150 - 28))
        let capsuleWidth = content + 28
        titleCapsule.frame = CGRect(x: floor((bounds.width - capsuleWidth) / 2), y: rowY, width: capsuleWidth, height: h)
        let textHeight = titleSize.height + subtitleSize.height
        let top = floor((h - textHeight) / 2)
        titleLabel.frame = CGRect(x: 14, y: top, width: content, height: titleSize.height)
        subtitleLabel.frame = CGRect(x: 14, y: titleLabel.frame.maxY, width: content, height: subtitleSize.height)
    }

    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.frame.contains(point) }
    }
}

// MARK: - Input panel

/// Glass composer: attach circle, text capsule with the sticker icon, mic circle that turns into Send when there is text.
/// Sources: ChatTextInputPanelNode.swift (40pt field, radius 20, 8pt side insets, 40 + 6 attach), ChatTextInputActionButtonsNode.swift
///          (40pt action button, send capsule inset by 3), PresentationResourcesChat.chatInputPanelSendIconImage.
public final class InputPanelView: UIView, UITextViewDelegate {
    public let attachButton: GlassButton
    public let fieldView: GlassView
    public let textView = UITextView()
    public let placeholderLabel = UILabel()
    public let stickerButton = UIButton(type: .custom)
    public let micButton: GlassButton
    public let sendButton = UIButton(type: .custom)
    private let sendCircle = UIView()
    private let sendIconView = UIImageView(image: Graphics.asset("TGSendIcon"))

    /// Called with the trimmed text when Send is tapped. The panel clears itself afterwards.
    public var onSend: ((String) -> Void)?
    /// Called when the text changes (after the panel relayouts).
    public var onTextChange: ((String) -> Void)?
    /// Called when the panel's height changes.
    var onHeightChange: (() -> Void)?

    public var maxLines = 6

    public init() {
        attachButton = GlassButton(icon: Graphics.asset("TGIconAttachment"))
        fieldView = GlassView(interactive: true)
        micButton = GlassButton(icon: Graphics.asset("TGIconMicrophone"))
        super.init(frame: .zero)
        addSubview(attachButton)
        addSubview(fieldView)
        addSubview(micButton)
        addSubview(sendButton)

        textView.backgroundColor = .clear
        textView.font = Metrics.inputFont
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        fieldView.contentView.addSubview(textView)
        placeholderLabel.text = "Message"
        placeholderLabel.font = Metrics.inputFont
        fieldView.contentView.addSubview(placeholderLabel)
        stickerButton.setImage(Graphics.asset("TGAccessoryIconStickers"), for: .normal)
        fieldView.contentView.addSubview(stickerButton)

        sendCircle.isUserInteractionEnabled = false
        sendButton.addSubview(sendCircle)
        sendIconView.contentMode = .center
        sendCircle.addSubview(sendIconView)
        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .touchUpInside)
        updateSendState(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        for button in [attachButton, micButton] {
            button.glass.tint = theme.glassTint
            button.iconView.tintColor = theme.controlColor
        }
        fieldView.tint = theme.glassTint
        textView.textColor = theme.inputText
        textView.tintColor = theme.accent == .white ? UIColor(rgb: 0x0088ff) : theme.accent
        placeholderLabel.textColor = theme.inputPlaceholder
        stickerButton.tintColor = theme.inputControl
        sendCircle.backgroundColor = theme.sendFill
        sendIconView.tintColor = theme.sendIcon
    }

    public var text: String {
        get { textView.text }
        set { textView.text = newValue; textViewDidChange(textView) }
    }

    private var hasText: Bool { !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sendTapped() {
        let value = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSend?(value)
        text = ""
    }

    public func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateSendState(animated: true)
        let old = fieldHeight
        setNeedsLayout()
        layoutIfNeeded()
        if fieldHeight != old { onHeightChange?() }
        onTextChange?(textView.text)
    }

    private func updateSendState(animated: Bool) {
        let showSend = hasText
        let changes = {
            self.sendButton.alpha = showSend ? 1 : 0
            self.sendButton.transform = showSend ? .identity : CGAffineTransform(scaleX: 0.3, y: 0.3)
            self.micButton.alpha = showSend ? 0 : 1
            self.micButton.transform = showSend ? CGAffineTransform(scaleX: 0.3, y: 0.3) : .identity
        }
        sendButton.isUserInteractionEnabled = showSend
        if animated {
            UIView.animate(springDuration: 0.3, bounce: 0.2, animations: changes)
        } else {
            changes()
        }
    }

    // Layout

    private var fieldHeight: CGFloat {
        let lineHeight = Metrics.inputFont.lineHeight
        let width = max(1, fieldView.bounds.width - 12 - 36)
        let textHeight = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maxHeight = lineHeight * CGFloat(maxLines) + 20
        return min(maxHeight, max(Metrics.inputHeight, ceil(textHeight)))
    }

    /// Height of the panel itself (the controls), without the bottom gap.
    public var panelHeight: CGFloat { fieldHeight }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: panelHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let side = Metrics.inputSideInset + safeAreaInsets.left
        let button = Metrics.inputHeight
        let fieldX = side + button + Metrics.inputButtonGap
        let fieldWidth = bounds.width - fieldX - Metrics.inputButtonGap - button - side
        fieldView.frame.size.width = fieldWidth
        let height = fieldHeight
        fieldView.frame = CGRect(x: fieldX, y: bounds.height - height, width: fieldWidth, height: height)
        attachButton.frame = CGRect(x: side, y: bounds.height - button, width: button, height: button)
        let right = CGRect(x: bounds.width - side - button, y: bounds.height - button, width: button, height: button)
        micButton.bounds = CGRect(origin: .zero, size: right.size)
        micButton.center = CGPoint(x: right.midX, y: right.midY)
        sendButton.bounds = CGRect(origin: .zero, size: right.size)
        sendButton.center = CGPoint(x: right.midX, y: right.midY)
        sendCircle.frame = sendButton.bounds.insetBy(dx: 3, dy: 3)
        sendCircle.layer.cornerRadius = sendCircle.bounds.height / 2
        sendIconView.frame = sendCircle.bounds

        let stickerSize: CGFloat = 36
        stickerButton.frame = CGRect(x: fieldWidth - stickerSize - 4, y: height - stickerSize - 2, width: stickerSize, height: stickerSize)
        let textInset = (Metrics.inputHeight - Metrics.inputFont.lineHeight) / 2
        textView.textContainerInset = UIEdgeInsets(top: textInset, left: 0, bottom: textInset, right: 0)
        textView.isScrollEnabled = height >= Metrics.inputFont.lineHeight * CGFloat(maxLines)
        textView.frame = CGRect(x: 12, y: 0, width: fieldWidth - 12 - stickerSize - 4, height: height)
        placeholderLabel.frame = CGRect(x: 12, y: textInset, width: textView.frame.width, height: Metrics.inputFont.lineHeight)
    }
}
