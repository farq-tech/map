'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const {
  INSUFFICIENT_COMPARISON_AR,
  FORECAST_REFUSAL_AR,
  classifyQuestion,
  refuseForecast,
  applyReplyPolicy,
  formatObservedReply,
  replyUsesOnlyToolNumbers,
} = require('./chat-policy');

describe('chat-policy', () => {
  it('classifies forecast intent and refuses before the model', () => {
    assert.equal(classifyQuestion('كم بيصير سعر البرجر بعد شهر؟'), 'forecast');
    assert.equal(classifyQuestion('forecast the price tomorrow'), 'forecast');
    assert.equal(classifyQuestion('توقع سعر البيك بكرة'), 'forecast');
    assert.equal(refuseForecast(), FORECAST_REFUSAL_AR);
  });

  it('does not treat map interpretation questions as forecasts', () => {
    assert.equal(classifyQuestion('وين أكبر فرق؟'), 'map');
    assert.equal(classifyQuestion('وش الأرخص حولي؟'), 'map');
    assert.equal(classifyQuestion('ليش هذي فرصة قوية؟'), 'map');
    assert.equal(classifyQuestion('قارن لي الخيارات الظاهرة'), 'map');
  });

  it('rejects invented prices that are not in the tool JSON', () => {
    const rows = [
      {
        place: 'شاورما هوم',
        cheapest_price: 18,
        highest_price: 29,
        difference_amount: 11,
      },
    ];
    assert.equal(replyUsesOnlyToolNumbers('أكبر فرق ١١ ر.س عند شاورما هوم', rows), true);
    assert.equal(
      replyUsesOnlyToolNumbers('البيك أرخص بـ 45 ريال وراح يصير 12', rows),
      false,
    );
    assert.equal(
      applyReplyPolicy('السعر بعد أسبوع 99 ريال', rows),
      INSUFFICIENT_COMPARISON_AR,
    );
  });

  it('empty or incomplete tool JSON uses the insufficient-comparison sentence', () => {
    assert.equal(applyReplyPolicy('أي كلام', []), INSUFFICIENT_COMPARISON_AR);
  });

  it('observed fallback names only tool JSON facts', () => {
    const text = formatObservedReply([
      {
        place: 'برجر ستيشن',
        item: 'برجر كلاسيك',
        cheapest_provider: 'hungerstation',
        expensive_provider: 'jahez',
        cheapest_price: 19,
        highest_price: 28,
        difference_amount: 9,
      },
    ]);
    assert.match(text, /برجر ستيشن/);
    assert.match(text, /19/);
    assert.match(text, /9/);
    assert.equal(text.includes('البيك'), false);
  });
});

describe('observed numbers the templates already print', () => {
  it('lets the copilot pass its own draft — a percentage is an observed number too', () => {
    const rows = [{ cheapest_price: 110, highest_price: 190, difference_amount: 80, pct: 42, provider_count: 3 }];
    /* Verbatim what the templates write and what the model echoes back. */
    const draft = 'أكبر فرق مرصود في هذا النطاق: كيكة المانجو في رايت: 110.0 ر.س في نينجا — فرق 80 ر.س (42%)';
    assert.equal(replyUsesOnlyToolNumbers(draft, rows), true);
    assert.equal(replyUsesOnlyToolNumbers('على 3 تطبيقات', rows), true);
  });

  it('accepts an observed price at the precision the product prints it', () => {
    /* The templates render price() to one decimal: 109.95 reaches the screen
     * as "110.0", and refusing that made the copilot refuse its own draft. */
    const rows = [{ cheapest_price: 109.95, highest_price: 190, difference_amount: 80 }];
    assert.equal(replyUsesOnlyToolNumbers('السعر 110.0 ر.س', rows), true);
    assert.equal(replyUsesOnlyToolNumbers('السعر 109.95 ر.س', rows), true);
    assert.equal(replyUsesOnlyToolNumbers('السعر 111 ر.س', rows), false, 'a full riyal away is not rounding');
  });

  it('still refuses a number that is on no row — the guard is widened, not loosened', () => {
    const rows = [{ cheapest_price: 110, highest_price: 190, difference_amount: 80, pct: 42, provider_count: 3 }];
    assert.equal(replyUsesOnlyToolNumbers('وفر 999 ر.س الليلة', rows), false);
    assert.equal(replyUsesOnlyToolNumbers('النسبة 77%', rows), false);
  });
});
