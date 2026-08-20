import { describe, expect, it } from "vitest";
import {
	SEARCH_SYNONYMS,
	expandQuery,
	highlightRanges,
	matchesQuery,
	normalizeSearchText,
} from "./farqTextSearch";

/* الحقول الثلاثة اللي تُبحث فعلاً على الخريطة */
const row = (name: string, name_en?: string | null, product_name?: string | null) => [name, name_en, product_name];

describe("farq text search", () => {
	it("normalises exactly like the API's normalizeArabic — same strings apps/api/lib/copilot.test.js pins", () => {
		expect(normalizeSearchText("أبي ٥ فرصٍ فوق ٢٠؟")).toBe("ابي 5 فرص فوق 20");
		expect(normalizeSearchText("قهوة إسبريسو، مَعَ تطويــل")).toBe("قهوه اسبريسو مع تطويل");
		expect(normalizeSearchText("هنقرستيشن ولا جاهز؟")).toBe("هنقرستيشن ولا جاهز");
		expect(normalizeSearchText("  Al-Olaya  ")).toBe("al-olaya");
		expect(normalizeSearchText("")).toBe("");
		/* همزة الواو والياء تبقى كما هي هنا — الطي للبحث فقط، عشان ما نفترق عن الـAPI */
		expect(normalizeSearchText("لؤلؤ")).toBe("لؤلؤ");
	});

	it("finds برغر for من كتب برجر, and Burger too", () => {
		expect(matchesQuery(row("برغر لحم", null, "برغر دبل"), "برجر")).toBe(true);
		expect(matchesQuery(row("مطعم", "Burger House", null), "برجر")).toBe(true);
		expect(matchesQuery(row("برقر ستيشن"), "برجر")).toBe(true);
		expect(matchesQuery(row("همبرجر الحي"), "برجر")).toBe(true);
		/* والاتجاه العكسي كذلك */
		expect(matchesQuery(row("برجر الحي"), "burger")).toBe(true);
		expect(matchesQuery(row("برجر الحي"), "همبرجر")).toBe(true);
	});

	it("closes the spelling gaps people actually type", () => {
		expect(matchesQuery(row("قهوة الصباح"), "قهوه")).toBe(true);
		expect(matchesQuery(row("كافيه الحي"), "قهوة")).toBe(true);
		expect(matchesQuery(row("شورما عربي"), "شاورما")).toBe(true);
		expect(matchesQuery(row("حلويات الشرق"), "حلى")).toBe(true);
		expect(matchesQuery(row("بروست الرياض"), "دجاج")).toBe(true);
		expect(matchesQuery(row("سندويش تونه"), "ساندويتش")).toBe(true);
		expect(matchesQuery(row("مكرونة بالجبن"), "باستا")).toBe(true);
		expect(matchesQuery(row("جمبري مشوي"), "سمك")).toBe(true);
		expect(matchesQuery(row("بوكس دجاج"), "box")).toBe(true);
		/* الأرقام: عربية أو إنجليزية، نفس الشي */
		expect(matchesQuery(row("5 قطع"), "٥ قطع")).toBe(true);
		expect(matchesQuery(row("٥ قطع"), "5 قطع")).toBe(true);
		/* أيس/ايس — الهمزة تُطبَّع على الجهتين */
		expect(matchesQuery(row("أيس كريم"), "ايس")).toBe(true);
		/* همزة الواو تُطوى للبحث وحده */
		expect(matchesQuery(row("مشويات اللؤلؤة"), "اللولوه")).toBe(true);
	});

	it("does not match everything: an unknown word filters, a blank query does not", () => {
		expect(matchesQuery(row("برغر لحم", "Burger House"), "سوشي")).toBe(false);
		expect(matchesQuery(row("برغر لحم"), "أتلانتس")).toBe(false);
		/* كلمة ما نعرفها تبحث عن نفسها فقط */
		expect(expandQuery("أتلانتس")).toEqual(["اتلانتس"]);
		expect(matchesQuery(row("مطعم أتلانتس"), "أتلانتس")).toBe(true);
		for (const blank of ["", "   ", "؟"]) {
			expect(matchesQuery(row("أي مطعم"), blank), blank).toBe(true);
			expect(expandQuery(blank), blank).toEqual([]);
		}
		/* حقول فاضية ما تنهار */
		expect(matchesQuery([null, undefined, ""], "برجر")).toBe(false);
		expect(matchesQuery([null, undefined, ""], "")).toBe(true);
	});

	it("expands a query to its siblings, itself first, without repeats", () => {
		const terms = expandQuery("برجر");
		expect(terms[0]).toBe("برجر");
		expect(terms).toContain("برغر");
		expect(terms).toContain("burger");
		expect(new Set(terms).size).toBe(terms.length);
		/* لغة الاستعلام ما تهم: كل مفتاح يشوف نفس المجموعة */
		expect(new Set(expandQuery("burger"))).toEqual(new Set(terms));
		/* جملة ما نوسّعها كلمة كلمة — "برجر لحم" ما يصح يطابق كل ما فيه لحم */
		expect(expandQuery("برجر لحم")).toEqual(["برجر لحم"]);
		expect(matchesQuery(row("لحم مفروم"), "برجر لحم")).toBe(false);
	});

	it("carries the API's CATEGORY_GROUPS ids and terms, so the two sides say the same thing", () => {
		/* المعرّفات والمصطلحات من apps/api/lib/copilot-intent.js */
		const apiTerms: Record<string, string[]> = {
			burgers: ["برجر", "برغر", "burger"],
			pizza: ["بيتزا", "pizza"],
			coffee: ["قهوه", "كوفي", "كافيه", "لاتيه", "اسبريسو", "coffee", "latte"],
			shawarma: ["شاورما", "shawarma"],
			chicken: ["بروستد", "دجاج", "فرايد تشكن", "تشكن", "chicken"],
			sushi: ["سوشي", "sushi"],
			desserts: ["حلا", "حلى", "كيك", "كيكه", "دونات", "ايس كريم", "dessert", "cake"],
			sandwiches: ["ساندويتش", "ساندوتش", "سندويش", "sandwich"],
			breakfast: ["فطور", "فول", "breakfast"],
			juice: ["عصير", "juice", "smoothie"],
			pasta: ["باستا", "معكرونه", "pasta"],
			seafood: ["سمك", "روبيان", "جمبري", "seafood", "fish"],
			grill: ["مشاوي", "مشويات", "كباب", "grill", "kebab"],
			grocery: ["بقاله", "تموين", "سوبرماركت", "grocery"],
		};
		for (const [id, terms] of Object.entries(apiTerms)) {
			for (const term of terms) {
				const key = normalizeSearchText(term);
				expect(SEARCH_SYNONYMS[key], `${id}: ${term}`).toBeTruthy();
				/* كل مصطلحات المجموعة الواحدة تشوف بعض */
				expect(new Set(expandQuery(term)), `${id}: ${term}`).toEqual(new Set(expandQuery(terms[0])));
			}
		}
	});

	it("gives back ranges in the ORIGINAL text, diacritics and all", () => {
		const cut = (text: string, q: string) => highlightRanges(text, q).map(([s, e]) => text.slice(s, e));

		expect(highlightRanges("برغر لحم", "برجر")).toEqual([[0, 4]]);
		expect(cut("برغر لحم", "برجر")).toEqual(["برغر"]);
		expect(cut("Hood Burger", "برجر")).toEqual(["Burger"]);

		/* النص الأصلي فيه تشكيل — الحذف ما يزحزح الخريطة */
		const shifted = "قَهوة إسبريسو";
		const [range] = highlightRanges(shifted, "قهوه");
		expect(shifted.slice(range[0], range[1])).toBe("قَهوة");
		expect(normalizeSearchText(shifted.slice(range[0], range[1]))).toBe("قهوه");

		/* أرقام عربية ومسافات مكرَّرة ما تكسر المواضع */
		const digits = "عرض   ٥ قطع";
		expect(cut(digits, "٥ قطع")).toEqual(["٥ قطع"]);

		/* كل ظهور، والمترادف كذلك، مدموجة ومرتَّبة */
		expect(cut("قهوة و قهوه", "قهوه")).toEqual(["قهوة", "قهوه"]);
		expect(cut("كافيه القهوة", "قهوه")).toEqual(["كافيه", "قهوة"]);

		/* لا مطابقة، لا استعلام، لا نص = لا مواضع */
		expect(highlightRanges("برغر لحم", "سوشي")).toEqual([]);
		expect(highlightRanges("برغر لحم", "")).toEqual([]);
		expect(highlightRanges("", "برجر")).toEqual([]);
	});
});
