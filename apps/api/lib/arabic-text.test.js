'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
	normalizeArabic,
	nameTokens,
	matchKey,
	scriptOf,
	splitBranchQualifier,
} = require('./arabic-text');

test('arabic normalization — the variants people actually type', async (t) => {
	await t.test('folds ta marbuta, so الروضه finds الروضة', () => {
		assert.equal(matchKey('الروضة'), matchKey('الروضه'));
	});

	await t.test('folds alif maqsura, so مستشفي finds مستشفى', () => {
		assert.equal(matchKey('مستشفى'), matchKey('مستشفي'));
	});

	await t.test('folds every alif and hamza carrier', () => {
		assert.equal(normalizeArabic('أحمد'), normalizeArabic('احمد'));
		assert.equal(normalizeArabic('إبراهيم'), normalizeArabic('ابراهيم'));
		assert.equal(normalizeArabic('مؤسسة'), 'موسسه');
		assert.equal(normalizeArabic('سائق'), 'سايق');
	});

	await t.test('strips diacritics and tatweel', () => {
		assert.equal(normalizeArabic('الرِّيَاض'), 'الرياض');
		assert.equal(normalizeArabic('الــرياض'), 'الرياض');
	});

	await t.test('folds both Arabic-Indic digit systems to ASCII', () => {
		/* The extended set (۰-۹) is the one a local copy of this normalizer used
		 * to miss, which made «حي ۵ نجوم» unfindable while the same text worked
		 * elsewhere in the product. */
		assert.equal(normalizeArabic('١٢٣'), '123');
		assert.equal(normalizeArabic('۵۶۷'), '567');
	});

	await t.test('resolves Arabic presentation forms, which arrive from PDFs and look identical', () => {
		assert.equal(normalizeArabic('ﺣﻲ ﺍﻟﻨﺮﺟﺲ'), 'حي النرجس');
		/* The lam-alef ligature is one code point that must become two. */
		assert.equal(normalizeArabic('ﻻ'), 'لا');
	});

	await t.test('removes invisible bidi controls', () => {
		assert.equal(normalizeArabic('حي النرجس‏'), 'حي النرجس');
		assert.equal(normalizeArabic('‫النرجس‬'), 'النرجس');
	});

	await t.test('collapses three-or-more letter repetition but leaves doubling alone', () => {
		assert.equal(normalizeArabic('كووول'), 'كول');
		assert.equal(normalizeArabic('coffee'), 'coffee');
	});

	await t.test('maps Perso-Arabic letters onto their Arabic equivalents', () => {
		assert.equal(normalizeArabic('کافيه'), normalizeArabic('كافيه'));
		assert.equal(normalizeArabic('ڤانيلا'), 'فانيلا');
	});

	await t.test('punctuation separates rather than joins', () => {
		assert.equal(normalizeArabic('dr.paws'), 'dr paws');
		assert.equal(normalizeArabic('بنك-الراجحي'), 'بنك الراجحي');
	});

	await t.test('missing input is empty, never a crash', () => {
		assert.equal(normalizeArabic(null), '');
		assert.equal(normalizeArabic(undefined), '');
		assert.equal(normalizeArabic(''), '');
	});
});

test('tokens for comparison', async (t) => {
	await t.test('a type word says what kind, not which one', () => {
		assert.equal(matchKey('حي النرجس'), matchKey('النرجس'));
		assert.equal(matchKey('شارع الملك فهد'), matchKey('الملك فهد'));
	});

	await t.test('venue words carry no information in a corpus of restaurants', () => {
		assert.equal(matchKey('مطعم البيك'), matchKey('البيك'));
		/* And stripping them must not make two different places look alike. */
		assert.notEqual(matchKey('مطعم الشرق'), matchKey('مطعم الغرب'));
	});

	await t.test('the definite article is folded as a variant', () => {
		assert.deepEqual(nameTokens('الروضة'), ['روضه']);
		/* Short tokens keep it — «الف» is not «ف». */
		assert.deepEqual(nameTokens('ابن'), ['ابن']);
	});

	await t.test('a name made only of type words has no identity', () => {
		assert.deepEqual(nameTokens('مطعم'), []);
		assert.equal(matchKey('حي'), '');
	});
});

test('branch qualifier splitting', async (t) => {
	await t.test('separates the chain from the branch it names', () => {
		assert.deepEqual(splitBranchQualifier('ترندي كيك - Al Yarmuk'),
			{ brand: 'ترندي كيك', branch: 'Al Yarmuk' });
		assert.deepEqual(splitBranchQualifier('مامولا - الملقا، الرياض'),
			{ brand: 'مامولا', branch: 'الملقا، الرياض' });
	});

	await t.test('a hyphen inside a word is part of the name', () => {
		assert.deepEqual(splitBranchQualifier('بن-دايت'), { brand: 'بن-دايت', branch: '' });
	});

	await t.test('no separator means the whole string is the brand', () => {
		assert.deepEqual(splitBranchQualifier('ستاربكس'), { brand: 'ستاربكس', branch: '' });
	});
});

test('script detection', async (t) => {
	await t.test('Arabic-Indic digits are an Arabic signal, ASCII digits are neutral', () => {
		/* Measured elsewhere: device locale is a poor proxy for query language —
		 * 45% of queries from English-locale devices were Arabic script. */
		assert.equal(scriptOf('٩'), 'ar');
		assert.equal(scriptOf('9'), 'none');
	});

	await t.test('mixed script is its own answer, not a guess', () => {
		assert.equal(scriptOf('مقهى volume'), 'mixed');
		assert.equal(scriptOf('النرجس'), 'ar');
		assert.equal(scriptOf('Narjis'), 'en');
	});
});


/**
 * The contract between this normalizer and its hand-kept copy in
 * apps/web/src/lib/farqDistrictSearch.ts. The web cannot import the server's
 * CommonJS, so parity is held by these vectors appearing verbatim in both test
 * files: change one side and the other fails.
 *
 * Before the copy was made a mirror, the two disagreed on 7 of 17 real inputs.
 */
const PARITY_VECTORS = [
	["حي النرجس", "النرجس"],
	["ﺣﻲ ﺍﻟﻨﺮﺟﺲ", "النرجس"],
	["حي ۵ نجوم", "5 نجوم"],
	["حي ٥ نجوم", "5 نجوم"],
	["Al Narjās", "al narjas"],
	["الشهداء", "الشهدا"],
	["مؤسسة", "موسسه"],
	["سائق", "سايق"],
	["كووول", "كول"],
	["کافيه", "كافيه"],
	["الرِّيَاض", "الرياض"],
	["الــرياض", "الرياض"],
	["بنك-الراجحي", "بنك الراجحي"]
];

test('normalization parity with the web district picker', async (t) => {
	await t.test('every shared vector normalizes to the agreed value', () => {
		for (const [input, expected] of PARITY_VECTORS) {
			/* The picker strips the type word; this normalizer keeps it, so the
			 * comparison drops it here in the same way the picker does. */
			assert.equal(normalizeArabic(input).replace(/^حي /, ''), expected,
				`${JSON.stringify(input)} must normalize to ${JSON.stringify(expected)}`);
		}
	});
});
