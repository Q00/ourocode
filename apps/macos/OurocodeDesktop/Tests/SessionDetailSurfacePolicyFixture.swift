import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionDetailSurfacePolicyFixture {
    static func main() {
        require(SessionDetailSurfacePolicy.browsingRailWidth == 304, "rail width drifted")
        require(SessionDetailSurfacePolicy.preferredReadingWidth >= 420, "reading surface too narrow")
        require(SessionDetailSurfacePolicy.preferredReadingWidth <= 480, "reading surface too wide")
        require(
            SessionDetailSurfacePolicy.readingWidth(availableWindowWidth: 700) == 420,
            "compact window did not preserve terminal space"
        )
        require(
            SessionDetailSurfacePolicy.readingWidth(availableWindowWidth: 1_400) == 480,
            "wide window exceeded the reading cap"
        )
        require(
            abs(SessionDetailSurfacePolicy.readingWidth(availableWindowWidth: 1_018) - 448) < 0.5,
            "preferred reading width changed"
        )
        print("PASS: compact rail and adaptive 420–480pt session reading surface")
    }
}
