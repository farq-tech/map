/**
 * The page a link preview (WhatsApp, iMessage, Telegram…) sees for an invite.
 *
 * The invite token rides in the URL fragment, which no client ever sends to a
 * server — so a crawler fetching /outings/join gets the same page for every
 * invite. That is the point: the card is generic («دعوة إلى طلعة», brand
 * image, one Arabic line), it names no outing and no person, and the token
 * never reaches Vercel's or anyone's logs. The build writes this as a static
 * file (outings-join.html) and vercel.json serves it for /outings/join only;
 * the same file boots the app for people.
 */

export const INVITE_PAGE_FILE = "outings-join.html";
export const INVITE_IMAGE_PATH = "/og/outing-invite.png";

export const INVITE_META = {
	title: "دعوة إلى طلعة",
	siteName: "سَرى البارق",
	description: "انضم لطلعتي على سَرى البارق — شوفوا بعض على الخريطة أثناء الطلعة البرية.",
	imageAlt: "دعوة إلى طلعة على سَرى البارق",
} as const;

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** https://host from the build environment (Vercel sets these), or "" for relative URLs. */
export function publicOrigin(env: Record<string, string | undefined>): string {
	const raw = env.SARY_PUBLIC_ORIGIN || env.VERCEL_PROJECT_PRODUCTION_URL || env.VERCEL_URL || "";
	const t = raw.trim().replace(/\/+$/, "");
	if (!t) return "";
	const url = /^https?:\/\//.test(t) ? t : `https://${t}`;
	return /^https?:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(url) ? url : "";
}

/** index.html → the invite page: same app, invite title/description and Open Graph tags. */
export function inviteHtml(indexHtml: string, origin: string): string {
	const m = INVITE_META;
	const tags = [
		`<meta property="og:type" content="website" />`,
		`<meta property="og:site_name" content="${esc(m.siteName)}" />`,
		`<meta property="og:locale" content="ar_SA" />`,
		`<meta property="og:title" content="${esc(m.title)}" />`,
		`<meta property="og:description" content="${esc(m.description)}" />`,
		`<meta property="og:url" content="${esc(`${origin}/outings/join`)}" />`,
		`<meta property="og:image" content="${esc(`${origin}${INVITE_IMAGE_PATH}`)}" />`,
		`<meta property="og:image:type" content="image/png" />`,
		`<meta property="og:image:width" content="1200" />`,
		`<meta property="og:image:height" content="630" />`,
		`<meta property="og:image:alt" content="${esc(m.imageAlt)}" />`,
		`<meta name="twitter:card" content="summary_large_image" />`,
	].join("\n    ");
	let out = indexHtml.replace(/<title>[\s\S]*?<\/title>/, `<title>${esc(`${m.title} · ${m.siteName}`)}</title>`);
	out = out.replace(/<meta name="description"[^>]*>/, `<meta name="description" content="${esc(m.description)}" />`);
	if (out === indexHtml || !out.includes("</head>")) throw new Error("inviteHtml: index.html has no <title>/<head> to rewrite");
	return out.replace("</head>", `    ${tags}\n  </head>`);
}
