/**
 * Grocery compare is product-level. TanStack /grocery always needs an explicit
 * `q`. A restaurant name from the map is not a SKU — stamping it into search
 * would print a storefront on a page that refuses to invent storefronts.
 */
export function groceryCompareSearch(): { q: undefined } {
	return { q: undefined };
}
