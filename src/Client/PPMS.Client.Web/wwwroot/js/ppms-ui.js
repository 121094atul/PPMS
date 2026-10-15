// PPMS — do cheezein jo HAR page par chahiye:
//   1. Khojne wala dropdown   (lambi list scroll na karni pade)
//   2. Lambi list me page     (table[data-pager])
//
// Shabd (Search / Previous / Next ...) layout ke <body data-...> se aate hain —
// ye file Razor nahi hai, @L[..] yahan nahi likha ja sakta.

// ═══════════════════════════════════════════════════════════════════════════
// 1. KHOJNE WALA DROPDOWN
// ───────────────────────────────────────────────────────────────────────────
// <select> ko BADLA NAHI jaata — wo jaisa hai waisa hi dikhta aur kaam karta hai
// (value, required, disabled, onchange, form submit, code se value badalna).
// Bas us par click / tap hone par browser ki apni list ki jagah hamara panel
// khulta hai: upar khoj ka khaana, neeche chhanti hui list. Chunne par select ki
// value badal kar wahi 'change' event bheja jaata hai jo browser bhejta.
//
// Select2 / Tom Select jaisi library select ko chhupa kar apna dabba banati hain.
// Is app me darjanon jagah `select.value = ...` aur `onchange="..."` likha hai —
// chhupa hua select un sab ko chupchaap tod deta. Isliye ye raasta.
//
// Chhoti list (MIN_OPTIONS se kam) me khoj ka koi faayda nahi — wahan browser ka
// apna dropdown hi rehta hai. Kisi ek select par band karna ho: data-no-search.
// ═══════════════════════════════════════════════════════════════════════════
(function () {
    'use strict';

    var MIN_OPTIONS = 8;

    var body = document.body;
    var T_SEARCH = body.getAttribute('data-ss-search') || 'Type to search...';
    var T_EMPTY = body.getAttribute('data-ss-empty') || 'No match found';

    var panel, input, list, emptyEl, backdrop;
    var current = null;     // jis select ke liye panel khula hai
    var items = [];         // [{ el, index, norm, disabled, group, visible }]
    var active = -1;        // items[] ka index jo abhi ubhra hua hai
    var touchStart = null;  // tap aur scroll me farak karne ke liye

    function eligible(sel) {
        if (!sel || sel.tagName !== 'SELECT') { return false; }
        if (sel.multiple || sel.size > 1 || sel.disabled) { return false; }
        if (sel.closest('[data-no-search]')) { return false; }
        return sel.options.length >= MIN_OPTIONS;
    }

    // "Jai  Shri" == "jai shri". Angrezi ke accent hatate hain; Hindi ki matra
    // (U+09xx) is range me nahi aati, wo jaisi hai waisi rehti hai.
    function norm(s) {
        s = (s || '').toLowerCase();
        if (s.normalize) { s = s.normalize('NFKD').replace(/[̀-ͯ]/g, ''); }
        return s.replace(/\s+/g, ' ').trim();
    }

    function build() {
        backdrop = document.createElement('div');
        backdrop.className = 'ss-backdrop';

        panel = document.createElement('div');
        panel.className = 'ss-panel';
        panel.setAttribute('role', 'dialog');
        panel.innerHTML =
            '<div class="ss-head">' +
            '<input type="text" class="form-control ss-input" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" enterkeyhint="done">' +
            '<button type="button" class="btn-close ss-close" aria-label="Close"></button>' +
            '</div>' +
            '<div class="ss-list" role="listbox"></div>' +
            '<div class="ss-empty" hidden></div>';

        input = panel.querySelector('.ss-input');
        list = panel.querySelector('.ss-list');
        emptyEl = panel.querySelector('.ss-empty');
        input.placeholder = T_SEARCH;
        input.setAttribute('aria-label', T_SEARCH);
        emptyEl.textContent = T_EMPTY;

        input.addEventListener('input', filter);
        input.addEventListener('keydown', onInputKey);
        panel.querySelector('.ss-close').addEventListener('click', function () { close(true); });

        list.addEventListener('click', function (e) {
            var el = e.target.closest ? e.target.closest('.ss-item') : null;
            if (el) { choose(parseInt(el.getAttribute('data-k'), 10)); }
        });
        list.addEventListener('mousemove', function (e) {
            var el = e.target.closest ? e.target.closest('.ss-item') : null;
            if (el) { setActive(parseInt(el.getAttribute('data-k'), 10), false); }
        });
    }

    function render() {
        list.innerHTML = '';
        items = [];
        var frag = document.createDocumentFragment();
        var opts = current.options;
        var lastGroup = null, groupEl = null;

        for (var i = 0; i < opts.length; i++) {
            var o = opts[i];
            if (o.hidden || o.style.display === 'none') { continue; }   // kuch page option chhupate hain

            var g = (o.parentNode && o.parentNode.tagName === 'OPTGROUP') ? o.parentNode : null;
            if (g !== lastGroup) {
                lastGroup = g;
                groupEl = null;
                if (g) {
                    groupEl = document.createElement('div');
                    groupEl.className = 'ss-group';
                    groupEl.textContent = g.label;
                    frag.appendChild(groupEl);
                }
            }

            var disabled = o.disabled || (g && g.disabled);
            var el = document.createElement('div');
            el.className = 'ss-item' + (i === current.selectedIndex ? ' ss-selected' : '') + (disabled ? ' ss-disabled' : '');
            el.setAttribute('role', 'option');
            el.setAttribute('data-k', items.length);
            el.textContent = o.text || ' ';
            frag.appendChild(el);

            items.push({ el: el, index: i, norm: norm(o.text), disabled: !!disabled, group: groupEl, visible: true });
        }
        list.appendChild(frag);
    }

    function filter() {
        var q = norm(input.value);
        var words = q ? q.split(' ') : [];
        var shown = 0, first = -1, selected = -1;
        var groups = [];

        items.forEach(function (it, k) {
            var ok = true;
            for (var w = 0; w < words.length; w++) {
                if (it.norm.indexOf(words[w]) === -1) { ok = false; break; }
            }
            it.visible = ok;
            it.el.hidden = !ok;
            if (it.group && groups.indexOf(it.group) === -1) { groups.push(it.group); it.group.hidden = true; }
            if (ok) {
                shown++;
                if (it.group) { it.group.hidden = false; }
                if (!it.disabled) {
                    if (first < 0) { first = k; }
                    if (it.index === current.selectedIndex) { selected = k; }
                }
            }
        });

        emptyEl.hidden = shown > 0;
        list.hidden = shown === 0;
        // Khoj khaali ho to abhi chuni hui line par raho; kuch likha ho to pehle mel par.
        setActive(q ? first : (selected >= 0 ? selected : first), true);
    }

    function setActive(k, scroll) {
        if (active >= 0 && items[active]) { items[active].el.classList.remove('ss-active'); }
        active = (k >= 0 && items[k] && items[k].visible && !items[k].disabled) ? k : -1;
        if (active < 0) { return; }
        var el = items[active].el;
        el.classList.add('ss-active');
        if (scroll) {
            var top = el.offsetTop - list.offsetTop;
            if (top < list.scrollTop) { list.scrollTop = top; }
            else if (top + el.offsetHeight > list.scrollTop + list.clientHeight) {
                list.scrollTop = top + el.offsetHeight - list.clientHeight;
            }
        }
    }

    function move(step) {
        if (!items.length) { return; }
        var k = active;
        for (var n = 0; n < items.length; n++) {
            k += step;
            if (k < 0 || k >= items.length) { return; }      // sire par ruk jao, ghoom kar mat aao
            if (items[k].visible && !items[k].disabled) { setActive(k, true); return; }
        }
    }

    function onInputKey(e) {
        switch (e.key) {
            case 'ArrowDown': e.preventDefault(); move(1); break;
            case 'ArrowUp': e.preventDefault(); move(-1); break;
            case 'PageDown': e.preventDefault(); for (var a = 0; a < 8; a++) { move(1); } break;
            case 'PageUp': e.preventDefault(); for (var b = 0; b < 8; b++) { move(-1); } break;
            case 'Enter':
                // Form submit na ho jaye — Enter yahan sirf "ye wali chuno" hai.
                e.preventDefault();
                e.stopPropagation();
                if (active >= 0) { choose(active); }
                break;
            case 'Escape':
                e.preventDefault();
                e.stopPropagation();      // Bootstrap modal bhi Escape sunta hai — wo band na ho
                close(true);
                break;
            case 'Tab':
                e.preventDefault();
                close(true);
                break;
        }
    }

    function isSheet() { return window.innerWidth < 768; }

    function place() {
        if (!current) { return; }
        var vv = window.visualViewport;
        var vw = window.innerWidth;
        var vh = vv ? vv.height : window.innerHeight;

        if (isSheet()) {
            // Phone: upar chipka hua, poori chaudai. Upar isliye ki keyboard neeche
            // se aata hai — neeche wali sheet uske peeche chhup jaati.
            panel.classList.add('ss-sheet');
            panel.style.left = panel.style.right = panel.style.width = panel.style.bottom = '';
            panel.style.top = ((vv ? vv.offsetTop : 0) + 8) + 'px';
            panel.style.maxHeight = Math.max(180, vh - 16) + 'px';
            return;
        }

        panel.classList.remove('ss-sheet');
        var r = current.getBoundingClientRect();
        var w = Math.min(Math.max(r.width, 280), vw - 16);
        var left = Math.min(Math.max(8, r.left), vw - w - 8);
        var below = vh - r.bottom - 10;
        var above = r.top - 10;
        var openBelow = below >= 260 || below >= above;

        panel.style.width = w + 'px';
        panel.style.left = left + 'px';
        panel.style.right = 'auto';
        panel.style.maxHeight = Math.max(160, Math.min(380, openBelow ? below : above)) + 'px';
        if (openBelow) {
            panel.style.top = (r.bottom + 2) + 'px';
            panel.style.bottom = 'auto';
        } else {
            panel.style.top = 'auto';
            panel.style.bottom = (window.innerHeight - r.top + 2) + 'px';
        }
    }

    function open(sel, seed) {
        if (!panel) { build(); }
        if (current) { close(false); }
        current = sel;

        // Bootstrap ka modal focus ko apne andar hi rakhta hai — panel bahar ho to
        // khoj ke khaane me likha hi nahi jaata. Isliye panel usi modal ke andar.
        var host = sel.closest('.modal, .offcanvas') || document.body;
        host.appendChild(backdrop);
        host.appendChild(panel);

        render();
        input.value = seed || '';
        backdrop.classList.add('ss-open');
        panel.classList.add('ss-open');
        place();
        list.scrollTop = 0;
        filter();
        try { input.focus({ preventScroll: true }); } catch (err) { input.focus(); }
        if (seed) { try { input.setSelectionRange(seed.length, seed.length); } catch (err2) { /* purana browser */ } }
    }

    function close(refocus) {
        if (!current) { return; }
        var sel = current;
        current = null;
        active = -1;
        panel.classList.remove('ss-open');
        backdrop.classList.remove('ss-open');
        if (refocus) { try { sel.focus({ preventScroll: true }); } catch (err) { sel.focus(); } }
    }

    function choose(k) {
        var it = items[k];
        if (!it || it.disabled || !current) { return; }
        var sel = current;
        var changed = sel.selectedIndex !== it.index;
        close(true);
        if (changed) {
            sel.selectedIndex = it.index;
            // Wahi do event jo browser khud bhejta — page ka apna onchange / jQuery
            // handler bina kisi badlav ke chalta hai.
            sel.dispatchEvent(new Event('input', { bubbles: true }));
            sel.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }

    function selectFrom(target) {
        return (target && target.closest) ? target.closest('select') : null;   // Firefox me target <option> hota hai
    }

    // ── Mouse ──
    document.addEventListener('mousedown', function (e) {
        if (current) {
            if (panel.contains(e.target)) { return; }
            var same = selectFrom(e.target) === current;
            close(false);
            if (same) { e.preventDefault(); return; }      // usi select par dobara click = band karo
        }
        if (e.button !== 0) { return; }
        var sel = selectFrom(e.target);
        if (!eligible(sel)) { return; }
        e.preventDefault();                                // browser ki apni list na khule
        open(sel);
    }, true);

    // ── Touch ──
    // touchend par rokne se browser na apni list kholta hai na nakli mouse event
    // bhejta hai. Ungli hili ho (scroll) to kuch nahi karte.
    document.addEventListener('touchstart', function (e) {
        var t = e.touches && e.touches[0];
        touchStart = t ? { x: t.clientX, y: t.clientY, target: e.target } : null;
    }, { capture: true, passive: true });

    document.addEventListener('touchend', function (e) {
        var start = touchStart;
        touchStart = null;
        var t = e.changedTouches && e.changedTouches[0];
        if (!start || !t) { return; }
        if (Math.abs(t.clientX - start.x) > 10 || Math.abs(t.clientY - start.y) > 10) { return; }

        if (current) {
            if (panel.contains(e.target)) { return; }
            if (e.cancelable) { e.preventDefault(); }      // bahar ka tap sirf band kare, neeche wali cheez na dabe
            close(false);
            return;
        }
        var sel = selectFrom(e.target);
        if (!eligible(sel) || !e.cancelable) { return; }
        e.preventDefault();
        open(sel);
    }, { capture: true, passive: false });

    // ── Keyboard (select par focus ho) ──
    document.addEventListener('keydown', function (e) {
        if (current) { return; }                           // panel ke andar ke button input sambhalta hai
        var sel = e.target;
        if (!sel || sel.tagName !== 'SELECT' || !eligible(sel)) { return; }
        if (e.ctrlKey || e.metaKey) { return; }

        var k = e.key;
        var opens = k === ' ' || k === 'Spacebar' || k === 'F4' || k === 'ArrowDown' || k === 'ArrowUp';
        var typed = k.length === 1 && k !== ' ' && !e.altKey;
        if (!opens && !typed) { return; }                  // Enter, Tab, Esc — browser jaisa karta hai waisa hi

        e.preventDefault();
        open(sel, typed ? k : '');
    }, true);

    window.addEventListener('resize', place);
    if (window.visualViewport) { window.visualViewport.addEventListener('resize', place); }
    // Page scroll ho to panel select ke saath chale (list ka apna scroll nahi ginte).
    document.addEventListener('scroll', function (e) {
        if (current && !(panel && panel.contains(e.target))) { place(); }
    }, { capture: true, passive: true });
})();

// ═══════════════════════════════════════════════════════════════════════════
// 2. LAMBI LIST ME PAGE   —   <table data-pager="25">
// ───────────────────────────────────────────────────────────────────────────
// Sirf un table ke liye jinki SAARI row page par aa chuki hain. Row chhupti hain,
// hat-ti nahi — isliye print me poori list aati hai, aur row ke andar ke form
// waise hi kaam karte hain. Row page ke size se kam hon to kuch nahi dikhta.
//
// Jis list ko server tukdon me bhejta hai (Sales, Shifts, Parties...) uske liye
// ye NAHI hai — wahan asli (server wali) paging hai.
// ═══════════════════════════════════════════════════════════════════════════
(function () {
    'use strict';

    var body = document.body;
    var T_PREV = body.getAttribute('data-pg-prev') || 'Previous';
    var T_NEXT = body.getAttribute('data-pg-next') || 'Next';
    var T_INFO = body.getAttribute('data-pg-info') || '{0}-{1} of {2}';

    function setup(table) {
        var size = parseInt(table.getAttribute('data-pager'), 10) || 25;
        var tbody = table.tBodies[0];
        if (!tbody) { return; }

        var rows = Array.prototype.slice.call(tbody.rows);
        if (rows.length <= size) { return; }

        var page = 1;
        var pages = Math.ceil(rows.length / size);

        var bar = document.createElement('div');
        bar.className = 'ppms-pager d-print-none';
        var info = document.createElement('span');
        info.className = 'small text-muted';
        var group = document.createElement('div');
        group.className = 'btn-group btn-group-sm';
        var prev = document.createElement('button');
        var next = document.createElement('button');
        prev.type = next.type = 'button';
        prev.className = next.className = 'btn btn-outline-secondary';
        prev.textContent = T_PREV;
        next.textContent = T_NEXT;
        group.appendChild(prev);
        group.appendChild(next);
        bar.appendChild(info);
        bar.appendChild(group);

        var anchor = table.closest('.table-responsive') || table;
        anchor.parentNode.insertBefore(bar, anchor.nextSibling);

        function show(scroll) {
            var from = (page - 1) * size, to = Math.min(page * size, rows.length);
            for (var i = 0; i < rows.length; i++) {
                rows[i].classList.toggle('pager-hidden', i < from || i >= to);
            }
            info.textContent = T_INFO.replace('{0}', from + 1).replace('{1}', to).replace('{2}', rows.length);
            prev.disabled = page <= 1;
            next.disabled = page >= pages;
            if (scroll) {
                var top = anchor.getBoundingClientRect().top;
                if (top < 0) { anchor.scrollIntoView({ block: 'start' }); }
            }
        }

        prev.addEventListener('click', function () { if (page > 1) { page--; show(true); } });
        next.addEventListener('click', function () { if (page < pages) { page++; show(true); } });
        show(false);
    }

    Array.prototype.forEach.call(document.querySelectorAll('table[data-pager]'), setup);
})();
