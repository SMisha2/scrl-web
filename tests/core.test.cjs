const test = require("node:test");
const assert = require("node:assert/strict");
const core = require("../js/core.js");

test("комиссия зависит от покрытия", () => {
  assert.equal(core.feeFromCoverage(0), 0.2);
  assert.equal(core.feeFromCoverage(1), 0.005);
  assert.equal(core.feeFromCoverage(1.5), 0.0025);
  assert.equal(core.feeFromCoverage(2), 0);
});

test("покрытие считает свободные и удержанные остатки", () => {
  const out = core.coverage([
    { scrl: 80, holdScrl: 20, vrub: 40, holdVrub: 10 },
    { scrl: 50, holdScrl: 0, vrub: 30, holdVrub: 0 }
  ], 0.05);
  assert.equal(out.tokens, 150);
  assert.equal(out.vrub, 80);
  assert.equal(out.limit, 1600);
  assert.equal(out.ratio, 10.6667);
});

test("VWAP учитывает только сделки в окне", () => {
  const out = core.vwap([
    { qty: 10, price: 0.05, date: 100 },
    { qty: 10, price: 0.07, date: 200 },
    { qty: 100, price: 0.2, date: 20 }
  ], 100, 0.04);
  assert.equal(out, 0.06);
});

test("исполнение заявки возвращает разницу лимитной цены", () => {
  const out = core.fill(
    { price: 0.06, date: 200 },
    { price: 0.05, date: 100 },
    10,
    0.01
  );
  assert.deepEqual(out, {
    price: 0.05,
    reserved: 0.6,
    cost: 0.5,
    refund: 0.1,
    fee: 0.1,
    tokens: 9.9
  });
});

test("расчёт сделки корректен для выплаты, возврата и разделения", () => {
  assert.deepEqual(core.settlement(100, 0.01, "pay"), {
    gross: 100, fee: 1, seller: 99, buyer: 0
  });
  assert.deepEqual(core.settlement(100, 0.01, "refund"), {
    gross: 0, fee: 0, seller: 0, buyer: 100
  });
  assert.deepEqual(core.settlement(100, 0.01, "split", 0.5), {
    gross: 50, fee: 0.5, seller: 49.5, buyer: 50
  });
});

test("биржа отклоняет цену и комиссию вне диапазона", () => {
  assert.throws(() => core.fill({ price: -1, date: 1 }, { price: -2, date: 1 }, 10, 0.01));
  assert.throws(() => core.fill({ price: 0.06, date: 1 }, { price: 0.05, date: 2 }, 10, -0.01));
  assert.throws(() => core.fill({ price: 0.06, date: 1 }, { price: 0.05, date: 2 }, 10, 1.2));
});

test("разделение сделки проверяет долю и комиссию", () => {
  assert.throws(() => core.settlement(100, 0.01, "split", Number.NaN));
  assert.throws(() => core.settlement(100, 1.5, "pay"));
  assert.throws(() => core.settlement(-1, 0.01, "refund"));
});

test("продажа ScRl: покупатель платит V-RUB, комиссия удерживается в ScRl", () => {
  assert.deepEqual(core.exchange("scrlSell", 100, 0.05, 0.01), {
    buyerPays: 5, buyerPaysIn: "V-RUB",
    buyerGets: 99, buyerGetsIn: "ScRl",
    sellerGets: 5, sellerGetsIn: "V-RUB",
    fee: 1, feeIn: "ScRl"
  });
});

test("продажа V-RUB: покупатель платит ScRl и получает V-RUB", () => {
  assert.deepEqual(core.exchange("vrubSell", 10, 20, 0.01), {
    buyerPays: 200, buyerPaysIn: "ScRl",
    buyerGets: 10, buyerGetsIn: "V-RUB",
    sellerGets: 198, sellerGetsIn: "ScRl",
    fee: 2, feeIn: "ScRl"
  });
});

test("биржа отклоняет неизвестное направление и дробное количество", () => {
  assert.throws(() => core.exchange("wrong", 10, 1, 0.01));
  assert.throws(() => core.exchange("scrlSell", 1.5, 1, 0.01));
});
