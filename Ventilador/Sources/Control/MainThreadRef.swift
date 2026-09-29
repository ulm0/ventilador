import Foundation

/// A weak reference that may be captured by `@Sendable` closures which are only ever delivered on the
/// main thread: `Timer`s scheduled on `RunLoop.main` and notifications observed with `queue: .main`.
/// Safe only under that contract; the compiler cannot see it, so this box states it in one place.
final class MainThreadRef<T: AnyObject>: @unchecked Sendable {
    private(set) weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}
