import Foundation

extension AppModel {
    /// «مساري» of an outing as a followable, measurable track (build 10): from its raw fixes
    /// when this phone has them (the most precise line), else from the stored trail. This
    /// device only; nothing here is sent. The filtering runs off the main thread.
    func trackSubject(_ id: String, name: String) async -> FollowSubject? {
        let demo = isDemo
        let trail = demo ? nil : myTrailPoints(id)
        return await Task.detached(priority: .userInitiated) {
            Self.trackSubject(id: id, name: name, trail: trail, demo: demo)
        }.value
    }

    nonisolated static func trackSubject(id: String, name: String, trail: Trail?, demo: Bool) -> FollowSubject? {
        if demo {
            #if DEBUG
            return DemoTrail.dunesSubject()
            #else
            return nil
            #endif
        }
        guard let t = trail, t.points.count >= 2 else { return nil }
        return FollowSubject.outing(id: id, name: name, trail: t, raw: TrailRawLog.load(id))
    }
}
