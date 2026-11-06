import { useEffect, useState } from "react";
import { appOpenUrl, copyText, installTarget, inviteLink } from "../../lib/outings/appInstall";
import {
	guideSteps,
	inviteLine,
	loadStep,
	mainButtonText,
	openAppOrInstall,
	saveStep,
	stepAfterLeaving,
	type GuideStep,
	type GuideStepInfo,
} from "../../lib/outings/installGuide";

/** A plain stand-in for the TestFlight icon (blue tile, white propeller) so they know what to look for. */
export function TestFlightIcon({ size = 44 }: { size?: number }) {
	return (
		<svg width={size} height={size} viewBox="0 0 44 44" aria-hidden="true" className="sary-o-guide-icon">
			<defs>
				<linearGradient id="tfg" x1="0" y1="0" x2="0" y2="1">
					<stop offset="0" stopColor="#2fb4ff" />
					<stop offset="1" stopColor="#0a6cf0" />
				</linearGradient>
			</defs>
			<rect width="44" height="44" rx="10" fill="url(#tfg)" />
			<g fill="#fff">
				<circle cx="22" cy="22" r="3.4" />
				<path d="M22 6c2.4 0 3.4 4.6 1.6 12.6h-3.2C18.6 10.6 19.6 6 22 6z" />
				<path d="M36 30c-1.2 2.1-5.7.7-11.7-4.9l1.6-2.8c7.8 2.4 11.3 5.6 10.1 7.7z" />
				<path d="M8 30c-1.2-2.1 2.3-5.3 10.1-7.7l1.6 2.8C13.7 30.7 9.2 32.1 8 30z" />
			</g>
		</svg>
	);
}

export function SaryIcon({ size = 44, ready = false }: { size?: number; ready?: boolean }) {
	return (
		<span className="sary-o-guide-icon" style={{ width: size, height: size }}>
			<img src="/icons/sary-albarq-app.png" alt="" width={size} height={size} />
			{ready ? <span className="sary-o-guide-tick" aria-hidden="true">✓</span> : null}
		</span>
	);
}

function StepIcon({ icon }: { icon: GuideStepInfo["icon"] }) {
	if (icon === "testflight") return <TestFlightIcon />;
	return <SaryIcon ready={icon === "sary-ready"} />;
}

const ARABIC_DIGITS = ["٠", "١", "٢", "٣"];

/**
 * iPhone, no app: one line, one big button, three numbered steps. Everything else
 * (joining from the browser) hides behind a small link at the bottom.
 */
export function InstallGuide({
	owner,
	outingName,
	token,
	onBrowser,
	initialStep,
}: {
	owner: string;
	outingName: string;
	token: string;
	onBrowser: () => void;
	/** Tests and screenshots; otherwise read from this phone. */
	initialStep?: GuideStep;
}) {
	const [step, setStep] = useState<GuideStep>(() => initialStep ?? loadStep());
	const install = installTarget();
	const steps = guideSteps(install.kind === "testflight-app" ? null : install.url);

	/* Back from the App Store / TestFlight: show where they are now. */
	useEffect(() => {
		if (initialStep) return;
		const onBack = () => {
			if (document.visibilityState === "visible") setStep(loadStep());
		};
		document.addEventListener("visibilitychange", onBack);
		window.addEventListener("pageshow", onBack);
		return () => {
			document.removeEventListener("visibilitychange", onBack);
			window.removeEventListener("pageshow", onBack);
		};
	}, [initialStep]);

	/* Every tap copies the invite first (Safari needs the tap), so the app finds it on «لصق». */
	const leaveFor = async (tapped: GuideStep, url: string) => {
		const link = inviteLink(window.location.origin, token);
		if (link) await copyText(link);
		const next = stepAfterLeaving(step, tapped);
		saveStep(next);
		window.location.href = url;
	};

	const main = async () => {
		const appUrl = appOpenUrl(token);
		if (step === 3 && appUrl) {
			const link = inviteLink(window.location.origin, token);
			if (link) await copyText(link);
			openAppOrInstall(appUrl, install.url, {
				go: (u) => (window.location.href = u),
				visible: () => document.visibilityState === "visible",
				setTimeout: (fn, ms) => window.setTimeout(fn, ms),
			});
			return;
		}
		/* Apple's TestFlight page itself says «نزّل TestFlight أولًا» when it is missing. */
		await leaveFor(2, install.url);
	};

	return (
		<section className="sary-o-guide" data-testid="outing-install-guide" data-step={step}>
			<h1 className="sary-o-guide-line" data-testid="outing-guide-line">
				{inviteLine(owner, outingName)}
			</h1>
			<button type="button" className="sary-o-guide-main" onClick={() => void main()} data-testid="outing-guide-main">
				{mainButtonText(step)}
			</button>
			<ol className="sary-o-guide-steps" data-testid="outing-guide-steps">
				{steps.map((s) => {
					const current = s.n === step;
					const done = s.n < step;
					const body = (
						<>
							<span className="sary-o-guide-num" aria-hidden="true">
								{done ? "✓" : ARABIC_DIGITS[s.n]}
							</span>
							<StepIcon icon={s.icon} />
							<span className="sary-o-guide-text">{s.text}</span>
						</>
					);
					return (
						<li
							key={s.n}
							className={`sary-o-guide-step${current ? " is-current" : ""}${done ? " is-done" : ""}`}
							aria-current={current ? "step" : undefined}
							data-testid={`outing-guide-step-${s.n}`}
						>
							{s.href ? (
								<a
									href={s.href}
									onClick={(e) => {
										e.preventDefault();
										void leaveFor(s.n, s.href!);
									}}
								>
									{body}
								</a>
							) : (
								<div>{body}</div>
							)}
						</li>
					);
				})}
			</ol>
			<button type="button" className="sary-o-guide-browser" onClick={onBrowser} data-testid="outing-guide-browser">
				ما تبي تنزّل؟ تابع من المتصفح
			</button>
		</section>
	);
}
