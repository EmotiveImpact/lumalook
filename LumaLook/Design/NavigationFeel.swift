import SwiftUI
import UIKit

/// LumaLook hides the system navigation bar on every screen (custom caps
/// headers), which as a side effect disables UIKit's interactive pop
/// gesture — the edge swipe-back every real iOS app has. Losing it is the
/// single loudest "this feels like a web view" signal.
///
/// Restoring it: become the pop gesture's delegate and allow it whenever
/// there is somewhere to pop back to. This is the long-standing community
/// pattern for custom-chrome apps.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldReceive touch: UITouch) -> Bool {
        viewControllers.count > 1
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // The edge swipe wins over horizontal scrollers (look strips,
        // timeline) near the screen edge — matches system apps.
        true
    }
}
