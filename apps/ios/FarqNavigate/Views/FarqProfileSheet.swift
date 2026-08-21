import PhotosUI
import SwiftUI

/// Choose the photo and the car.
///
/// Both are decoration over a position that the map already knew, which is why
/// this sheet says where the photo goes and where it does not: on this phone,
/// on this map, and nowhere else.
struct FarqProfileSheet: View {
    @ObservedObject var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @State private var picked: PhotosPickerItem?
    @State private var refused = false

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Farq.chipGround)
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text("سيارتك على الخريطة")
                .font(Farq.font(19, .extraBold))
                .foregroundStyle(Farq.ink)

            preview

            PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                Text(profile.isPersonalised ? "تغيير الصورة" : "اختر صورتك")
                    .font(Farq.font(15, .bold))
                    .foregroundStyle(Farq.brand900)
                    .frame(maxWidth: .infinity)
                    .frame(height: Farq.tapTarget)
                    .background(Farq.mint, in: Capsule())
            }

            if profile.isPersonalised {
                Button("إزالة الصورة") { profile.clearAvatar() }
                    .font(Farq.font(13, .medium))
                    .foregroundStyle(Color(hex: 0xB3202B))
            }

            colors

            Text("الصورة تبقى على جهازك — ما نرفعها ولا نرسلها مع أي طلب.")
                .font(Farq.font(12))
                .foregroundStyle(Farq.inkMuted)
                .multilineTextAlignment(.center)

            if refused {
                Text("ما قدرنا نقرأ هذي الصورة، جرّب وحدة ثانية.")
                    .font(Farq.font(12, .medium))
                    .foregroundStyle(Color(hex: 0xB3202B))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Color.white.ignoresSafeArea())
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    refused = true
                    return
                }
                refused = !profile.setAvatar(from: data)
            }
        }
    }

    /// Exactly what the map will draw, at the size the map draws it.
    private var preview: some View {
        ZStack {
            Image(uiImage: FarqVehicle.car(hex: profile.vehicleColor.hex))
                .resizable()
                .frame(width: 51, height: 111)
            if let avatar = profile.avatar {
                Image(uiImage: FarqVehicle.avatarPin(avatar))
                    .resizable()
                    .frame(width: 52, height: 66)
                    .offset(y: -66)
            }
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .background(Farq.surfaceInset, in: RoundedRectangle(cornerRadius: Farq.card))
    }

    private var colors: some View {
        HStack(spacing: 12) {
            ForEach(FarqVehicle.colors) { option in
                Button { profile.vehicleColorId = option.id } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: option.hex)))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Circle().stroke(
                                    profile.vehicleColorId == option.id
                                        ? Farq.mintStrong : Farq.chipGround,
                                    lineWidth: profile.vehicleColorId == option.id ? 3 : 1
                                )
                            )
                        Text(option.nameAr)
                            .font(Farq.font(12))
                            .foregroundStyle(Farq.inkSubtle)
                    }
                }
            }
        }
    }
}
