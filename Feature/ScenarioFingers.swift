import UIKit

/// Fingers drawn over the window during scenario playback (`-touches`): the scenario touches nothing, and a screen
/// recording shows no touches anyway. Demo only, like the scenario.
@MainActor
final class ScenarioFingers: UIView {
    static let size: CGFloat = 44
    private var dots: [Int: UIView] = [:]

    init(window: UIWindow) {
        super.init(frame: window.bounds)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layer.zPosition = 10_000
        window.addSubview(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func down(_ id: Int = 0, at point: CGPoint) {
        dots.removeValue(forKey: id)?.removeFromSuperview()
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        dot.center = point
        dot.backgroundColor = UIColor(white: 1, alpha: 0.35)
        dot.layer.cornerRadius = Self.size / 2
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor(white: 1, alpha: 0.65).cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.25
        dot.layer.shadowRadius = 6
        dot.layer.shadowOffset = .zero
        dot.layer.shadowPath = UIBezierPath(ovalIn: dot.bounds).cgPath
        dot.alpha = 0
        dot.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        addSubview(dot)
        dots[id] = dot
        UIView.animate(withDuration: 0.12) {
            dot.alpha = 1
            dot.transform = .identity
        }
    }

    func move(_ id: Int = 0, to point: CGPoint) {
        dots[id]?.center = point
    }

    func up(_ id: Int = 0) {
        guard let dot = dots.removeValue(forKey: id) else { return }
        UIView.animate(withDuration: 0.2, animations: {
            dot.alpha = 0
            dot.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }, completion: { _ in dot.removeFromSuperview() })
    }

    /// Down, a beat, up; returns as the finger lifts, when a real tap's action fires.
    func tap(at point: CGPoint) async {
        down(at: point)
        try? await Task.sleep(for: .seconds(0.14))
        up()
    }
}
