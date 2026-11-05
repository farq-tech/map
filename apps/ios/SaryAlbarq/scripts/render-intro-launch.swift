// Renders the static launch image (Assets.xcassets/IntroLaunch) from the intro's own
// drawing code, so the launch screen is exactly the intro's first frame.
//
//   swiftc -parse-as-library Sources/Intro/IntroScene.swift scripts/render-intro-launch.swift -o /tmp/render-intro-launch
//   /tmp/render-intro-launch Resources/Assets.xcassets/IntroLaunch.imageset
//   /tmp/render-intro-launch <dir> --frame 2.6     # any intro frame (for previews)
import AppKit
import SwiftUI

@main
struct RenderIntroLaunch {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let dir = args.count > 1 ? args[1] : "."
        var frame: Double?
        if let i = args.firstIndex(of: "--frame"), i + 1 < args.count { frame = Double(args[i + 1]) }
        for scale in [2, 3] {
            let view = Canvas { ctx, _ in
                if let frame { IntroScene.draw(ctx, t: frame, reduceMotion: false) } else { IntroScene.drawLaunchFrame(ctx) }
            }
            .frame(width: IntroScene.size.width, height: IntroScene.size.height)
            let r = ImageRenderer(content: view)
            r.scale = CGFloat(scale)
            r.isOpaque = true
            guard let cg = r.cgImage else { fatalError("render failed") }
            let rep = NSBitmapImageRep(cgImage: cg)
            let name = frame == nil ? "IntroLaunch@\(scale)x.png" : "IntroFrame-\(frame!)@\(scale)x.png"
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print(url.path, cg.width, "x", cg.height)
        }
    }
}
