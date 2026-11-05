import SwiftUI

/// The intro on screen: the night desert (`IntroScene`) in its fixed design space,
/// centred like the launch image, with the app's name fading in under the rising mark.
struct IntroOverlay: View {
    @ObservedObject var intro: IntroController

    var body: some View {
        Color(IntroScene.c(0x09070C))
            .overlay { stage.frame(width: IntroScene.size.width, height: IntroScene.size.height) }
            .ignoresSafeArea()
            .environment(\.layoutDirection, .leftToRight)
            .contentShape(Rectangle())
            .onTapGesture { intro.userSkip() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("سَرى البارق")
            .accessibilityHint("اضغط للتخطي")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { intro.userSkip() }
            .accessibilityIdentifier("intro")
    }

    @ViewBuilder private var stage: some View {
        if intro.mode == .full, intro.startedAt != nil || intro.freeze != nil {
            if intro.reduceMotion {
                /* Reduce Motion: the finished frame simply fades in over the launch frame. */
                ZStack {
                    launchFrame
                    IntroFrameView(t: IntroScene.T.total, reduceMotion: true).transition(.opacity)
                }
            } else {
                TimelineView(.animation(paused: intro.freeze != nil)) { tl in
                    IntroFrameView(t: intro.time(at: tl.date), reduceMotion: false)
                }
            }
        } else {
            launchFrame
        }
    }

    private var launchFrame: some View {
        Canvas { ctx, _ in IntroScene.drawLaunchFrame(ctx) }
    }
}

/// One frame: the drawn scene plus the name and tagline.
struct IntroFrameView: View {
    var t: Double
    var reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        let nameA = reduceMotion ? 1 : IntroScene.smooth(IntroScene.ramp(t, IntroScene.T.nameIn, IntroScene.T.nameIn + 0.7))
        let tagA = reduceMotion ? 1 : IntroScene.smooth(IntroScene.ramp(t, IntroScene.T.taglineIn, IntroScene.T.taglineIn + 0.6))
        ZStack(alignment: .top) {
            Canvas { ctx, _ in IntroScene.draw(ctx, t: t, reduceMotion: reduceMotion) }
            VStack(spacing: 10) {
                Text("سَرى البارق")
                    .font(.sary(44, .heavy, relativeTo: .largeTitle))
                    .foregroundStyle(IntroScene.c(IntroScene.ivory))
                    .shadow(color: IntroScene.c(IntroScene.gold, 0.55), radius: 14)
                    .opacity(nameA)
                    .offset(y: CGFloat(1 - nameA) * 10)
                Text("طلعات البر مع أصحابك")
                    .font(.sary(17, .medium, relativeTo: .callout))
                    .foregroundStyle(IntroScene.c(0xC9BBA4))
                    .opacity(tagA * 0.9)
            }
            .environment(\.layoutDirection, .rightToLeft)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .offset(y: IntroScene.logoRest.y + 62)
        }
        .opacity(reduceMotion ? (shown ? 1 : 0) : 1)
        .onAppear { if reduceMotion { withAnimation(.easeInOut(duration: 0.5)) { shown = true } } }
    }
}
