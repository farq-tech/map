/**
 * Push-to-talk («اضغط وتكلم») — the pure parts: which format to record in,
 * whether this device can play what arrived, and which clips are still news.
 *
 * Format. iOS Safari records only MP4/AAC; Chrome and Firefox record WebM/Opus,
 * and recent Chrome can record MP4/AAC too. AAC in MP4 plays on every browser
 * we serve, so it is asked for first; WebM/Opus is the transcode-free fallback
 * (Safari plays it from 17.4/18). Nothing is converted on the server: each
 * receiver checks canPlayType and says so plainly when it cannot.
 */

export const CLIP_MAX_MS = 15_000;
/** A press shorter than this is a tap, not a message. */
export const CLIP_MIN_MS = 500;
/** How long «رسالة صوتية من …» stays over the car after it arrives. */
export const CHIP_MS = 60_000;
/** Older than this when we first see it: shown, never auto-played. */
export const AUTOPLAY_MAX_AGE_MS = 90_000;

export const RECORDING_MIMES = [
	"audio/mp4;codecs=mp4a.40.2",
	"audio/webm;codecs=opus",
	"audio/mp4",
	"audio/webm",
	"audio/ogg;codecs=opus",
] as const;

/** First format this recorder supports, or "" to let the browser choose. */
export function pickRecordingMime(isTypeSupported: ((t: string) => boolean) | undefined): string {
	if (!isTypeSupported) return "";
	for (const t of RECORDING_MIMES) {
		try {
			if (isTypeSupported(t)) return t;
		} catch {
			/* some engines throw on unknown types */
		}
	}
	return "";
}

/** The container part of a MIME type, as the server will label it. */
export function containerOf(mime: string): string {
	return mime.split(";")[0].trim().toLowerCase();
}

/** Can this device play a clip of this type? "" from canPlayType means no. */
export function playable(mime: string, canPlayType: ((t: string) => string) | undefined): boolean {
	if (!canPlayType) return false;
	const base = containerOf(mime);
	const probes = base === "audio/mp4" ? ["audio/mp4;codecs=mp4a.40.2", "audio/mp4"] : base === "audio/webm" ? ["audio/webm;codecs=opus", "audio/webm"] : [base];
	return probes.some((t) => {
		try {
			return canPlayType(t) !== "";
		} catch {
			return false;
		}
	});
}

export type ClipMeta = {
	id: string;
	user_id: string;
	mime: string;
	duration_ms: number;
	at: string;
	expires_at: string;
	url: string;
};

/** Clips worth a chip right now: from someone else, not expired, recent. */
export function liveChips(clips: ClipMeta[], meId: string | undefined, serverNow: number): Map<string, ClipMeta> {
	const out = new Map<string, ClipMeta>();
	for (const c of clips) {
		if (c.user_id === meId) continue;
		const at = new Date(c.at).getTime();
		if (new Date(c.expires_at).getTime() <= serverNow) continue;
		if (serverNow - at > CHIP_MS + c.duration_ms) continue;
		const prev = out.get(c.user_id);
		if (!prev || new Date(prev.at).getTime() < at) out.set(c.user_id, c);
	}
	return out;
}

/**
 * New clips to queue for playback, oldest first. Clips already present when
 * the screen opened are not news; nor is anything older than the autoplay window.
 */
export function newClipsToPlay(clips: ClipMeta[], seen: Set<string>, meId: string | undefined, serverNow: number): ClipMeta[] {
	return clips
		.filter((c) => !seen.has(c.id) && c.user_id !== meId && serverNow - new Date(c.at).getTime() <= AUTOPLAY_MAX_AGE_MS && new Date(c.expires_at).getTime() > serverNow)
		.sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime());
}

/** Seconds as people say them: «٤ ث». */
export function clipSeconds(ms: number): number {
	return Math.max(1, Math.round(ms / 1000));
}
