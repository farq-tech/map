import { Mic } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { OutingApiError, OutingsApi, outingErrorText } from "../../lib/outings/api";
import type { OutingView } from "../../lib/outings/outingState";
import { serverNow } from "../../lib/outings/outingState";
import { formatNumber } from "../../lib/sary/domain";
import {
	CLIP_MAX_MS,
	CLIP_MIN_MS,
	clipSeconds,
	liveChips,
	newClipsToPlay,
	pickRecordingMime,
	playable,
	type ClipMeta,
} from "../../lib/outings/voice";

type RecState = "idle" | "arming" | "recording" | "sending";

/**
 * «اضغط وتكلم»: hold to record (≤ 15 s), let go to send. The recording goes
 * to our API only, lives there 10 minutes in memory, and reaches the members
 * of this outing — no third-party service, nothing kept.
 */
export function PushToTalk({ outingId, isRTL, disabled, onSent }: { outingId: string; isRTL: boolean; disabled?: boolean; onSent: (text: string) => void }) {
	const [state, setState] = useState<RecState>("idle");
	const [elapsed, setElapsed] = useState(0);
	const [message, setMessage] = useState<string | null>(null);
	const pressedRef = useRef(false);
	const recRef = useRef<MediaRecorder | null>(null);
	const streamRef = useRef<MediaStream | null>(null);
	const startedRef = useRef(0);
	const cancelledRef = useRef(false);
	const autoStopRef = useRef<number | null>(null);

	const supported = typeof window !== "undefined" && typeof window.MediaRecorder !== "undefined" && Boolean(navigator.mediaDevices?.getUserMedia);

	const release = () => {
		streamRef.current?.getTracks().forEach((t) => t.stop());
		streamRef.current = null;
		if (autoStopRef.current) window.clearTimeout(autoStopRef.current);
		autoStopRef.current = null;
	};

	useEffect(() => () => {
		cancelledRef.current = true;
		try {
			recRef.current?.stop();
		} catch {
			/* */
		}
		release();
	}, []);

	useEffect(() => {
		if (state !== "recording") return;
		const t = window.setInterval(() => setElapsed(Date.now() - startedRef.current), 200);
		return () => window.clearInterval(t);
	}, [state]);

	useEffect(() => {
		if (!message) return;
		const t = window.setTimeout(() => setMessage(null), 3_500);
		return () => window.clearTimeout(t);
	}, [message]);

	const send = useCallback(
		async (blob: Blob, ms: number) => {
			setState("sending");
			try {
				await OutingsApi.uploadClip(outingId, blob, ms);
				onSent(isRTL ? "وصلت رسالتك الصوتية ✓" : "Voice message sent ✓");
			} catch (e) {
				setMessage(outingErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
			} finally {
				setState("idle");
			}
		},
		[outingId, isRTL, onSent],
	);

	const begin = async () => {
		if (disabled || state !== "idle") return;
		if (!supported) {
			setMessage(isRTL ? "المتصفح لا يدعم التسجيل الصوتي." : "This browser cannot record audio.");
			return;
		}
		pressedRef.current = true;
		cancelledRef.current = false;
		setState("arming");
		let stream: MediaStream;
		try {
			stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
		} catch {
			setState("idle");
			setMessage(isRTL ? "اسمح باستخدام المايكروفون من إعدادات المتصفح." : "Allow the microphone in browser settings.");
			return;
		}
		/* Let go while the permission prompt was up: nothing to record yet. */
		if (!pressedRef.current) {
			stream.getTracks().forEach((t) => t.stop());
			setState("idle");
			setMessage(isRTL ? "اضغط مطولًا وتكلم، ثم ارفع إصبعك." : "Hold, speak, then let go.");
			return;
		}
		streamRef.current = stream;
		const mime = pickRecordingMime((t) => MediaRecorder.isTypeSupported(t));
		let rec: MediaRecorder;
		try {
			rec = new MediaRecorder(stream, mime ? { mimeType: mime, audioBitsPerSecond: 48_000 } : { audioBitsPerSecond: 48_000 });
		} catch {
			release();
			setState("idle");
			setMessage(isRTL ? "تعذّر بدء التسجيل." : "Could not start recording.");
			return;
		}
		const chunks: Blob[] = [];
		rec.ondataavailable = (e) => {
			if (e.data && e.data.size) chunks.push(e.data);
		};
		rec.onstop = () => {
			const ms = Math.min(CLIP_MAX_MS, Date.now() - startedRef.current);
			release();
			recRef.current = null;
			if (cancelledRef.current) return setState("idle");
			if (ms < CLIP_MIN_MS || !chunks.length) {
				setState("idle");
				setMessage(isRTL ? "اضغط مطولًا وتكلم، ثم ارفع إصبعك." : "Hold, speak, then let go.");
				return;
			}
			const type = rec.mimeType || mime || chunks[0].type || "audio/webm";
			void send(new Blob(chunks, { type }), ms);
		};
		recRef.current = rec;
		rec.start();
		startedRef.current = Date.now();
		setElapsed(0);
		setState("recording");
		try {
			navigator.vibrate?.(30);
		} catch {
			/* */
		}
		autoStopRef.current = window.setTimeout(() => end(), CLIP_MAX_MS);
	};

	const end = () => {
		pressedRef.current = false;
		const rec = recRef.current;
		if (rec && rec.state !== "inactive") {
			try {
				rec.stop();
			} catch {
				release();
				setState("idle");
			}
		}
	};

	const left = Math.max(0, Math.ceil((CLIP_MAX_MS - elapsed) / 1000));
	const label =
		state === "recording"
			? isRTL ? `يسجّل… ارفع إصبعك للإرسال · ${formatNumber(left, true)} ث` : `Recording… let go to send · ${left}s`
			: state === "sending"
				? isRTL ? "يرسل…" : "Sending…"
				: state === "arming"
					? isRTL ? "المايكروفون…" : "Microphone…"
					: isRTL ? "اضغط وتكلم" : "Hold to talk";

	return (
		<div className="sary-o-ptt-wrap">
			{message ? (
				<p className="sary-o-ptt-msg" role="status" data-testid="outing-ptt-message">
					{message}
				</p>
			) : null}
			<button
				type="button"
				className="sary-o-ptt"
				data-state={state}
				data-testid="outing-ptt"
				disabled={disabled || state === "sending"}
				aria-label={label}
				aria-pressed={state === "recording"}
				onPointerDown={(e) => {
					e.preventDefault();
					try {
						e.currentTarget.setPointerCapture(e.pointerId);
					} catch {
						/* */
					}
					void begin();
				}}
				onPointerUp={end}
				onPointerCancel={end}
				onKeyDown={(e) => {
					if ((e.key === " " || e.key === "Enter") && !e.repeat) {
						e.preventDefault();
						void begin();
					}
				}}
				onKeyUp={(e) => {
					if (e.key === " " || e.key === "Enter") end();
				}}
				onContextMenu={(e) => e.preventDefault()}
			>
				<Mic className="size-6" aria-hidden />
				<span>{label}</span>
				{state === "recording" ? <i className="sary-o-ptt-bar" style={{ width: `${Math.min(100, (elapsed / CLIP_MAX_MS) * 100)}%` }} aria-hidden="true" /> : null}
			</button>
		</div>
	);
}

/* A 0.05 s silent WAV, played inside the first tap so this page may play sound later (iOS, Chrome). */
const SILENT_WAV = "data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=";

export type VoiceChip = { clip: ClipMeta; name: string; color: string; state: "waiting" | "loading" | "playing" | "played" | "unplayable" | "gone" };

/**
 * Incoming clips. Recipients auto-play only after they have touched the page
 * once (browser autoplay rules); until then each clip waits behind a ▶.
 */
export function useVoiceInbox(view: OutingView | null, meId: string | undefined, names: (id: string) => { name: string; color: string }) {
	const audioRef = useRef<HTMLAudioElement | null>(null);
	const [unlocked, setUnlocked] = useState(false);
	const [states, setStates] = useState<Map<string, VoiceChip["state"]>>(new Map());
	const seenRef = useRef<Set<string> | null>(null);
	const queueRef = useRef<ClipMeta[]>([]);
	const playingRef = useRef(false);
	const [tick, setTick] = useState(0);
	const unlockedRef = useRef(false);

	const audio = () => {
		if (!audioRef.current && typeof Audio !== "undefined") {
			audioRef.current = new Audio();
			audioRef.current.preload = "auto";
		}
		return audioRef.current;
	};

	const setState = (id: string, s: VoiceChip["state"]) =>
		setStates((prev) => {
			if (prev.get(id) === s) return prev;
			const next = new Map(prev);
			next.set(id, s);
			return next;
		});

	/* The first tap anywhere unlocks sound for the rest of the outing. */
	useEffect(() => {
		const unlock = () => {
			if (unlockedRef.current) return;
			unlockedRef.current = true;
			setUnlocked(true);
			const a = audio();
			if (a) {
				a.src = SILENT_WAV;
				void a.play().catch(() => undefined);
			}
		};
		document.addEventListener("pointerdown", unlock, { capture: true });
		document.addEventListener("keydown", unlock, { capture: true });
		return () => {
			document.removeEventListener("pointerdown", unlock, { capture: true });
			document.removeEventListener("keydown", unlock, { capture: true });
		};
	}, []);

	useEffect(
		() => () => {
			const a = audioRef.current;
			if (a) {
				a.pause();
				if (a.src.startsWith("blob:")) URL.revokeObjectURL(a.src);
			}
		},
		[],
	);

	const playClip = useCallback(async (clip: ClipMeta) => {
		const a = audio();
		if (!a) return;
		if (!playable(clip.mime, (t) => a.canPlayType(t))) {
			setState(clip.id, "unplayable");
			return;
		}
		playingRef.current = true;
		setState(clip.id, "loading");
		try {
			const blob = await OutingsApi.fetchClip(clip.url);
			const url = URL.createObjectURL(blob);
			if (a.src.startsWith("blob:")) URL.revokeObjectURL(a.src);
			a.src = url;
			await new Promise<void>((resolve, reject) => {
				a.onended = () => resolve();
				a.onerror = () => reject(new Error("decode"));
				a.play().then(() => setState(clip.id, "playing"), reject);
			});
			setState(clip.id, "played");
		} catch (e) {
			setState(clip.id, e instanceof OutingApiError && e.code === "clip_gone" ? "gone" : (a.error ? "unplayable" : "waiting"));
		} finally {
			playingRef.current = false;
			setTick((n) => n + 1);
		}
	}, []);

	/* New clips: queue them; play in order once sound is unlocked. */
	const clips = view?.snapshot.voice_clips || [];
	useEffect(() => {
		if (!view) return;
		const now = serverNow(view);
		if (seenRef.current === null) {
			/* Whatever was already there when the screen opened is not news. */
			seenRef.current = new Set(clips.map((c) => c.id));
			for (const c of clips) if (c.user_id !== meId) setState(c.id, "waiting");
			return;
		}
		for (const c of newClipsToPlay(clips, seenRef.current, meId, now)) {
			seenRef.current.add(c.id);
			queueRef.current.push(c);
			setState(c.id, "waiting");
			try {
				navigator.vibrate?.([80, 40, 80]);
			} catch {
				/* */
			}
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [clips, meId]);

	useEffect(() => {
		if (!unlocked || playingRef.current) return;
		const next = queueRef.current.shift();
		if (next) void playClip(next);
	}, [unlocked, tick, clips, playClip]);

	const now = view ? serverNow(view) : Date.now();
	const chips = new Map<string, VoiceChip>();
	for (const [uid, clip] of liveChips(clips, meId, now)) {
		const who = names(uid);
		chips.set(uid, { clip, name: who.name, color: who.color, state: states.get(clip.id) || "waiting" });
	}

	/** A tap on a chip plays it now (and, being a tap, unlocks sound too). */
	const play = (clip: ClipMeta) => {
		queueRef.current = queueRef.current.filter((c) => c.id !== clip.id);
		if (!playingRef.current) void playClip(clip);
	};

	return { chips, unlocked, play };
}

/** «رسالة صوتية من سعد» — the newest one, as a banner the person can tap. */
export function VoiceBanner({ chip, isRTL, onPlay }: { chip: VoiceChip; isRTL: boolean; onPlay: () => void }) {
	const secs = clipSeconds(chip.clip.duration_ms);
	const status =
		chip.state === "playing"
			? isRTL ? "يُشغَّل الآن" : "Playing"
			: chip.state === "loading"
				? isRTL ? "يحمّل…" : "Loading…"
				: chip.state === "played"
					? isRTL ? "اضغط لإعادة السماع" : "Tap to replay"
					: chip.state === "unplayable"
						? isRTL ? "جهازك لا يشغّل هذه الصيغة" : "This device cannot play it"
						: chip.state === "gone"
							? isRTL ? "انتهت صلاحيتها" : "Expired"
							: isRTL ? "اضغط للاستماع" : "Tap to listen";
	return (
		<button
			type="button"
			className="sary-o-voice"
			style={{ "--car": chip.color } as React.CSSProperties}
			onClick={onPlay}
			disabled={chip.state === "unplayable" || chip.state === "gone" || chip.state === "loading"}
			data-testid="outing-voice-alert"
			data-state={chip.state}
			data-user={chip.clip.user_id}
		>
			<span aria-hidden="true">{chip.state === "playing" ? "🔊" : "▶"}</span>
			<strong>{isRTL ? `رسالة صوتية من ${chip.name}` : `Voice message from ${chip.name}`}</strong>
			<small>
				{isRTL ? `${formatNumber(secs, true)} ث` : `${secs}s`} · {status}
			</small>
		</button>
	);
}
