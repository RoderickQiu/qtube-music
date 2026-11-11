import CoreGraphics

/// How the Stage's Standard layout divides its width between the art column and the lyrics.
///
/// - Wide (1 000 pt of content and up): the two share the width almost evenly, a 72 pt gap between them.
/// - Narrower: the art column shrinks towards 30 % and the gap towards 44 pt, so the lyrics keep close to the width
///   they have on a wide Stage and lines don't wrap beside a large cover.
/// - Narrowest (under 640 pt, only the detached Stage window gets there): no art column; the lyrics take it all.
struct QTStageStandardSplit: Equatable {
    static let wideWidth: CGFloat = 1000
    static let artHiddenBelow: CGFloat = 640

    let showsArt: Bool
    let gap: CGFloat
    let artWidth: CGFloat
    let lyricsWidth: CGFloat

    init(width: CGFloat) {
        let width = max(width, 0)
        guard width >= Self.artHiddenBelow else {
            showsArt = false
            gap = 0
            artWidth = 0
            lyricsWidth = width
            return
        }
        // 0 at the narrowest Stage that still shows art, 1 from `wideWidth` up.
        let t = min(max((width - Self.artHiddenBelow) / (Self.wideWidth - Self.artHiddenBelow), 0), 1)
        let gap = 44 + (72 - 44) * t
        let share = 0.30 + (1 / 2.08 - 0.30) * t
        let art = max((width - gap) * share, 0)
        showsArt = true
        self.gap = gap
        artWidth = art
        lyricsWidth = max(width - gap - art, 0)
    }
}
