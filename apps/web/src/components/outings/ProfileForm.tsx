import { useState } from "react";
import { loadAvatar } from "../../lib/farqAvatar";
import { OutingApiError, OutingsApi, outingErrorText, type Identity } from "../../lib/outings/api";
import { RecoveryForm } from "./Recovery";

/**
 * The name (and, only if the person ticks it, the photo) that members of
 * their outings will see. There are no accounts: this creates a private token
 * kept on this device.
 */
export default function ProfileForm({ isRTL, onDone, submitLabel }: { isRTL: boolean; onDone: (id: Identity) => void; submitLabel?: string }) {
	const avatar = loadAvatar();
	const [name, setName] = useState("");
	const [sharePhoto, setSharePhoto] = useState(false);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [recovering, setRecovering] = useState(false);

	if (recovering) return <RecoveryForm isRTL={isRTL} onDone={onDone} onCancel={() => setRecovering(false)} />;

	return (
		<form
			className="sary-o-form"
			data-testid="outing-profile-form"
			onSubmit={async (e) => {
				e.preventDefault();
				setBusy(true);
				setError(null);
				try {
					onDone(await OutingsApi.createIdentity(name, sharePhoto ? avatar : null));
				} catch (err) {
					setError(outingErrorText(err instanceof OutingApiError ? err.code : "network", isRTL));
				} finally {
					setBusy(false);
				}
			}}
		>
			<label>
				<span>{isRTL ? "اسمك كما يظهر للعيال" : "Your name, as friends will see it"}</span>
				<input
					value={name}
					onChange={(e) => setName(e.target.value)}
					maxLength={40}
					required
					autoComplete="nickname"
					placeholder={isRTL ? "مثال: أبو فهد" : "e.g. Fahad"}
					data-testid="outing-name-input"
				/>
			</label>
			{avatar ? (
				<label className="sary-o-check">
					<input type="checkbox" checked={sharePhoto} onChange={(e) => setSharePhoto(e.target.checked)} />
					<img src={avatar} alt="" width={32} height={32} />
					<span>{isRTL ? "أظهر صورتي لأعضاء طلعاتي فقط" : "Show my photo to my outing members only"}</span>
				</label>
			) : null}
			<p className="sary-o-note">
				{isRTL
					? "بلا حساب ولا رقم جوال: نحفظ مفتاحًا خاصًا على هذا الجهاز فقط."
					: "No account, no phone number: a private key is kept on this device only."}
			</p>
			{error ? <p className="sary-o-error" role="alert">{error}</p> : null}
			<button type="submit" className="sary-o-primary" disabled={busy || !name.trim()} data-testid="outing-profile-submit">
				{busy ? "…" : submitLabel || (isRTL ? "متابعة" : "Continue")}
			</button>
			<button type="button" className="sary-o-link-btn" onClick={() => setRecovering(true)} data-testid="outing-recover-open">
				{isRTL ? "استخدمت سَرى من قبل؟ عندي رمز استرجاع" : "Used Sary before? I have a recovery code"}
			</button>
		</form>
	);
}
