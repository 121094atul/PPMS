// ═══════════════════════════════════════════════════════════════════════════
// "Aaj ki shift" (Operations/TodayShift) — ek screen par poori shift.
//
// Shuru karne wala hissa (koi shift khuli nahi) sirf ek form hai — tareekh badalte
// hi page dobara khulta hai, taaki opening reading usi din ki aaye.
//
// Chalti shift: 4 kadam. Har cheez likhte-likhte jodi jaati hai aur neeche ki
// patti me dikhti hai: bikri, kitna cash aana chahiye, farak.
//
//   cash aana chahiye = bikri − udhaar − UPI − card
//                       − (Sales screen ke udhaar / UPI)          ← boot.cash.otherCredit / otherDigital
//                       + vasooli + daala − nikala − kharcha − bank ← boot.cash.adjust
//
// Ye wahi formula hai jo sp_Shift_Close lagata hai (opening cash chhod kar) —
// isliye band hone ke baad Shifts list me wahi farak aata hai.
//
// Draft: har badlav localStorage me (ppms-ts-<shiftId>). Phone band ho jaye ya
// galti se page chala jaye to bhara hua wapas aa jaata hai. Ye sirf ISI phone par
// rehta hai — UPI / udhaar "Paisa" kadam se aage badhte hi server par bhi save hote hain.
// ═══════════════════════════════════════════════════════════════════════════
(function () {
    'use strict';

    // ── Shuru karne wala form ──────────────────────────────────────────────
    var startForm = document.getElementById('tsStartForm');
    if (startForm) {
        var dateEl = document.getElementById('tsDate');
        if (dateEl) {
            dateEl.addEventListener('change', function () {
                if (!dateEl.value) { return; }
                var pump = startForm.querySelector('input[name="PumpId"]').value;
                window.location = '/Operations/TodayShift?pumpId=' + encodeURIComponent(pump) +
                    '&date=' + encodeURIComponent(dateEl.value);
            });
        }
        var editBtn = document.getElementById('tsEditOpening');
        if (editBtn) {
            editBtn.addEventListener('click', function () {
                startForm.querySelectorAll('.ts-open-in').forEach(function (el) { el.readOnly = false; });
                var gap = document.getElementById('tsGapWrap');
                if (gap) { gap.hidden = false; }
                editBtn.hidden = true;
                var first = startForm.querySelector('.ts-open-in');
                if (first) { first.focus(); }
            });
        }
        var editCash = document.getElementById('tsEditOpenCash');
        if (editCash) {
            editCash.addEventListener('click', function () {
                var inp = document.getElementById('tsOpenCash');
                inp.readOnly = false;
                inp.focus();
                editCash.hidden = true;
            });
        }
        return;
    }

    var B = window.TS_BOOT;
    var T = window.TS_T || {};
    if (!B) { return; }

    var KEY = 'ppms-ts-' + B.shiftId;
    var TEST_LIMIT = 5;

    function $(s, r) { return (r || document).querySelector(s); }
    function $$(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
    function num(el) {
        if (!el) { return null; }
        var v = parseFloat(el.value);
        return isNaN(v) ? null : v;
    }
    function rs(n) {
        var r = Math.round(Math.abs(n));
        return (n < 0 ? '−' : '') + '₹' + r.toLocaleString('en-IN');
    }
    // Ikai ke saath matra: "350.55 kg" / "940.85 L". Alag-alag ikai (kg aur L) kabhi jodte nahi.
    function qty(n, unit) {
        return n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' ' + (unit || 'L');
    }
    function qtyByUnit(noz) {
        var byUnit = {}, order = [];
        noz.forEach(function (n) {
            if (n.state !== 'ok' && n.state !== 'why') { return; }
            if (!(n.unit in byUnit)) { byUnit[n.unit] = 0; order.push(n.unit); }
            byUnit[n.unit] += n.net;
        });
        return order.map(function (u) { return qty(byUnit[u], u); }).join(' + ') || qty(0, 'L');
    }
    function fmt(s, v) { return (s || '').replace('{0}', v); }
    function nOfM(n, m) { return (T.nOfM || '{0} / {1}').replace('{0}', n).replace('{1}', m); }

    var cash = B.cash || {};
    var moneyDirty = false;
    var step = 1;
    var ack = { warn: false };

    var nozEls = $$('.ts-noz');
    var tankEls = $$('.ts-tank');
    var slipBox = $('#tsSlips');
    var slipTpl = $('#tsSlipTpl');
    var expTpl = $('#tsExpTpl');
    var hoTpl = $('#tsHoTpl');
    var cashEl = $('#tsCash');
    var upiEl = $('#tsUpi');
    var cardEl = $('#tsCard');
    var notesText = $('#tsNotesText');

    // ── 1. Meter ───────────────────────────────────────────────────────────
    function nozInfo(el) {
        var open = parseFloat(el.dataset.open) || 0;
        var rate = parseFloat(el.dataset.rate) || 0;
        var close = num($('.ts-close', el));
        var test = num($('.ts-test', el)) || 0;
        var why = $('.ts-why', el).value;
        var info = { el: el, id: +el.dataset.nozzle, code: el.dataset.code, open: open, rate: rate, close: close, test: test, why: why, unit: el.dataset.unit || 'L' };
        if (close === null) { info.state = 'empty'; info.net = 0; return info; }
        if (close < open) { info.state = 'less'; info.net = 0; return info; }
        info.net = close - open - test;
        if (info.net < -0.0005) { info.state = 'test'; info.net = 0; return info; }
        if (test > TEST_LIMIT && !why) { info.state = 'why'; return info; }
        info.state = 'ok';
        return info;
    }

    function renderNoz(el) {
        var i = nozInfo(el);
        var why = $('.ts-why', el);
        why.hidden = !(i.test > TEST_LIMIT);
        var err = $('.ts-err', el);
        var msg = i.state === 'less' ? T.closeLess : i.state === 'test' ? T.testTooMuch : i.state === 'why' ? T.whyNeeded : '';
        err.textContent = msg;
        err.hidden = !msg;
        el.classList.toggle('is-done', i.state === 'ok');
        el.classList.toggle('is-bad', i.state === 'less' || i.state === 'test');
        $('.ts-lit', el).textContent = i.state === 'ok' || i.state === 'why' ? qty(i.net, i.unit) : '—';
        $('.ts-amt', el).textContent = i.state === 'ok' || i.state === 'why' ? rs(i.net * i.rate) : '—';
        return i;
    }

    function allNoz() { return nozEls.map(nozInfo); }

    // ── 2. Dip ─────────────────────────────────────────────────────────────
    function tankInfo(el, noz) {
        var book = parseFloat(el.dataset.book) || 0;
        var ids = (el.dataset.nozzles || '').split(',').filter(Boolean);
        noz.forEach(function (n) { if (ids.indexOf(String(n.id)) >= 0) { book -= n.net; } });
        var act = num($('.ts-act', el));
        return { el: el, id: +el.dataset.tank, book: book, cm: num($('.ts-cm', el)), act: act, diff: act ? act - book : null };
    }

    function renderTanks(noz) {
        return tankEls.map(function (el) {
            var t = tankInfo(el, noz);
            $('.ts-book', el).textContent = t.book.toLocaleString('en-IN', { maximumFractionDigits: 2 });
            var d = $('.ts-diff', el);
            var w = $('.ts-dip-warn', el);
            if (t.diff === null) {
                d.textContent = '—'; d.className = 'ts-diff'; w.hidden = true;
                el.classList.remove('is-done');
                return t;
            }
            var a = Math.abs(t.diff);
            d.textContent = (t.diff > 0 ? '+' : '') + t.diff.toFixed(2) + ' L';
            d.className = 'ts-diff ' + (a <= 10 ? 'ts-ok' : a <= 30 ? 'ts-excess' : 'ts-short');
            // 09 Sep ko pichhle din ka litre likh diya tha - farak +910 aaya tha.
            w.textContent = T.bigDiff;
            w.hidden = a <= 100;
            el.classList.add('is-done');
            return t;
        });
    }

    // ── 3. Paisa: udhaar parchi ────────────────────────────────────────────
    function addSlip(s) {
        var node = slipTpl.content.firstElementChild.cloneNode(true);
        s = s || {};
        $('.ts-s-party', node).value = s.partyId ? String(s.partyId) : '';
        $('.ts-s-veh', node).value = s.vehicleNo || '';
        $('.ts-s-amt', node).value = s.amount ? s.amount : '';
        $('.ts-s-note', node).value = s.slipNote || '';
        if (s.prod) { $('.ts-s-prod', node).selectedIndex = s.prod; }
        slipBox.appendChild(node);
        return node;
    }

    function slips() {
        return $$('.ts-slip', slipBox).map(function (el) {
            return {
                partyId: parseInt($('.ts-s-party', el).value, 10) || 0,
                vehicleNo: $('.ts-s-veh', el).value.trim(),
                amount: num($('.ts-s-amt', el)) || 0,
                slipNote: $('.ts-s-note', el).value.trim(),
                prod: $('.ts-s-prod', el).selectedIndex
            };
        });
    }

    // Litre likho to rakam (us product ke shift wale rate se), aur note khaali ho
    // to "20 L Diesel" bhar do. Rakam seedha likho to litre khud nahi badalte.
    function slipLitres(el) {
        var l = num($('.ts-s-lit', el));
        var prod = $('.ts-s-prod', el);
        var rate = parseFloat(prod.value) || 0;
        if (l === null || !rate) { return; }
        $('.ts-s-amt', el).value = (l * rate).toFixed(2);
        var note = $('.ts-s-note', el);
        var opt = prod.options[prod.selectedIndex];
        var auto = l + ' ' + (opt.getAttribute('data-unit') || 'L') + ' ' + opt.text;
        if (!note.value || note.dataset.auto === '1') { note.value = auto; note.dataset.auto = '1'; }
    }

    // ── 3. Paisa: kharcha (seedha server par) ──────────────────────────────
    function renderExpenses(list) {
        var box = $('#tsExpList');
        if (!box) { return; }
        box.innerHTML = '';
        var total = 0;
        (list || []).forEach(function (e) {
            var node = expTpl.content.firstElementChild.cloneNode(true);
            $('.ts-e-head', node).textContent = e.expenseHeadName;
            $('.ts-e-note', node).textContent = e.narration || '';
            $('.ts-e-amt', node).textContent = rs(e.amount);
            $('.ts-e-del', node).dataset.id = e.id;
            box.appendChild(node);
            total += e.amount;
        });
        if (!list || list.length === 0) {
            box.innerHTML = '<div class="small text-muted"></div>';
            box.firstChild.textContent = T.noExpense;
        }
        $('#tsExpTotal').textContent = rs(total);
    }

    // ── 3. Paisa: galle se nikala nakad (malik ko diya / bank me jama), seedha server par ──
    function renderHandovers(list) {
        var box = $('#tsHoList');
        if (!box) { return; }
        box.innerHTML = '';
        var total = 0;
        (list || []).forEach(function (h) {
            var node = hoTpl.content.firstElementChild.cloneNode(true);
            $('.ts-h-kind', node).textContent = h.kind === 'BANK' ? T.kindBank : T.kindOwner;
            $('.ts-h-note', node).textContent = h.note || '';
            $('.ts-h-amt', node).textContent = rs(h.amount);
            $('.ts-h-del', node).dataset.id = h.id;
            box.appendChild(node);
            total += h.amount;
        });
        $('#tsHoTotal').textContent = rs(total);
    }

    // ── Hisaab ─────────────────────────────────────────────────────────────
    function totals() {
        var noz = allNoz();
        var sale = 0, litres = 0;
        noz.forEach(function (n) { if (n.state === 'ok' || n.state === 'why') { sale += n.net * n.rate; litres += n.net; } });
        var sl = slips();
        var slipTotal = sl.reduce(function (a, s) { return a + s.amount; }, 0);
        var upi = num(upiEl) || 0;
        var card = num(cardEl) || 0;
        var expected = sale - slipTotal - upi - card - (cash.otherCredit || 0) - (cash.otherDigital || 0) + (cash.adjust || 0);
        var got = num(cashEl);
        // Galle me = shuru ka + ginaa hua - malik ko diya - bank me jama. Band hote hi isme se B.keepInDrawer
        // chhod kar baaki apne aap malik ko (Section AN); wahi bacha hua agli shift ki opening.
        var handed = (cash.handoverOwner || 0) + (cash.handoverBank || 0);
        var left = got === null ? null : (cash.openingCash || 0) + got - handed;
        var keep = B.keepInDrawer || 0;
        return {
            noz: noz, sale: sale, litres: litres, slips: sl, slipTotal: slipTotal, upi: upi, card: card,
            expected: expected, cash: got, diff: got === null ? null : got - expected,
            handed: handed, left: left,
            auto: left === null ? null : Math.max(0, left - keep),
            drawer: left === null ? null : Math.min(left, keep)
        };
    }

    function diffClass(d) {
        if (d === null) { return ''; }
        return Math.abs(d) <= B.tolerance ? 'ts-ok' : d < 0 ? 'ts-short' : 'ts-excess';
    }
    function diffWord(d) {
        return Math.abs(d) <= B.tolerance ? T.matched : d < 0 ? T.short : T.excess;
    }

    function render() {
        nozEls.forEach(renderNoz);
        var t = totals();
        var tanks = renderTanks(t.noz);

        var okNoz = t.noz.filter(function (n) { return n.state === 'ok'; }).length;
        var dips = tanks.filter(function (x) { return x.act; }).length;

        $('#tsSub1').textContent = nOfM(okNoz, t.noz.length);
        $('#tsSub2').textContent = tankEls.length ? nOfM(dips, tankEls.length) : '—';
        $('#tsSub3').textContent = t.cash === null ? T.moneySub : rs(t.cash);
        $('#tsSub4').textContent = t.diff === null ? T.checkSub : diffWord(t.diff);
        setDone(1, okNoz === t.noz.length && t.noz.length > 0);
        setDone(2, tankEls.length > 0 && dips === tankEls.length);
        setDone(3, t.cash !== null);
        setDone(4, false);

        $('#tsSlipTotal').textContent = rs(t.slipTotal);
        $('#tsExpected').textContent = rs(t.expected);
        var leftEl = $('#tsLeft');
        if (leftEl) {
            // Nikala hua galle se zyada ho to wahi minus dikhao (band karna rukta hai), warna malik ko jaane wala.
            leftEl.textContent = t.left === null ? '—' : rs(t.left < 0 ? t.left : t.auto);
            leftEl.className = t.left !== null && t.left < 0 ? 'ts-short' : '';
        }

        $('#tsBarSale').textContent = rs(t.sale);
        $('#tsBarExp').textContent = rs(t.expected);
        var bd = $('#tsBarDiff');
        bd.textContent = t.diff === null ? '—' : (t.diff > 0 ? '+' : '') + rs(t.diff);
        bd.className = 'val ' + diffClass(t.diff);

        renderCheck(t, okNoz, dips);
        renderBreak(t);
        return t;
    }

    function setDone(n, done) {
        var b = $('.ts-step[data-step="' + n + '"]');
        b.classList.toggle('done', done);
        $('.ts-num', b).textContent = done ? '✓' : String(n);
    }

    function renderCheck(t, okNoz, dips) {
        var rows = [
            [okNoz === t.noz.length, T.chkMeter, okNoz + ' / ' + t.noz.length],
            [tankEls.length === 0 || dips === tankEls.length, T.chkDip, tankEls.length ? dips + ' / ' + tankEls.length : '—', dips === 0 && tankEls.length ? 'warn' : ''],
            [true, T.chkMoney, rs(t.upi + t.card + t.slipTotal)],
            [t.cash !== null, T.chkCash, t.cash === null ? T.notFilled : rs(t.cash)],
            [t.diff !== null && Math.abs(t.diff) <= B.tolerance, T.chkMatch, t.diff === null ? '—' : (t.diff > 0 ? '+' : '') + rs(t.diff)]
        ];
        var box = $('#tsChecklist');
        box.innerHTML = '';
        rows.forEach(function (r) {
            var d = document.createElement('div');
            d.className = 'ts-check ' + (r[0] ? 'ok' : (r[3] || ''));
            d.innerHTML = '<span class="dot">✓</span><span class="flex-grow-1"></span><span class="text-muted small"></span>';
            d.children[1].textContent = r[1];
            d.children[2].textContent = r[2];
            box.appendChild(d);
        });
    }

    function renderBreak(t) {
        var L = B.labels || {};
        var lines = [[L.sale + ' (' + qtyByUnit(t.noz) + ')', t.sale]];
        function add(label, v, sign) { if (Math.abs(v) >= 0.005) { lines.push([label, sign * v]); } }
        add(L.slips, t.slipTotal, -1);
        add(L.upi, t.upi, -1);
        add(L.card, t.card, -1);
        add(L.other, (cash.otherCredit || 0) + (cash.otherDigital || 0), -1);
        add(L.receipts, cash.receiptsCash || 0, 1);
        add(L.cashIn, cash.cashIn || 0, 1);
        add(L.cashOut, cash.cashOut || 0, -1);
        add(L.expenses, cash.cashExpenses || 0, -1);
        add(L.bank, cash.bankDeposits || 0, -1);

        var body = $('#tsBreak');
        body.innerHTML = '';
        function row(label, val, cls) {
            var tr = document.createElement('tr');
            if (cls) { tr.className = cls; }
            tr.innerHTML = '<td></td><td class="text-end"></td>';
            tr.children[0].textContent = label;
            tr.children[1].textContent = val;
            body.appendChild(tr);
            return tr;
        }
        lines.forEach(function (l, i) { row(l[0], (i > 0 && l[1] > 0 ? '+' : '') + rs(l[1])); });
        row(L.expected, rs(t.expected), 'total');
        row(L.came, t.cash === null ? '—' : rs(t.cash));
        var dr = row(L.diff, t.diff === null ? '—' : (t.diff > 0 ? '+' : '') + rs(t.diff) + '  ' + diffWord(t.diff), 'total');
        dr.children[1].className = 'text-end ' + diffClass(t.diff);

        // Ginne ke baad: kitna nikala, kitna apne aap malik ko, kitna galle me bacha (wahi agli shift ki shuruaat).
        if ((cash.handoverOwner || 0) > 0) { row(L.hoOwner, '−' + rs(cash.handoverOwner)); }
        if ((cash.handoverBank || 0) > 0) { row(L.hoBank, '−' + rs(cash.handoverBank)); }
        if (t.auto) { row(L.autoOwner, '−' + rs(t.auto)); }
        row(L.left, t.drawer === null ? '—' : rs(t.drawer), 'total');
    }

    // ── Draft ──────────────────────────────────────────────────────────────
    var draftTimer = null;
    function saveDraft() {
        clearTimeout(draftTimer);
        draftTimer = setTimeout(function () {
            var d = { v: 1, step: step, noz: {}, dip: {}, den: {} };
            nozEls.forEach(function (el) {
                d.noz[el.dataset.nozzle] = { c: $('.ts-close', el).value, t: $('.ts-test', el).value, w: $('.ts-why', el).value };
            });
            tankEls.forEach(function (el) {
                d.dip[el.dataset.tank] = { cm: $('.ts-cm', el).value, a: $('.ts-act', el).value };
            });
            $$('.ts-den-in').forEach(function (el) { d.den[el.dataset.den] = el.value; });
            d.upi = upiEl.value; d.card = cardEl.value; d.slips = slips();
            d.cash = cashEl.value; d.notes = notesText.value;
            try {
                localStorage.setItem(KEY, JSON.stringify(d));
                var ind = $('#tsDraft');
                ind.textContent = '💾 ' + T.savedHere + ' ✓';
            } catch (e) { /* private window - draft nahi, baaki sab chalta hai */ }
        }, 300);
    }

    function loadDraft() {
        var d = null;
        try { d = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { d = null; }

        // Server wala paisa pehle — draft ho to wo upar (wo hamesha naya hota hai).
        upiEl.value = B.upi ? B.upi : '';
        cardEl.value = B.card ? B.card : '';
        (B.slips || []).forEach(addSlip);
        // Roz ki testing (is pump par har nozzle 5 L) pehle se. Pichhli baar 5 L se
        // zyada thi to wo kabhi-kabhar wali baat thi — use dohraate nahi.
        nozEls.forEach(function (el) {
            var last = parseFloat(el.dataset.lastTest) || 0;
            $('.ts-test', el).value = last > 0 && last <= TEST_LIMIT ? last : '';
        });

        if (!d || d.v !== 1) { return 1; }

        nozEls.forEach(function (el) {
            var x = d.noz && d.noz[el.dataset.nozzle];
            if (!x) { return; }
            $('.ts-close', el).value = x.c || '';
            $('.ts-test', el).value = x.t || '';
            $('.ts-why', el).value = x.w || '';
        });
        tankEls.forEach(function (el) {
            var x = d.dip && d.dip[el.dataset.tank];
            if (!x) { return; }
            $('.ts-cm', el).value = x.cm || '';
            $('.ts-act', el).value = x.a || '';
        });
        $$('.ts-den-in').forEach(function (el) { el.value = (d.den && d.den[el.dataset.den]) || ''; });
        upiEl.value = d.upi || '';
        cardEl.value = d.card || '';
        slipBox.innerHTML = '';
        (d.slips || []).forEach(addSlip);
        cashEl.value = d.cash || '';
        notesText.value = d.notes || '';
        moneyDirty = true;
        return d.step || 1;
    }

    // ── Kadam ──────────────────────────────────────────────────────────────
    function show(n) {
        step = n;
        $$('.ts-sec').forEach(function (s) { s.hidden = +s.dataset.sec !== n; });
        $$('.ts-step').forEach(function (b) {
            b.classList.toggle('active', +b.dataset.step === n);
            b.setAttribute('aria-current', +b.dataset.step === n ? 'step' : 'false');
        });
        var pane = document.querySelector('.content-pane');
        if (pane) { pane.scrollTo({ top: 0, behavior: 'smooth' }); }
        saveDraft();
    }

    async function go(n) {
        // "Paisa" se aage badhte hi UPI / udhaar server par — phone kho jaye to bhi rahe.
        if (step === 3 && n > 3) {
            var ok = await saveMoney();
            if (!ok) { return; }
        }
        show(n);
    }

    function moneyError(msg) {
        var e = $('#tsMoneyErr');
        e.textContent = msg || '';
        e.hidden = !msg;
    }

    function slipProblem(sl) {
        return sl.some(function (s) { return s.amount > 0 && !s.partyId; }) ? T.slipParty : null;
    }

    async function saveMoney() {
        moneyError('');
        var t = totals();
        var p = slipProblem(t.slips);
        if (p) { moneyError(p); return false; }
        if (!moneyDirty) { return true; }
        try {
            var r = await ppmsFetch(B.urls.money, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ shiftId: B.shiftId, pumpId: B.pumpId, upi: t.upi, card: t.card, slips: t.slips })
            });
            var j = await r.json();
            if (!j.success) { moneyError(j.message || T.serverError); return false; }
            cash = j.cash || cash;
            moneyDirty = false;
            if (window.ppmsToast) { ppmsToast(T.moneySaved, { type: 'success' }); }
            render();
            return true;
        } catch (e) {
            moneyError(T.serverError);
            return false;
        }
    }

    // ── Band karna ─────────────────────────────────────────────────────────
    function finishError(msg) {
        var e = $('#tsFinishErr');
        e.textContent = msg || '';
        e.hidden = !msg;
    }

    async function finish() {
        finishError('');
        var btn = $('#tsFinish');
        var t = render();

        var bad = t.noz.filter(function (n) { return n.state !== 'ok'; });
        if (bad.length) {
            show(1);
            var first = bad[0];
            var msg = first.state === 'empty' ? T.fillAll : first.state === 'less' ? T.closeLess : first.state === 'test' ? T.testTooMuch : T.whyNeeded;
            $('.ts-err', first.el).textContent = msg;
            $('.ts-err', first.el).hidden = false;
            (first.state === 'why' ? $('.ts-why', first.el) : $('.ts-close', first.el)).focus();
            return;
        }

        var p = slipProblem(t.slips);
        if (p) { show(3); moneyError(p); return; }

        if (t.cash === null) {
            show(3);
            moneyError(T.cashNeeded);
            cashEl.focus();
            return;
        }

        // Nikala hua nakad galle me jitna tha usse zyada nahi ho sakta.
        if (t.left !== null && t.left < 0) {
            show(3);
            moneyError(T.hoTooMuch);
            return;
        }

        // Saari chetavni EK hi sawaal me. Pehle teen alag ppmsConfirm the — pehla modal
        // band hote waqt uska "hidden" event doosre sawaal ko "nahi" bana deta tha, aur
        // shift chupchaap band hi nahi hoti thi.
        var tanks = renderTanks(t.noz);
        var warn = [];
        if (t.sale <= 0) { warn.push(T.zeroSale); }
        if (tanks.length && !tanks.some(function (x) { return x.act; })) { warn.push(T.noDip); }
        if (Math.abs(t.diff) > B.tolerance) { warn.push(fmt(t.diff < 0 ? T.farkShort : T.farkExcess, rs(Math.abs(t.diff)))); }
        if (warn.length && !ack.warn) {
            warn.push(T.closeAnyQ);
            if (!(await ppmsConfirm(warn.join(' '), { okText: T.closeAnyway, danger: t.diff < 0 }))) { return; }
            ack.warn = true;
        }

        // Testing 5 L se zyada — wajah shift ke notes me jaati hai.
        var notes = notesText.value.trim();
        var testLines = t.noz.filter(function (n) { return n.test > TEST_LIMIT; })
            .map(function (n) { return T.testingNote + ' ' + n.code + ': ' + n.test + ' L (' + n.why + ')'; });
        if (testLines.length) { notes = (notes ? notes + '\n' : '') + testLines.join('\n'); }

        var payload = {
            shiftId: B.shiftId,
            pumpId: B.pumpId,
            readings: t.noz.map(function (n) { return { nozzleId: n.id, closingReading: n.close, testingLoss: n.test }; }),
            dips: tanks.filter(function (x) { return x.act; }).map(function (x) { return { tankId: x.id, dipCm: x.cm, actualStock: x.act }; }),
            upi: t.upi,
            card: t.card,
            slips: t.slips,
            cashToday: t.cash,
            notes: notes.slice(0, 480)
        };

        btn.disabled = true;
        var oldText = btn.textContent;
        btn.textContent = T.closing;
        try {
            var r = await ppmsFetch(B.urls.finish, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            var j = await r.json();
            if (!j.success) {
                finishError(j.message || T.serverError);
                btn.disabled = false;
                btn.textContent = oldText;
                return;
            }
            try { localStorage.removeItem(KEY); } catch (e) { /* koi baat nahi */ }
            window.location = j.redirect;
        } catch (e) {
            finishError(T.serverError);
            btn.disabled = false;
            btn.textContent = oldText;
        }
    }

    // ── Kharcha ────────────────────────────────────────────────────────────
    async function expenseCall(url, body) {
        var err = $('#tsExpErr');
        if (err) { err.hidden = true; }
        try {
            var r = await ppmsFetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            var j = await r.json();
            if (!j.success) {
                if (err) { err.textContent = j.message || T.serverError; err.hidden = false; }
                return false;
            }
            renderExpenses(j.expenses);
            cash = j.cash || cash;
            render();
            return true;
        } catch (e) {
            if (err) { err.textContent = T.serverError; err.hidden = false; }
            return false;
        }
    }

    async function handoverCall(url, body) {
        var err = $('#tsHoErr');
        if (err) { err.hidden = true; }
        try {
            var r = await ppmsFetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            var j = await r.json();
            if (!j.success) {
                if (err) { err.textContent = j.message || T.serverError; err.hidden = false; }
                return false;
            }
            renderHandovers(j.handovers);
            cash = j.cash || cash;
            ack.warn = false;
            render();
            return true;
        } catch (e) {
            if (err) { err.textContent = T.serverError; err.hidden = false; }
            return false;
        }
    }

    // ── Events ─────────────────────────────────────────────────────────────
    document.addEventListener('input', function (e) {
        var el = e.target;
        var slip = el.closest('.ts-slip');
        if (slip) {
            moneyDirty = true;
            if (el.classList.contains('ts-s-lit')) { slipLitres(slip); }
            if (el.classList.contains('ts-s-note')) { el.dataset.auto = ''; }
            $('#tsSlipErr').hidden = true;
        }
        if (el === upiEl || el === cardEl) { moneyDirty = true; }
        if (el.classList.contains('ts-den-in')) {
            var total = $$('.ts-den-in').reduce(function (a, x) { return a + (parseInt(x.value, 10) || 0) * (+x.dataset.den); }, 0);
            $('#tsDenTotal').textContent = rs(total);
        }
        if (el.closest('.ts-wrap')) { ack.warn = false; render(); saveDraft(); }
    });

    document.addEventListener('change', function (e) {
        var el = e.target;
        if (el.classList.contains('ts-s-party')) { moneyDirty = true; }
        if (el.classList.contains('ts-s-prod')) { slipLitres(el.closest('.ts-slip')); moneyDirty = true; }
        if (el.closest('.ts-wrap')) { render(); saveDraft(); }
    });

    document.addEventListener('click', function (e) {
        var el = e.target;
        var stepBtn = el.closest('.ts-step');
        if (stepBtn) { go(+stepBtn.dataset.step); return; }
        var goBtn = el.closest('[data-go]');
        if (goBtn) { go(+goBtn.dataset.go); return; }

        var same = el.closest('.ts-same');
        if (same) {
            var noz = same.closest('.ts-noz');
            $('.ts-close', noz).value = noz.dataset.open;
            $('.ts-test', noz).value = '';
            render(); saveDraft();
            return;
        }

        var del = el.closest('.ts-s-del');
        if (del) {
            del.closest('.ts-slip').remove();
            moneyDirty = true;
            render(); saveDraft();
            return;
        }

        var hdel = el.closest('.ts-h-del');
        if (hdel) {
            ppmsConfirm(T.deleteHandover, { danger: true, okText: T.delete }).then(function (ok) {
                if (ok) { handoverCall(B.urls.deleteHandover, { id: +hdel.dataset.id, shiftId: B.shiftId, pumpId: B.pumpId }); }
            });
            return;
        }

        var edel = el.closest('.ts-e-del');
        if (edel) {
            ppmsConfirm(T.deleteExpense, { danger: true, okText: T.delete }).then(function (ok) {
                if (ok) { expenseCall(B.urls.deleteExpense, { id: +edel.dataset.id, shiftId: B.shiftId, pumpId: B.pumpId }); }
            });
        }
    });

    $('#tsAddSlip').addEventListener('click', function () {
        var all = slips();
        var last = all[all.length - 1];
        var err = $('#tsSlipErr');
        if (last && (!last.partyId || !last.amount)) {
            err.textContent = T.slipFirst;
            err.hidden = false;
            return;
        }
        err.hidden = true;
        // Pichhli parchi ka product hi aksar agla bhi hota hai.
        var node = addSlip({ prod: last ? last.prod : 0 });
        $('.ts-s-party', node).focus();
        saveDraft();
    });

    $('#tsNotesBtn').addEventListener('click', function () {
        var box = $('#tsNotes');
        box.hidden = !box.hidden;
    });
    $('#tsDenApply').addEventListener('click', function () {
        var total = $$('.ts-den-in').reduce(function (a, x) { return a + (parseInt(x.value, 10) || 0) * (+x.dataset.den); }, 0);
        cashEl.value = total;
        $('#tsNotes').hidden = true;
        ack.warn = false;
        render(); saveDraft();
    });
    $('#tsCashExact').addEventListener('click', function () {
        var t = totals();
        cashEl.value = Math.max(0, t.expected).toFixed(2);
        ack.warn = false;
        render(); saveDraft();
    });

    var expAdd = $('#tsExpAdd');
    if (expAdd) {
        expAdd.addEventListener('click', async function () {
            var head = parseInt($('#tsExpHead').value, 10) || 0;
            var amt = num($('#tsExpAmt')) || 0;
            if (!head || amt <= 0) {
                var err = $('#tsExpErr');
                err.textContent = T.expenseNeeded;
                err.hidden = false;
                return;
            }
            expAdd.disabled = true;
            var ok = await expenseCall(B.urls.addExpense, {
                shiftId: B.shiftId, pumpId: B.pumpId, expenseHeadId: head, amount: amt, narration: $('#tsExpNote').value
            });
            expAdd.disabled = false;
            if (ok) {
                $('#tsExpHead').value = '';
                $('#tsExpAmt').value = '';
                $('#tsExpNote').value = '';
            }
        });
    }

    var hoAdd = $('#tsHoAdd');
    if (hoAdd) {
        hoAdd.addEventListener('click', async function () {
            var amt = num($('#tsHoAmt')) || 0;
            if (amt <= 0) {
                var err = $('#tsHoErr');
                err.textContent = T.hoNeedAmount;
                err.hidden = false;
                return;
            }
            hoAdd.disabled = true;
            var ok = await handoverCall(B.urls.addHandover, {
                shiftId: B.shiftId, pumpId: B.pumpId, kind: $('#tsHoKind').value, amount: amt, note: $('#tsHoNote').value
            });
            hoAdd.disabled = false;
            if (ok) {
                $('#tsHoAmt').value = '';
                $('#tsHoNote').value = '';
            }
        });
    }

    $('#tsFinish').addEventListener('click', finish);

    // ── Shuru ──────────────────────────────────────────────────────────────
    renderExpenses(B.expenses);
    if (B.expenses && B.expenses.length) { $('#tsExpBox').open = true; }
    renderHandovers(B.handovers);
    var startStep = loadDraft();
    render();
    show(startStep);
})();
