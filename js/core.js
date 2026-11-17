(function (root) {
  function round(value, digits = 2) {
    const scale = 10 ** digits;
    return Math.round((Number(value) + Number.EPSILON) * scale) / scale;
  }

  function feeFromCoverage(coverage) {
    const value = Number(coverage);
    if (!Number.isFinite(value)) return 0;
    if (value < 1) return Math.min(0.2, Math.max(0, 0.005 + (1 - value) * 0.2));
    if (value < 2) return Math.max(0, 0.005 * (2 - value));
    return 0;
  }

  function coverage(users, targetRate) {
    const rate = Number(targetRate);
    const list = Array.isArray(users) ? users : [];
    const tokens = list.reduce((sum, user) => sum + Number(user.scrl || 0) + Number(user.holdScrl || 0), 0);
    const vrub = list.reduce((sum, user) => sum + Number(user.vrub || 0) + Number(user.holdVrub || 0), 0);
    const limit = rate > 0 ? vrub / rate : 0;
    const ratio = tokens > 0 && rate > 0 ? vrub / (tokens * rate) : 0;
    return { tokens: round(tokens), vrub: round(vrub), limit: round(limit), ratio: round(ratio, 4) };
  }

  function vwap(trades, from, fallback) {
    const list = (Array.isArray(trades) ? trades : []).filter(trade =>
      Number(trade.date) >= Number(from) && Number(trade.qty) > 0 && Number(trade.price) > 0
    );
    const qty = list.reduce((sum, trade) => sum + Number(trade.qty), 0);
    const value = list.reduce((sum, trade) => sum + Number(trade.qty) * Number(trade.price), 0);
    return qty > 0 ? round(value / qty, 4) : round(Number(fallback || 0), 4);
  }

  function fill(buy, sell, qty, rate) {
    const amount = Number(qty);
    const buyPrice = Number(buy?.price);
    const sellPrice = Number(sell?.price);
    const feeRate = Number(rate);
    if (!buy || !sell || !Number.isFinite(amount) || !(amount > 0) ||
        !Number.isFinite(buyPrice) || !Number.isFinite(sellPrice) ||
        buyPrice <= 0 || sellPrice <= 0 || buyPrice < sellPrice ||
        !Number.isFinite(feeRate) || feeRate < 0 || feeRate > 1) {
      throw new Error("Некорректная встречная заявка.");
    }
    const price = Number(sell.date) <= Number(buy.date) ? sellPrice : buyPrice;
    const reserved = round(amount * Number(buy.price));
    const cost = round(amount * price);
    const fee = round(amount * Number(rate));
    return {
      price: round(price, 4),
      reserved,
      cost,
      refund: round(Math.max(0, reserved - cost)),
      fee,
      tokens: round(Math.max(0, amount - fee))
    };
  }

  function exchange(side, amount, price, rate) {
    const qty = Number(amount), unit = Number(price), feeRate = Number(rate);
    if (!Number.isSafeInteger(qty) || qty < 1 || qty > 1000000 ||
        !Number.isFinite(unit) || unit < 0.0001 || unit > 10000 ||
        !Number.isFinite(feeRate) || feeRate < 0 || feeRate > 1) {
      throw new Error("Некорректная заявка на обмен.");
    }
    if (side !== "scrlSell" && side !== "vrubSell") throw new Error("Неизвестное направление обмена.");
    const cost = round(qty * unit);
    if (cost < 0.01) throw new Error("Сумма заявки после округления должна быть не меньше 0,01 единицы встречной валюты.");
    if (side === "scrlSell") {
      const fee = round(qty * feeRate);
      return {
        buyerPays: cost, buyerPaysIn: "V-RUB",
        buyerGets: round(Math.max(0, qty - fee)), buyerGetsIn: "ScRl",
        sellerGets: cost, sellerGetsIn: "V-RUB", fee, feeIn: "ScRl"
      };
    }
    const fee = round(cost * feeRate);
    return {
      buyerPays: cost, buyerPaysIn: "ScRl",
      buyerGets: round(qty), buyerGetsIn: "V-RUB",
      sellerGets: round(Math.max(0, cost - fee)), sellerGetsIn: "ScRl", fee, feeIn: "ScRl"
    };
  }

  function settlement(amount, rate, mode, share = 1) {
    const value = Number(amount);
    const feeRate = Number(rate);
    if (!Number.isFinite(value) || value < 0) throw new Error("Некорректная сумма сделки.");
    if (!Number.isFinite(feeRate) || feeRate < 0 || feeRate > 1) throw new Error("Некорректная комиссия.");
    const total = round(value);
    if (mode === "refund") return { gross: 0, fee: 0, seller: 0, buyer: total };
    if (mode !== "pay" && mode !== "split") throw new Error("Неизвестный тип завершения.");
    const shareValue = Number(share);
    if (mode === "split" && !Number.isFinite(shareValue)) throw new Error("Некорректная доля выплаты.");
    const part = mode === "split" ? Math.min(1, Math.max(0, shareValue)) : 1;
    const gross = round(total * part);
    const fee = round(gross * feeRate);
    return {
      gross,
      fee,
      seller: round(gross - fee),
      buyer: round(total - gross)
    };
  }

  const api = { round, feeFromCoverage, coverage, vwap, fill, exchange, settlement };
  root.ScrlCore = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
