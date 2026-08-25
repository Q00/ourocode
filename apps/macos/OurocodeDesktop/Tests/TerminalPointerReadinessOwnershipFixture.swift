import Foundation

private final class SurfaceProbe {
  var onLockedInteraction: (() -> Void)?
}

private final class HostProbe {}

private final class WeakBox<Value: AnyObject> {
  weak var value: Value?
}

private let weakHost = WeakBox<HostProbe>()
private let weakSurface = WeakBox<SurfaceProbe>()

autoreleasepool {
  let host = HostProbe()
  let surface = SurfaceProbe()
  surface.onLockedInteraction = { [weak host, weak surface] in
    guard let host, let surface else { return }
    _ = (host, surface)
  }
  weakHost.value = host
  weakSurface.value = surface
}

precondition(weakHost.value == nil, "weak host capture retained the owner")
precondition(weakSurface.value == nil, "weak surface capture retained the surface")
print("PASS: pointer readiness callback does not retain host or surface")
