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
