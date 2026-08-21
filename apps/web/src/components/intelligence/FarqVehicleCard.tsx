/**
 * «سيارتك على الخريطة» — the control that turns the location dot into you.
 *
 * The photo never leaves the device. That is stated in the card rather than
 * buried in a policy, because it is the answer to the question a person
 * actually has when a map asks for their face.
 */
import { Camera, Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import {
	VEHICLE_COLORS,
	clearAvatar,
	loadAvatar,
	loadVehicleColor,
	processAvatar,
	saveAvatar,
	saveVehicleColor,
	vehicleColorHex,
	vehicleSvg,
	type AvatarError,
	type VehicleColorId,
} from "../../lib/farqAvatar";

const MESSAGES: Record<AvatarError | "quota", { ar: string; en: string }> = {
	"not-an-image": { ar: "هذا الملف ليس صورة", en: "That file is not an image" },
	"too-large": { ar: "الصورة كبيرة جدًا — جرّب واحدة أصغر", en: "That image is too large — try a smaller one" },
	unreadable: { ar: "ما قدرنا نقرأ هذه الصورة", en: "We could not read that image" },
	quota: { ar: "ما فيه مساحة كافية في المتصفح لحفظ الصورة", en: "No room left in this browser to store the photo" },
};

export default function FarqVehicleCard({ isRTL }: { isRTL: boolean }) {
	const [avatar, setAvatar] = useState<string | null>(null);
	const [color, setColor] = useState<VehicleColorId>("navy");
	const [error, setError] = useState<string | null>(null);
	const [busy, setBusy] = useState(false);
	const inputRef = useRef<HTMLInputElement | null>(null);

	/* Read once on mount. The store is synchronous, so there is no loading state
	 * and no flash of an empty card. */
	useEffect(() => {
		setAvatar(loadAvatar());
		setColor(loadVehicleColor());
	}, []);

	async function onPick(file: File | undefined) {
		if (!file) return;
		setError(null);
		setBusy(true);
		try {
			const dataUrl = await processAvatar(file);
			if (!saveAvatar(dataUrl)) {
				setError(isRTL ? MESSAGES.quota.ar : MESSAGES.quota.en);
				return;
			}
			setAvatar(dataUrl);
		} catch (err) {
			const kind = (err instanceof Error ? err.message : "unreadable") as AvatarError;
			const message = MESSAGES[kind] || MESSAGES.unreadable;
			setError(isRTL ? message.ar : message.en);
		} finally {
			setBusy(false);
			/* Let the same file be chosen again after a failure. */
			if (inputRef.current) inputRef.current.value = "";
		}
	}

	function onRemove() {
		clearAvatar();
		setAvatar(null);
		setError(null);
	}

	function onColor(id: VehicleColorId) {
		setColor(id);
		saveVehicleColor(id);
	}

	return (
		<section className="farq-vehicle-card" data-testid="farq-vehicle-card">
			<p className="farq-map-drawer-kicker">
				{isRTL ? "سيارتك على الخريطة" : "Your car on the map"}
			</p>

			<div className="farq-vehicle-preview" data-testid="farq-vehicle-preview">
				<div
					className="farq-vehicle-shape"
					// biome-ignore lint/security/noDangerouslySetInnerHtml: a string this module builds itself
					dangerouslySetInnerHTML={{ __html: vehicleSvg(vehicleColorHex(color)) }}
					aria-hidden
				/>
				{avatar ? (
					<img className="farq-vehicle-face" src={avatar} alt="" aria-hidden />
				) : (
					<span className="farq-vehicle-face is-empty" aria-hidden>
						<Camera size={18} />
					</span>
				)}
			</div>

			<div className="farq-vehicle-colors" role="group"
				aria-label={isRTL ? "لون السيارة" : "Car colour"}>
				{VEHICLE_COLORS.map((c) => (
					<button
						key={c.id}
						type="button"
						className={`farq-vehicle-swatch ${color === c.id ? "is-on" : ""}`}
						style={{ background: c.hex }}
						aria-pressed={color === c.id}
						aria-label={isRTL ? c.nameAr : c.nameEn}
						data-testid={`farq-vehicle-color-${c.id}`}
						onClick={() => onColor(c.id)}
					/>
				))}
			</div>

			<div className="farq-vehicle-actions">
				<button
					type="button"
					className="farq-vehicle-upload"
					disabled={busy}
					data-testid="farq-vehicle-upload"
					onClick={() => inputRef.current?.click()}
				>
					<Camera size={16} aria-hidden />
					{busy
						? isRTL ? "جاري…" : "Working…"
						: avatar
							? isRTL ? "غيّر صورتك" : "Change your photo"
							: isRTL ? "ارفع صورتك" : "Upload your photo"}
				</button>
				{avatar ? (
					<button
						type="button"
						className="farq-vehicle-remove"
						data-testid="farq-vehicle-remove"
						onClick={onRemove}
					>
						<Trash2 size={16} aria-hidden />
						<span className="sr-only">{isRTL ? "احذف الصورة" : "Remove photo"}</span>
					</button>
				) : null}
				<input
					ref={inputRef}
					type="file"
					accept="image/*"
					className="sr-only"
					data-testid="farq-vehicle-file"
					onChange={(e) => onPick(e.target.files?.[0])}
				/>
			</div>

			{error ? (
				<p className="farq-vehicle-error" role="alert" data-testid="farq-vehicle-error">
					{error}
				</p>
			) : null}

			<p className="farq-vehicle-note">
				{isRTL
					? "الصورة تبقى على جهازك — ما تنرفع لنا ولا يشوفها أحد غيرك. وتروح إذا مسحت بيانات المتصفح."
					: "The photo stays on your device — never uploaded, never seen by anyone else. It goes if you clear this browser's data."}
			</p>
		</section>
	);
}
