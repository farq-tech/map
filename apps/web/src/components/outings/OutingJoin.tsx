import { useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { loadAvatar } from "../../lib/farqAvatar";
import {
	loadIdentity,
	OutingApiError,
	OutingsApi,
	outingErrorText,
	type Identity,
	type InvitePreview,
} from "../../lib/outings/api";
import { formatNumber } from "../../lib/sary/domain";
import { usePageMeta } from "../../lib/usePageMeta";
import { useSaryChrome } from "../../lib/sary/useSaryChrome";
import { statusLabel } from "./labels";
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

/** /outings/join#<token> — see who invited you to what, then join in one tap. */
export default function OutingJoin() {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const navigate = useNavigate();
	const [token] = useState(() => takeInviteToken());
	const [identity, setIdentity] = useState<Identity | null>(() => loadIdentity());
	const [preview, setPreview] = useState<InvitePreview | null>(null);
	const [error, setError] = useState<string | null>(token ? null : "invite_invalid");
	const [busy, setBusy] = useState(false);
	const avatar = loadAvatar();
	const [name, setName] = useState("");
	const [sharePhoto, setSharePhoto] = useState(false);

	useSaryChrome();
	usePageMeta({
		title: preview
			? isRTL ? `دعوة إلى «${preview.name}» · سَرى البارق` : `Invite to “${preview.name}” · Sary Albarq`
			: isRTL ? "دعوة إلى طلعة · سَرى البارق" : "Outing invite · Sary Albarq",
		path: "/outings/join",
		robots: "noindex",
	});

	useEffect(() => {
		if (!token) return;
		OutingsApi.previewInvite(token).then(
			(r) => setPreview(r.invite),
			(e) => setError(e instanceof OutingApiError ? e.code : "network"),
		);
	}, [token]);

	/* One tap: create the identity if there is none, then join. */
	const join = async () => {
		if (!token) return;
		setBusy(true);
		setError(null);
		try {
			if (!identity) {
				const id = await OutingsApi.createIdentity(name, sharePhoto ? avatar : null);
				setIdentity(id);
			}
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
			<header className="sary-o-top sary-o-brand">
				<strong>{isRTL ? "سَرى البارق — خريطة البر" : "Sary Albarq — the desert map"}</strong>
				<p className="sary-o-note">
					{isRTL
						? "خريطة للطلعات البرية: تشوف أصحابك على الخريطة أثناء الطلعة، ويشوفونك."
						: "A map for desert trips: see your friends on one map during the outing, and they see you."}
				</p>
			</header>
			{preview ? (
				<section className="sary-o-card" data-testid="outing-join-preview">
					<span className="sary-o-kicker">{isRTL ? "دعوة إلى طلعة" : "Outing invite"}</span>
					<h2 data-testid="outing-join-name">{preview.name}</h2>
					<p>
						{isRTL ? `دعاك ${preview.owner_name}` : `${preview.owner_name} invited you`} ·{" "}
						{isRTL ? `${formatNumber(preview.member_count, true)} مشارك` : `${preview.member_count} members`} ·{" "}
						{statusLabel(preview.status, isRTL)}
					</p>
					<p className="sary-o-note">
						{isRTL
							? "بعد الانضمام يرى أعضاء الطلعة موقعك وأنت على شاشة الطلعة فقط، وتستطيع إيقاف المشاركة أو المغادرة متى شئت."
							: "Once you join, members see your location only while you are on the outing screen. You can pause sharing or leave any time."}
					</p>
					<form
						className="sary-o-form"
						onSubmit={(e) => {
							e.preventDefault();
							void join();
						}}
					>
						{!identity ? (
							<>
								<label>
									<span>{isRTL ? "اسمك كما يظهر لأصحابك" : "Your name, as friends will see it"}</span>
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
							</>
						) : null}
						<button
							type="submit"
							className="sary-o-primary"
							disabled={busy || (!identity && !name.trim())}
							data-testid="outing-join-submit"
						>
							{busy
								? "…"
								: identity
									? isRTL ? `انضم للطلعة باسم ${identity.user.display_name}` : `Join as ${identity.user.display_name}`
									: isRTL ? "انضم للطلعة" : "Join the outing"}
						</button>
					</form>
					<button type="button" className="sary-o-secondary" onClick={() => void navigate({ to: "/map" })}>
						{isRTL ? "ليس الآن" : "Not now"}
					</button>
				</section>
			) : null}
			{error ? (
				<section className="sary-o-card" role="alert" data-testid="outing-join-error">
					<p>{outingErrorText(error, isRTL)}</p>
					<div className="sary-o-row">
						<button type="button" className="sary-o-primary" onClick={() => void navigate({ to: "/map" })} data-testid="outing-join-open-map">
							{isRTL ? "افتح الخريطة" : "Open the map"}
						</button>
						<button type="button" className="sary-o-secondary" onClick={() => void navigate({ to: "/outings" })}>
							{isRTL ? "طلعاتي" : "My outings"}
						</button>
					</div>
				</section>
			) : !preview ? (
				<p className="sary-o-note">…</p>
			) : null}
		</main>
	);
}
