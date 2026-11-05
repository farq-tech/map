import Contacts
import ContactsUI
import SwiftUI

/// One person from the leader's contacts: the name as saved («فهد أخوي») and the number.
struct PickedContact: Equatable {
    var name: String
    var phone: String?
}

/// The system contact picker (`CNContactPickerViewController`). It runs out of
/// process and hands back only the person tapped, so the app needs NO Contacts
/// permission and never sees the address book.
///
/// DEBUG `-SaryStubContact "فهد أخوي|0501234567"` returns that contact at once
/// (UI tests cannot drive the out-of-process picker).
struct ContactPicker: UIViewControllerRepresentable {
    var picked: (PickedContact?) -> Void

    static var stub: PickedContact? {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryStubContact"), i + 1 < a.count {
            let parts = a[i + 1].split(separator: "|", maxSplits: 1).map(String.init)
            return PickedContact(name: parts.first ?? "", phone: parts.count > 1 ? parts[1] : nil)
        }
        #endif
        return nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        /* People without a number can still be picked (shared through the share sheet). */
        return vc
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let picked: (PickedContact?) -> Void
        init(picked: @escaping (PickedContact?) -> Void) { self.picked = picked }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { picked(nil) }

        /// A whole contact: its mobile first, else its first number.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let numbers = contact.phoneNumbers
            let mobile = numbers.first { $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone } ?? numbers.first
            picked(PickedContact(name: Self.name(contact), phone: mobile?.value.stringValue))
        }

        /// The person tapped one number on the card.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            let phone = (property.value as? CNPhoneNumber)?.stringValue
            picked(PickedContact(name: Self.name(property.contact), phone: phone))
        }

        static func name(_ c: CNContact) -> String {
            let full = CNContactFormatter.string(from: c, style: .fullName) ?? ""
            let n = full.isEmpty ? (c.nickname.isEmpty ? c.organizationName : c.nickname) : full
            return String(n.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ServerRules.nameMax))
        }
    }
}
