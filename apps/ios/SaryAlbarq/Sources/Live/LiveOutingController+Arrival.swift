import SwiftUI
import UIKit

/// The first seconds after an invite join (build 21, `InviteeArrival`): «نحدد موقعك…» until a good
/// fix, then the camera frames me, the live cars and the destination; a one-time welcome card;
/// «موقعك مو ظاهر للعيال» while my position does not reach the group. Nothing blocks the map,
/// the SOS dock, «تردد ١» or the voice notes.
extension LiveOutingController {
    func beginArrivalIfNeeded() {
        guard session.arrivedByInvite, !arrival.active else { return }
        session.arrivedByInvite = false
        var a = InviteeArrivalState()
        a.startedAt = Date()
        a.welcomePending = InviteeArrival.shouldWelcome(outing: session.id)
        arrival = a
        /* The GPS is already running from the join tap (the sheet warmed it); keep it on screen. */
        location.watchForeground()
        /* «نحدد موقعك…» gets its «جرّب مكان مكشوف» hint even if no fix ever comes. */
        DispatchQueue.main.asyncAfter(deadline: .now() + InviteeArrival.slowAfterS + 0.2) { [weak self] in self?.objectWillChange.send() }
        arrivalTick()
    }

    /// On every session / location change while arriving.
    func arrivalTick() {
        guard arrival.active else { return }
        let now = Date()
        /* The welcome waits for the trip's snapshot (name, members). */
        if arrival.welcomePending, session.displayView != nil {
            arrival.welcomePending = false
            arrival.welcomeUntil = now.addingTimeInterval(InviteeArrival.welcomeSeconds)
            InviteeArrival.markWelcomed(outing: session.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + InviteeArrival.welcomeSeconds + 0.1) { [weak self] in
                guard let self else { return }
                if let u = self.arrival.welcomeUntil, u <= Date() { self.arrival.welcomeUntil = nil }
            }
        }
        guard !arrival.located else { return }
        if locationHiddenFromGroup != nil {
            /* View mode: no fix of mine to wait for — frame the convoy and the destination once. */
            if !arrival.framedWithoutMe, session.displayView != nil {
                arrival.framedWithoutMe = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.frameArrival(me: nil) }
            }
            return
        }
        guard let f = location.lastFix, let start = arrival.startedAt else { return }
        let age = now.timeIntervalSince1970 - f.atMs / 1000
        guard InviteeArrival.isGoodFix(accuracyM: f.accuracy, ageS: age, sinceArrivalS: now.timeIntervalSince(start)) else { return }
        arrival.located = true
        frameArrival(me: LngLat(lng: f.lng, lat: f.lat))
    }

    /// Me (when located), every car shown live (never a stale one), and the destination.
    private func frameArrival(me: LngLat?) {
        var pts: [LngLat] = []
        if let me { pts.append(me) }
        pts += mapMembers(theme: .default).filter { !$0.isMe && $0.presence == .live }.map(\.position)
        if let d = tripDestination { pts.append(LngLat(lng: d.lng, lat: d.lat)) }
        guard !pts.isEmpty else { return }
        ask(pts.count == 1 ? .point(pts[0]) : .fit(pts))
    }

    /// «نحدد موقعك… الدقة ±٣٥ م» while arriving without a good fix; nil otherwise.
    var arrivalLocating: String? {
        guard let start = arrival.startedAt, !arrival.located, locationHiddenFromGroup == nil, location.canLocate,
              session.closedReason == nil else { return nil }
        let now = Date()
        let age = location.lastFix.map { now.timeIntervalSince1970 - $0.atMs / 1000 }
        return InviteeArrival.locatingText(accuracyM: location.lastFix?.accuracy, ageS: age, sinceArrivalS: now.timeIntervalSince(start))
    }

    /// The one-time welcome card, while it is up.
    var arrivalWelcome: String? {
        guard let until = arrival.welcomeUntil, until > Date(), let v = session.displayView else { return nil }
        let others = v.members.keys.filter { $0 != v.myId }.count
        return InviteeArrival.welcome(trip: v.snapshot.outing.name, destination: tripDestination?.name, others: others)
    }

    /// Refused / approximate while a member of a running trip: what is off («موقعك مو ظاهر للعيال»).
    var locationHiddenFromGroup: JoinPermission? {
        let p = JoinPermission.from(location.authorization, location.accuracyAuthorization)
        let over = session.closedReason != nil || session.view?.status == .ended
        return InviteeArrival.hidden(member: session.hasConsent, tripOver: over, permission: p)
    }

    /// «افتح الإعدادات» on the hidden-location pill. Approximate: iOS's precise prompt first.
    func fixHiddenLocation() {
        guard let p = locationHiddenFromGroup else { return }
        if p == .reduced {
            Task {
                let acc = await location.requestTemporaryFullAccuracy(purposeKey: LocationSharer.joinAccuracyPurposeKey)
                if acc == .reducedAccuracy { openAppSettings() }
                objectWillChange.send()
            }
        } else {
            openAppSettings()
        }
    }

    func dismissWelcome() { arrival.welcomeUntil = nil }
}

/// The arrival's three small things at the top of the map (under the trip header, above the alerts).
struct InviteeArrivalStack: View {
    @ObservedObject var controller: LiveOutingController
    @Environment(\.sary) private var theme

    var body: some View {
        let hidden = controller.locationHiddenFromGroup
        let locating = controller.arrivalLocating
        let welcome = controller.arrivalWelcome
        if hidden != nil || locating != nil || welcome != nil {
            VStack(spacing: theme.space(.s)) {
                if let welcome {
                    welcomeCard(welcome)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let hidden {
                    hiddenPill(hidden)
                        .transition(.opacity)
                } else if let locating {
                    locatingPill(locating)
                        .transition(.opacity)
                }
            }
            .animation(theme.animation(.smooth), value: welcome)
            .animation(theme.animation(.smooth), value: hidden)
            .animation(theme.animation(.smooth), value: locating == nil)
        }
    }

    private func welcomeCard(_ text: String) -> some View {
        let p = theme.palette
        return Button(action: controller.dismissWelcome) {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "hand.wave.fill").foregroundStyle(p.accentText).accessibilityHidden(true)
                Text(text)
                    .saryText(.callout, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.vertical, theme.space(.s) + 2)
            .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .chrome)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("arrival.welcome")
        .accessibilityLabel(Text(text))
    }

    private func locatingPill(_ text: String) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            ProgressView().controlSize(.small)
            Text(text).saryText(.subhead, weight: .medium).foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("arrival.locating")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .saryGlass(Capsule(), role: .chrome)
        .accessibilityElement(children: .combine)
    }

    private func hiddenPill(_ p: JoinPermission) -> some View {
        let pal = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Image(systemName: p == .reduced ? "location.circle" : "location.slash.fill")
                .foregroundStyle(pal.emergency)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(JoinCopy.hiddenTitle).saryText(.subhead, weight: .bold).foregroundStyle(pal.textPrimary)
                    .accessibilityIdentifier("arrival.hidden")
                Text(JoinCopy.hiddenDetail(p)).saryText(.footnote).foregroundStyle(pal.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: controller.fixHiddenLocation) {
                Text(p == .reduced ? "شغّل الدقيق" : JoinCopy.openSettings).saryText(.subhead, weight: .bold)
            }
            .buttonStyle(.sary(.secondary))
            .fixedSize()
            .accessibilityIdentifier("arrival.openSettings")
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .chrome)
    }
}
