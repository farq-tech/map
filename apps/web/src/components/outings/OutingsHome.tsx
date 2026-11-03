import { useNavigate } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Pencil } from "lucide-react";
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
import { formatDate, formatNumber } from "../../lib/sary/domain";
import { usePageMeta } from "../../lib/usePageMeta";
import { useSaryChrome } from "../../lib/sary/useSaryChrome";
import { statusLabel } from "./labels";
import ProfileForm from "./ProfileForm";
import { RecoverySave } from "./Recovery";
import { SummaryList } from "./TripSummary";
import { hasTrip } from "../../lib/outings/tripStore";
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
	const [editingName, setEditingName] = useState(false);
	const [newName, setNewName] = useState("");

	useSaryChrome();
	usePageMeta({
		title: isRTL ? "طلعة مشتركة · سَرى البارق" : "Shared outing · Sary Albarq",
		description: isRTL ? "أنشئ طلعة، أرسل الرابط لأصحابك، وشوفوا بعض على الخريطة." : "Create an outing, invite friends, and see each other on one map.",
		path: "/outings",
		robots: "noindex",
	});

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

	const open = (id: string) => void navigate({ to: "/outings/$id", params: { id } });

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

	const saveName = async () => {
		setBusy(true);
		setError(null);
		try {
			const user = await OutingsApi.updateProfile({ display_name: newName });
			setIdentity((id) => (id ? { ...id, user } : id));
			setEditingName(false);
		} catch (e) {
			setError(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		} finally {
			setBusy(false);
		}
	};

	const ongoing = current[0] || null;

	return (
		<main className="sary-o-page" dir={isRTL ? "rtl" : "ltr"} data-testid="outings-home">
			<header className="sary-o-top">
				<button type="button" className="sary-o-back" onClick={() => void navigate({ to: "/map" })}>
					{isRTL ? <ChevronRight className="size-4" aria-hidden /> : <ChevronLeft className="size-4" aria-hidden />}
					{isRTL ? "الخريطة" : "Map"}
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
					{ongoing ? (
						<section className="sary-o-card sary-o-current" data-testid="outing-ongoing">
							<span className="sary-o-kicker">{isRTL ? "طلعتك الجارية" : "Your current outing"}</span>
							<h2>{ongoing.name}</h2>
							<p className="sary-o-meta">
								<StatusChip status={ongoing.status} isRTL={isRTL} />
								{isRTL ? `${formatNumber(ongoing.member_count, true)} مشارك` : `${ongoing.member_count} members`}
							</p>
							<button type="button" className="sary-o-primary" onClick={() => open(ongoing.id)} data-testid="outing-ongoing-open">
								{isRTL ? "ارجع للطلعة" : "Back to the outing"}
							</button>
						</section>
					) : null}

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
						{editingName ? (
							<form
								className="sary-o-inline-form"
								onSubmit={(e) => {
									e.preventDefault();
									void saveName();
								}}
							>
								<input
									value={newName}
									onChange={(e) => setNewName(e.target.value)}
									maxLength={40}
									required
									autoFocus
									aria-label={isRTL ? "اسمك" : "Your name"}
									data-testid="outing-rename-input"
								/>
								<button type="submit" className="sary-o-primary" disabled={busy || !newName.trim()} data-testid="outing-rename-save">
									{isRTL ? "حفظ" : "Save"}
								</button>
								<button type="button" className="sary-o-secondary" onClick={() => setEditingName(false)}>
									{isRTL ? "إلغاء" : "Cancel"}
								</button>
							</form>
						) : (
							<p className="sary-o-note sary-o-identity">
								{isRTL ? `تظهر لأصحابك باسم «${identity.user.display_name}».` : `Friends will see you as “${identity.user.display_name}”.`}
								<button
									type="button"
									className="sary-o-link-btn"
									onClick={() => {
										setNewName(identity.user.display_name);
										setEditingName(true);
									}}
									data-testid="outing-rename"
								>
									<Pencil className="size-3.5" aria-hidden />
									{isRTL ? "تعديل" : "Edit"}
								</button>
							</p>
						)}
					</section>

					{error ? <p className="sary-o-error" role="alert">{error}</p> : null}

					<RecoverySave isRTL={isRTL} />

					<section className="sary-o-card" data-testid="outing-current">
						<h2>{isRTL ? "طلعاتك الحالية" : "Current outings"}</h2>
						{current.length ? (
							<OutingRows rows={current} isRTL={isRTL} onOpen={open} />
						) : (
							<p className="sary-o-note">{loaded ? (isRTL ? "لا توجد طلعة حالية." : "No current outing.") : "…"}</p>
						)}
					</section>

					<section className="sary-o-card" data-testid="outing-history">
						<h2>{isRTL ? "الطلعات السابقة" : "Past outings"}</h2>
						{history.length ? (
							<OutingRows rows={history} isRTL={isRTL} onSummary={open} meId={identity?.user.id} />
						) : (
							<p className="sary-o-note">{isRTL ? "لا طلعات سابقة بعد." : "No past outings yet."}</p>
						)}
						<p className="sary-o-note">
							{isRTL
								? "السجل يحفظ الاسم والتاريخ والمشاركين فقط — لا نحفظ مسار أحد ولا مواقعه. الملخص (المسافة والوقت) يظهر فقط لمن اختار مشاركته."
								: "History keeps name, date and members only — never anyone's route or positions. A summary (distance and time) appears only if its owner chose to share it."}
						</p>
					</section>
				</>
			)}
		</main>
	);
}

function StatusChip({ status, isRTL }: { status: OutingSummary["status"]; isRTL: boolean }) {
	return (
		<span className="sary-o-chip" data-status={status}>
			{statusLabel(status, isRTL)}
		</span>
	);
}

function OutingRows({ rows, isRTL, onOpen, onSummary, meId }: { rows: OutingSummary[]; isRTL: boolean; onOpen?: (id: string) => void; onSummary?: (id: string) => void; meId?: string }) {
	return (
		<ul className="sary-o-rows">
			{rows.map((r) => {
				const when = r.ended_at || r.started_at || r.created_at;
				const mine =
					r.my_status === "removed" ? (isRTL ? "أُزلت منها" : "removed") : r.my_status === "left" ? (isRTL ? "غادرتها" : "left") : null;
				const body = (
					<>
						<span className="sary-o-row-head">
							<strong>{r.name}</strong>
							<StatusChip status={r.status} isRTL={isRTL} />
						</span>
						<span>
							{isRTL ? `${formatNumber(r.member_count, true)} مشارك` : `${r.member_count} members`}
							{" · "}
							{formatDate(when, isRTL)}
							{mine ? ` · ${mine}` : ""}
						</span>
					</>
				);
				return (
					<li key={r.id}>
						{onOpen ? (
							<button type="button" className="sary-o-row-card" onClick={() => onOpen(r.id)} data-testid="outing-row">
								{body}
							</button>
						) : (
							<div className="sary-o-row-card is-static">
								{body}
								{r.summaries?.length ? <SummaryList rows={r.summaries} isRTL={isRTL} meId={meId} /> : null}
								{onSummary && r.status === "ended" && r.my_status === "active" && !r.summaries?.some((x) => x.user_id === meId) && hasTrip(r.id) ? (
									<button type="button" className="sary-o-link-btn" onClick={() => onSummary(r.id)} data-testid="outing-history-summary">
										{isRTL ? "ملخصك جاهز على جوالك — شاركه؟" : "Your summary is on this phone — share it?"}
									</button>
								) : null}
							</div>
						)}
					</li>
				);
			})}
		</ul>
	);
}
