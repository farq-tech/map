'use strict';

/**
 * «إذاعة الطلعة» — the live stations a trip may play, and the only ones.
 *
 * A trip's controller sends a station ID; the stream URL always comes from this
 * list, never from a phone, so nobody can make every phone in the trip fetch an
 * arbitrary URL. Every phone fetches the station's own public stream itself —
 * the server never fetches, proxies or rebroadcasts audio.
 *
 * Sources and licence notes: docs/GROUP-AUDIO.md. The iOS app ships the same
 * list (Sources/Media/GroupAudio/GroupAudioStations.swift) as its offline
 * fallback; GET /api/outings/group-audio/catalog serves this one so a station
 * can be fixed or removed without an app release.
 */

const STATIONS = [
  /* Quran first: إذاعة القرآن الكريم من مكة المكرمة (هيئة الإذاعة والتلفزيون). */
  { id: 'sba-quran', name: 'إذاعة القرآن الكريم', subtitle: 'من مكة المكرمة', group: 'quran',
    url: 'https://live.kwikmotion.com/sbrksaquranradiolive/ksaquranradio/chunks.m3u8', homepage: 'https://www.aloula.sa/ar/live/quranradio' },
  { id: 'sba-nidaa', name: 'إذاعة نداء الإسلام', subtitle: 'من مكة المكرمة', group: 'quran',
    url: 'https://live.kwikmotion.com/sbrksanidaalislamradiolive/ksanidaalislamradio/chunks.m3u8', homepage: 'https://www.aloula.sa/ar/live/nidaalislamadio' },
  { id: 'mp3quran-mix', name: 'إذاعة mp3quran', subtitle: 'تلاوات متنوعة', group: 'quran',
    url: 'https://qurango.net/radio/mix', homepage: 'https://www.mp3quran.net/ar/radio' },
  { id: 'mp3quran-tarateel', name: 'تراتيل قصيرة', subtitle: 'mp3quran', group: 'quran',
    url: 'https://qurango.net/radio/tarateel', homepage: 'https://www.mp3quran.net/ar/radio' },
  /* Saudi public radio (هيئة الإذاعة والتلفزيون — منصة «الأولى»). */
  { id: 'sba-riyadh', name: 'إذاعة الرياض', subtitle: 'هيئة الإذاعة والتلفزيون', group: 'saudi',
    url: 'https://live.kwikmotion.com/sbrksariyadhradiolive/ksariyadhradio/chunks.m3u8', homepage: 'https://www.aloula.sa/ar/live/riyadhradio' },
  { id: 'sba-jeddah', name: 'إذاعة جدة', subtitle: 'هيئة الإذاعة والتلفزيون', group: 'saudi',
    url: 'https://live.kwikmotion.com/sbrksajeddahradiolive/ksajeddahradio/chunks.m3u8', homepage: 'https://www.aloula.sa/ar/live/jeddahradio' },
  { id: 'sba-saudia', name: 'راديو السعودية', subtitle: 'هيئة الإذاعة والتلفزيون', group: 'saudi',
    url: 'https://live.kwikmotion.com/sbrksasaudiaradiolive/ksasaudiaradio/chunks.m3u8', homepage: 'https://www.aloula.sa/ar/live/saudiaradio' },
  { id: 'sba-khuzama', name: 'إذاعة خزامى', subtitle: 'هيئة الإذاعة والتلفزيون', group: 'saudi',
    url: 'https://live.kwikmotion.com/sbrksakhuzamaradiolive/khuzama/chunks.m3u8', homepage: 'https://www.aloula.sa/ar/live/khuzamaradio' },
  /* Popular FM — each station's own official stream host. */
  { id: 'mbc-fm', name: 'MBC FM', subtitle: 'أغاني خليجية وعربية', group: 'fm',
    url: 'https://radio-mbcfm.mbc.net/radio-mbcfm_1.m3u8', homepage: 'https://www.mbc.net/' },
  { id: 'panorama-fm', name: 'بانوراما FM', subtitle: 'MBC', group: 'fm',
    url: 'https://radio-panoramafm.mbc.net/radio-panoramafm_1.m3u8', homepage: 'https://www.mbc.net/' },
  { id: 'mbc-loud', name: 'MBC Loud FM', subtitle: 'MBC', group: 'fm',
    url: 'https://radio-loud-fm.mbc.net/radio-loud-fm.m3u8', homepage: 'https://mbcloud.fm/' },
  { id: 'alarabiya-fm', name: 'العربية FM', subtitle: 'أخبار', group: 'fm',
    url: 'https://fm.alarabiya.net/fm/myStream/playlist.m3u8', homepage: 'https://www.alarabiya.net/ar/fm' },
  { id: 'ufm', name: 'UFM 95.5', subtitle: 'الرياض', group: 'fm',
    url: 'https://stream.ufmradio.com:8003/', homepage: 'https://ufmradio.com/' },
];

const BY_ID = new Map(STATIONS.map((s) => [s.id, s]));

function station(id) {
  return typeof id === 'string' ? BY_ID.get(id) || null : null;
}

/* Recitations (one surah file) from mp3quran.net's own CDN — see docs/GROUP-AUDIO.md. */
const QURAN_URL = /^https:\/\/(cdn|server\d{1,2})\.mp3quran\.net\/(audio\/)?[a-z0-9_-]{2,60}\/(r\d{1,2}\/)?\d{3}\.mp3$/;

function quranUrl(raw) {
  return typeof raw === 'string' && raw.length <= 200 && QURAN_URL.test(raw) ? raw : null;
}

/* Audius track ids are short base-62 hash ids («1AXEE»). */
const AUDIUS_ID = /^[A-Za-z0-9]{1,16}$/;

function audiusId(raw) {
  return typeof raw === 'string' && AUDIUS_ID.test(raw) ? raw : null;
}

function catalog() {
  return STATIONS.map(({ id, name, subtitle, group, url, homepage }) => ({ id, name, subtitle, group, url, homepage }));
}

module.exports = { STATIONS, station, quranUrl, audiusId, catalog };
