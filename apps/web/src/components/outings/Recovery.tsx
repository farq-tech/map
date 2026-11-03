import { useEffect, useState } from "react";
import { OutingApiError, OutingsApi, outingErrorText, type Identity, type RecoveryStatus } from "../../lib/outings/api";

/**
 * Account recovery without accounts. The device key lives in this browser;
 * if its data is cleared the person is a stranger to their own outings. A
 * recovery code, saved once somewhere safe, brings them back on any device.
 * No SMS, no third party: the code is the only thing that proves it.
 */

/** «احفظ رمز الاسترجاع» — make a code, show it once. */
export function RecoverySave({ isRTL }: { isRTL: boolean }) {
	const [status, setStatus] = useState<RecoveryStatus | null>(null);
	const [code, setCode] = useState<string | null>(null);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [copied, setCopied] = useState(false);

	useEffect(() => {
		OutingsApi.recoveryStatus().then(setStatus, () => setStatus(null));
	}, []);

	const make = async () => {
		setBusy(true);
		setError(null);
		try {
			const r = await OutingsApi.createRecoveryCode();
			setCode(r.code);
			setCopied(false);
			setStatus({ active: true, created_at: r.created_at });
		} catch (e) {
			setError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};

	return (
		<section className="sary-o-card" data-testid="outing-recovery">
			<h2>{isRTL ? "رمز الاسترجاع" : "Recovery code"}</h2>
			{code ? (
				<>
					<p className="sary-o-note">
						{isRTL
							? "احفظ هذا الرمز الآن (صورة شاشة أو ملاحظة خاصة). لن يظهر مرة ثانية، ومن معه الرمز يدخل باسمك."
							: "Save this code now (a screenshot or a private note). It will not be shown again, and whoever has it can sign in as you."}
					</p>
					<input
						className="sary-o-link sary-o-code"
						readOnly
						value={code}
						dir="ltr"
						onFocus={(e) => e.currentTarget.select()}
						data-testid="outing-recovery-code"
					/>
					<div className="sary-o-row">
						<button
							type="button"
							className="sary-o-primary"
							onClick={() =>
								void navigator.clipboard?.writeText(code).then(
									() => setCopied(true),
									() => setCopied(false),
								)
							}
							data-testid="outing-recovery-copy"
						>
							{copied ? (isRTL ? "تم النسخ ✓" : "Copied ✓") : isRTL ? "نسخ الرمز" : "Copy code"}
						</button>
						<button type="button" className="sary-o-secondary" onClick={() => setCode(null)} data-testid="outing-recovery-done">
							{isRTL ? "حفظته" : "I saved it"}
						</button>
					</div>
				</>
			) : (
				<>
					<p className="sary-o-note">
						{status?.active
							? isRTL
								? "لديك رمز استرجاع محفوظ. إن ضاع، أنشئ رمزًا جديدًا (يتوقف القديم)."
								: "You have a recovery code. If you lost it, make a new one (the old one stops working)."
							: isRTL
								? "إذا مُسحت بيانات المتصفح تفقد طلعاتك. احفظ رمزًا لتسترجعها على أي جهاز."
								: "If this browser's data is cleared you lose your outings. Save a code to get them back on any device."}
					</p>
					<button
						type="button"
						className={status?.active ? "sary-o-secondary" : "sary-o-primary"}
						disabled={busy}
						onClick={() => void make()}
						data-testid="outing-recovery-create"
					>
						{busy ? "…" : status?.active ? (isRTL ? "رمز جديد (يلغي القديم)" : "New code (cancels the old)") : isRTL ? "احفظ رمز الاسترجاع" : "Save a recovery code"}
					</button>
				</>
			)}
			{error ? <p className="sary-o-error" role="alert">{error}</p> : null}
		</section>
	);
}

/** On a new device: type the saved code, get your outings back. */
export function RecoveryForm({ isRTL, onDone, onCancel }: { isRTL: boolean; onDone: (id: Identity) => void; onCancel: () => void }) {
	const [code, setCode] = useState("");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	return (
		<form
			className="sary-o-form"
			data-testid="outing-recover-form"
			onSubmit={async (e) => {
				e.preventDefault();
				setBusy(true);
				setError(null);
				try {
					onDone(await OutingsApi.recover(code));
				} catch (err) {
					setError(outingErrorText(err instanceof OutingApiError ? err.code : "network", isRTL));
				} finally {
					setBusy(false);
				}
			}}
		>
			<label>
				<span>{isRTL ? "رمز الاسترجاع" : "Recovery code"}</span>
				<input
					value={code}
					onChange={(e) => setCode(e.target.value)}
					maxLength={60}
					required
					dir="ltr"
					autoComplete="one-time-code"
					autoCapitalize="characters"
					spellCheck={false}
					placeholder="XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
					data-testid="outing-recover-input"
				/>
			</label>
			<p className="sary-o-note">
				{isRTL
					? "يرجع اسمك وطلعاتك على هذا الجهاز، ويتوقف الجهاز القديم. الرمز يُستخدم مرة واحدة؛ احفظ رمزًا جديدًا بعدها."
					: "Your name and outings come back on this device and the old device is signed out. A code works once; save a new one afterwards."}
			</p>
			{error ? <p className="sary-o-error" role="alert">{error}</p> : null}
			<div className="sary-o-row">
				<button type="submit" className="sary-o-primary" disabled={busy || code.replace(/[\s-]/g, "").length < 28} data-testid="outing-recover-submit">
					{busy ? "…" : isRTL ? "استرجع حسابي" : "Recover"}
				</button>
				<button type="button" className="sary-o-secondary" onClick={onCancel}>
					{isRTL ? "رجوع" : "Back"}
				</button>
			</div>
		</form>
	);
}
