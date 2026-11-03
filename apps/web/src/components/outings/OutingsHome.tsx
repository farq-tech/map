import { useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import {
	loadIdentity,
	OutingApiError,
	OutingsApi,
	outingErrorText,
	type Identity,
	type OutingSummary,
} from "../../lib/outings/api";
import { statusLabel } from "./labels";
import ProfileForm from "./ProfileForm";
import "../../styles/outings.css";

/** /outings — start an outing, rejoin a current one, look back at past ones. */
export default function OutingsHome() {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const navigate = useNavigate();
	const [identity, setIdentity] = useState<Identity | null>(() => loadIdentity());
	const [current, setCurrent] = useState<OutingSummary[]>([]);
	const [history, setHistory] = useState<OutingSummary[]>([]);
	const [name, setName] = useState("");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [loaded, setLoaded] = useState(false);

	const refresh = useCallback(async () => {
		if (!loadIdentity()) return;
		try {
			const r = await OutingsApi.list();
			setCurrent(r.current);
			setHistory(r.history);
			setError(null);
		} catch (e) {
			const code = e instanceof OutingApiError ? e.code : "network";
			if (code === "unauthorized") setIdentity(null);
			setError(outingErrorText(code, isRTL));
		} finally {
			setLoaded(true);
		}
	}, [isRTL]);

	useEffect(() => {
		if (identity) void refresh();
	}, [identity, refresh]);

	const create = async () => {
		setBusy(true);
		setError(null);
		try {
			const r = await OutingsApi.create(name);
			void navigate({ to: "/outings/$id", params: { id: r.outing_id }, search: { panel: "invite" } });
		} catch (e) {
			setError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};

	return (
		<main className="sary-o-page" dir={isRTL ? "rtl" : "ltr"} data-testid="outings-home">
			<header className="sary-o-top">
				<button type="button" className="sary-o-back" onClick={() => void navigate({ to: "/map" })}>
					{isRTL ? "← الخريطة" : "← Map"}
				</button>
				<h1>{isRTL ? "طلعة مشتركة" : "Shared outing"}</h1>
				<p className="sary-o-note">
					{isRTL
						? "أنشئ طلعة، أرسل الرابط لخويك، وشوفوا بعض على الخريطة أثناء الطلعة."
						: "Create an outing, send the link, and see each other on one map."}
				</p>
			</header>

			{!identity ? (
				<section className="sary-o-card">
					<h2>{isRTL ? "قبل أن تبدأ" : "Before you start"}</h2>
					<ProfileForm isRTL={isRTL} onDone={setIdentity} />
				</section>
			) : (
				<>
					<section className="sary-o-card" data-testid="outing-create">
						<h2>{isRTL ? "طلعة جديدة" : "New outing"}</h2>
						<form
							className="sary-o-form"
							onSubmit={(e) => {
								e.preventDefault();
								void create();
							}}
						>
							<label>
								<span>{isRTL ? "اسم الطلعة" : "Outing name"}</span>
								<input
									value={name}
									onChange={(e) => setName(e.target.value)}
									maxLength={60}
									required
									placeholder={isRTL ? "طلعة الثمامة" : "Thumamah run"}
									data-testid="outing-create-name"
								/>
							</label>
							<button type="submit" className="sary-o-primary" disabled={busy || !name.trim()} data-testid="outing-create-submit">
								{busy ? "…" : isRTL ? "إنشاء وإرسال الدعوة" : "Create and invite"}
							</button>
						</form>
						<p className="sary-o-note">
							{isRTL ? `تظهر لأصحابك باسم «${identity.user.display_name}».` : `Friends will see you as “${identity.user.display_name}”.`}
						</p>
					</section>

					{error ? <p className="sary-o-error" role="alert">{error}</p> : null}

					<section className="sary-o-card" data-testid="outing-current">
						<h2>{isRTL ? "طلعاتك الحالية" : "Current outings"}</h2>
						{current.length ? (
							<OutingRows rows={current} isRTL={isRTL} onOpen={(id) => void navigate({ to: "/outings/$id", params: { id } })} />
						) : (
							<p className="sary-o-note">{loaded ? (isRTL ? "لا توجد طلعة حالية." : "No current outing.") : "…"}</p>
						)}
					</section>

					<section className="sary-o-card" data-testid="outing-history">
						<h2>{isRTL ? "الطلعات السابقة" : "Past outings"}</h2>
						{history.length ? (
							<OutingRows rows={history} isRTL={isRTL} />
						) : (
							<p className="sary-o-note">{isRTL ? "لا طلعات سابقة بعد." : "No past outings yet."}</p>
						)}
						<p className="sary-o-note">
							{isRTL
								? "السجل يحفظ الاسم والتاريخ والمشاركين فقط — لا نحفظ مسار أحد ولا مواقعه."
								: "History keeps name, date and members only — never anyone's route or positions."}
						</p>
					</section>
				</>
			)}
		</main>
	);
}

function OutingRows({ rows, isRTL, onOpen }: { rows: OutingSummary[]; isRTL: boolean; onOpen?: (id: string) => void }) {
	return (
		<ul className="sary-o-rows">
			{rows.map((r) => {
				const when = r.ended_at || r.started_at || r.created_at;
				const body = (
					<>
						<strong>{r.name}</strong>
						<span>
							{statusLabel(r.status, isRTL)}
							{r.my_status === "removed" ? (isRTL ? " · أُزلت منها" : " · removed") : r.my_status === "left" ? (isRTL ? " · غادرتها" : " · left") : ""}
							{" · "}
							{isRTL ? `${r.member_count.toLocaleString("ar-SA")} مشارك` : `${r.member_count} members`}
							{" · "}
							{new Date(when).toLocaleDateString(isRTL ? "ar-SA" : "en")}
						</span>
					</>
				);
				return (
					<li key={r.id}>
						{onOpen ? (
							<button type="button" onClick={() => onOpen(r.id)} data-testid="outing-row">
								{body}
							</button>
						) : (
							<div>{body}</div>
						)}
					</li>
				);
			})}
		</ul>
	);
}
