'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const {
  extractPlace,
  extractQueryTerms,
  resolveChatSearch,
} = require('./chat-intent');

describe('chat-intent — source vs viewport', () => {
  it('extracts المغرزات and burger terms from أرخص برجر في المغرزات', () => {
    const q = 'أرخص برجر في المغرزات';
    assert.equal(extractPlace(q), 'المغرزات');
    assert.ok(extractQueryTerms(q).includes('برجر'));
    assert.ok(extractQueryTerms(q).includes('burger'));
    const plan = resolveChatSearch(q);
    assert.equal(plan.tool, 'search_source_opportunities');
    assert.equal(plan.bboxSource, 'place');
    assert.equal(plan.sort, 'cheapest');
    assert.equal(plan.place, 'المغرزات');
  });

  it('treats كل الرياض as city source, not a geocode of الرياض', () => {
    const plan = resolveChatSearch('ابحث في كل الرياض');
    assert.equal(plan.tool, 'search_source_opportunities');
    assert.equal(plan.bboxSource, 'city');
    assert.equal(plan.place, null);
  });

  it('uses user location for حولي when coords are present', () => {
    const plan = resolveChatSearch('أرخص مطعم حولي؟', {
      userLat: 24.71,
      userLng: 46.67,
    });
    assert.equal(plan.bboxSource, 'user');
    assert.equal(plan.tool, 'search_source_opportunities');
  });

  it('keeps viewport only when the user asks about هالنطاق', () => {
    const plan = resolveChatSearch('وين أكبر فرق بهالنطاق؟');
    assert.equal(plan.tool, 'get_visible_opportunities');
    assert.equal(plan.bboxSource, 'viewport');
  });

  it('defaults generic questions to the comparison source, not the camera', () => {
    const plan = resolveChatSearch('وين أكبر فرق؟');
    assert.equal(plan.tool, 'search_source_opportunities');
    assert.equal(plan.bboxSource, 'city');
  });
});
