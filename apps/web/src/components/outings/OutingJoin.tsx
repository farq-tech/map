import { useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import {
	loadIdentity,
	OutingApiError,
	OutingsApi,
	outingErrorText,
	type Identity,
	type InvitePreview,
} from "../../lib/outings/api";
import { statusLabel } from "./labels";
import ProfileForm from "./ProfileForm";
import "../../styles/outings.css";

const PENDING_KEY = "sary.outings.pendingInvite";

/** The token rides in the URL fragment so no server ever logs it. Read it once, then wipe it from the address bar. */
function takeInviteToken(): string | null {
	const fromHash = window.location.hash.replace(/^#/, "").trim();
	if (/^[A-Za-z0-9_-]{43}$/.test(fromHash)) {
		try {
			sessionStorage.setItem(PENDING_KEY, fromHash);
		} catch {
			/* */
		}
		window.history.replaceState(null, "", window.location.pathname);
		return fromHash;
	}
	try {
		return sessionStorage.getItem(PENDING_KEY);
	} catch {
		return null;
	}
}

/** /outings/join#<token> — see who invited you to what, then choose to join. */
export default function OutingJoin() {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const navigate = useNavigate();
	const [token] = useState(() => takeInviteToken());
	const [identity, setIdentity] = useState<Identity | null>(() => loadIdentity());
	const [preview, setPreview] = useState<InvitePreview | null>(null);
	const [error, setError] = useState<string | null>(token ? null : "invite_invalid");
	const [busy, setBusy] = useState(false);

	useEffect(() => {
		if (!token) return;
		OutingsApi.previewInvite(token).then(
			(r) => setPreview(r.invite),
			(e) => setError(e instanceof OutingApiError ? e.code : "network"),
		);
	}, [token]);

	const join = async () => {
		if (!token) return;
		setBusy(true);
		setError(null);
		try {
			const r = await OutingsApi.join(token);
			try {
				sessionStorage.removeItem(PENDING_KEY);
			} catch {
				/* */
			}
			void navigate({ to: "/outings/$id", params: { id: r.outing_id }, replace: true });
		} catch (e) {
			const code = e instanceof OutingApiError ? e.code : "network";
			if (code === "unauthorized") setIdentity(null);
			setError(code);
		} finally {
			setBusy(false);
		}
	};

	return (
		<main className="sary-o-page" dir={isRTL ? "rtl" : "ltr"} data-testid="outing-join">
			<header className="sary-o-top">
				<h1>{isRTL ? "دعوة إلى طلعة" : "Outing invite"}</h1>
			</header>
			{preview ? (
				<section className="sary-o-card" data-testid="outing-join-preview">
					<h2 data-testid="outing-join-name">{preview.name}</h2>
					<p>
						{isRTL ? `دعاك ${preview.owner_name}` : `${preview.owner_name} invited you`} ·{" "}
						{isRTL ? `${preview.member_count.toLocaleString("ar-SA")} مشارك` : `${preview.member_count} members`} ·{" "}
						{statusLabel(preview.status, isRTL)}
					</p>
					<p className="sary-o-note">
						{isRTL
							? "بعد الانضمام يرى أعضاء الطلعة موقعك وأنت على شاشة الطلعة فقط، وتستطيع إيقاف المشاركة أو المغادرة متى شئت."
							: "Once you join, members see your location only while you are on the outing screen. You can pause sharing or leave any time."}
					</p>
					{identity ? (
						<button type="button" className="sary-o-primary" onClick={() => void join()} disabled={busy} data-testid="outing-join-submit">
							{busy ? "…" : isRTL ? `انضمام باسم ${identity.user.display_name}` : `Join as ${identity.user.display_name}`}
						</button>
					) : (
						<ProfileForm isRTL={isRTL} onDone={setIdentity} submitLabel={isRTL ? "حفظ الاسم" : "Save name"} />
					)}
					<button type="button" className="sary-o-secondary" onClick={() => void navigate({ to: "/map" })}>
						{isRTL ? "ليس الآن" : "Not now"}
					</button>
				</section>
			) : null}
			{error ? (
				<section className="sary-o-card" role="alert" data-testid="outing-join-error">
					<p>{outingErrorText(error, isRTL)}</p>
					<button type="button" className="sary-o-secondary" onClick={() => void navigate({ to: "/outings" })}>
						{isRTL ? "طلعاتي" : "My outings"}
					</button>
				</section>
			) : !preview ? (
				<p className="sary-o-note">…</p>
			) : null}
		</main>
	);
}
