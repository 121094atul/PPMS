// PPMS Client Global Scripts

(function () {
    'use strict';

    // ═══════════════════════════════════════════
    // Mobile Sidebar Navigation Toggle
    // ═══════════════════════════════════════════
    var sideNav = document.getElementById('sideNav');
    var openBtn = document.getElementById('openSideNav');
    var closeBtn = document.getElementById('closeSideNav');
    var overlay = document.getElementById('sideNavOverlay');

    function openSideNav() {
        if (sideNav) sideNav.classList.add('open');
        if (overlay) overlay.classList.add('active');
        document.body.style.overflow = 'hidden';
    }

    function closeSideNav() {
        if (sideNav) sideNav.classList.remove('open');
        if (overlay) overlay.classList.remove('active');
        document.body.style.overflow = '';
    }

    if (openBtn) openBtn.addEventListener('click', openSideNav);
    if (closeBtn) closeBtn.addEventListener('click', closeSideNav);
    if (overlay) overlay.addEventListener('click', closeSideNav);

    // Close sidebar when a menu link is clicked (mobile UX)
    document.querySelectorAll('.menu-link').forEach(function (link) {
        link.addEventListener('click', function () {
            if (window.innerWidth < 992) {
                closeSideNav();
            }
        });
    });

    // ═══════════════════════════════════════════
    // Double-Submit Prevention
    // ═══════════════════════════════════════════
    // "Saving..." ka tarjuma layout se aata hai — ye file Razor nahi hai,
    // isliye @L[..] yahan nahi likha ja sakta.
    var MSG_SAVING = document.body.getAttribute('data-msg-saving') || 'Saving...';

    document.querySelectorAll('form[method="post"]').forEach(function (form) {
        // Logout ko chhodna hai — uska apna confirm pehle se hai.
        //
        // Pehle yahan `form.querySelector('[asp-action="Logout"]')` likha tha,
        // par `asp-action` ek Razor tag helper hai jo render hote hi HTML se
        // HAT jaata hai — browser use kabhi dekhta hi nahi. Isliye logout form
        // kabhi skip hota hi nahi tha: button par spinner aur "Saving..." aa
        // jaata tha, aur 10 second baad uska naam badal kar "Save" ho jaata tha.
        // Ab asli URL dekhte hain.
        var action = form.getAttribute('action') || '';
        if (/\/Account\/Logout/i.test(action) || form.getAttribute('data-no-guard') === 'true') {
            return;
        }

        form.addEventListener('submit', function (e) {
            var submitBtn = form.querySelector('button[type="submit"], input[type="submit"]');
            if (submitBtn && submitBtn.disabled) {
                e.preventDefault();
                return;
            }
            if (submitBtn) {
                // Purana label sambhal kar rakho. Pehle 10 second baad har button
                // par "Save" likh diya jaata tha — "Close Shift" ho ya "Logout",
                // sab "Save" ban jaate the.
                var originalHtml = submitBtn.innerHTML;
                submitBtn.disabled = true;
                submitBtn.innerHTML = '<span class="spinner-border spinner-border-sm me-1" role="status"></span> ' + MSG_SAVING;
                // Net ki dikkat me atak na jaaye, isliye 10 second baad wapas.
                setTimeout(function () {
                    submitBtn.disabled = false;
                    submitBtn.innerHTML = originalHtml;
                }, 10000);
            }
        });
    });

    // ═══════════════════════════════════════════
    // Confirmation Dialogs for Destructive Actions
    // ───────────────────────────────────────────
    // Ye pehle browser ka confirm() istemaal karta tha. Wo popup app ki theme se
    // mel nahi khaata tha, har browser me alag dikhta tha, Hindi mode me bhi
    // browser ki apni "OK / Cancel" dikhata tha, aur mobile par to poori screen
    // rok deta tha. Ab _Layout ka Bootstrap modal use hota hai.
    //
    // Kisi bhi button/link/form par lagayein:
    //   data-confirm="Pucha jaane wala sawaal"
    //   data-confirm-title="..."   (optional)
    //   data-confirm-ok="..."      (optional, OK button ka text)
    //   data-confirm-danger="true" (optional, laal OK button — delete waghairah)
    // ═══════════════════════════════════════════
    (function () {
        var modalEl = document.getElementById('appConfirmModal');
        if (!modalEl) { return; }   // koi purana layout — chup-chaap chhod do

        var bsModal = null;
        var titleEl = document.getElementById('appConfirmTitle');
        var bodyEl = document.getElementById('appConfirmBody');
        var okBtn = document.getElementById('appConfirmOk');
        var defaultTitle = titleEl ? titleEl.textContent : 'Please confirm';
        var defaultOk = okBtn ? okBtn.textContent : 'Confirm';
        var pending = null;          // {el, event} jise confirm hone par dobara chalana hai

        function ask(opts) {
            if (!bsModal) { bsModal = new bootstrap.Modal(modalEl); }
            titleEl.textContent = opts.title || defaultTitle;
            bodyEl.textContent = opts.message;
            okBtn.textContent = opts.okText || defaultOk;
            okBtn.className = 'btn btn-sm ' + (opts.danger ? 'btn-danger' : 'btn-primary');
            bsModal.show();
        }

        okBtn.addEventListener('click', function () {
            var p = pending;
            pending = null;
            bsModal.hide();
            if (!p) { return; }

            // Confirm ho gaya — ab asli kaam hone do. Flag laga kar dobara
            // handler chalne se rokte hain, warna modal loop me phans jaata.
            p.el.dataset.confirmed = 'yes';
            if (p.el.tagName === 'FORM') {
                p.el.submit();
            } else {
                p.el.click();
            }
            delete p.el.dataset.confirmed;
        });

        modalEl.addEventListener('hidden.bs.modal', function () { pending = null; });

        // Click aur submit dono capture karte hain — button, link ya form, kahin bhi lag sakta hai.
        function intercept(eventName) {
            document.addEventListener(eventName, function (e) {
                var el = e.target.closest('[data-confirm]');
                if (!el || el.dataset.confirmed === 'yes') { return; }
                // Form ke submit event par button ka data-confirm bhi chalta hai —
                // dono baar na puche, isliye submit par sirf FORM wale dekhte hain.
                if (eventName === 'submit' && el.tagName !== 'FORM') { return; }

                e.preventDefault();
                e.stopPropagation();
                pending = { el: el };
                ask({
                    message: el.getAttribute('data-confirm') || 'Are you sure?',
                    title: el.getAttribute('data-confirm-title'),
                    okText: el.getAttribute('data-confirm-ok'),
                    danger: el.getAttribute('data-confirm-danger') === 'true'
                });
            }, true);
        }
        intercept('click');
        intercept('submit');

        // Kisi bhi page se: ppmsConfirm('sawaal').then(ok => ...)
        window.ppmsConfirm = function (message, opts) {
            opts = opts || {};
            return new Promise(function (resolve) {
                pending = null;
                var once = function () {
                    okBtn.removeEventListener('click', onOk);
                    modalEl.removeEventListener('hidden.bs.modal', onHide);
                };
                var onOk = function () { once(); bsModal.hide(); resolve(true); };
                var onHide = function () { once(); resolve(false); };
                okBtn.addEventListener('click', onOk);
                modalEl.addEventListener('hidden.bs.modal', onHide);
                ask({ message: message, title: opts.title, okText: opts.okText, danger: opts.danger });
            });
        };
    })();

    // ═══════════════════════════════════════════
    // ppmsPrompt — browser ke prompt() ki jagah
    // ───────────────────────────────────────────
    // prompt() ke saath teen dikkatein thin: dikhne me app se bilkul alag,
    // uske OK/Cancel browser ki apni bhasha me, aur password maangte waqt
    // akshar khule dikhte the. Ab _Layout ka Bootstrap modal use hota hai.
    //
    //   ppmsPrompt('Reason for voiding this bill').then(function (v) {
    //       if (v === null) { return; }   // user ne Cancel kiya
    //   });
    //
    // Options: { title, okText, password: true, required: true, minLength: 6,
    //            errorText: '...' , placeholder: '...' }
    // ═══════════════════════════════════════════
    (function () {
        var modalEl = document.getElementById('appPromptModal');
        if (!modalEl) {
            // Purana layout — prompt() par wapas gir jao, taaki page toote nahi.
            window.ppmsPrompt = function (label) {
                return Promise.resolve(window.prompt(label));
            };
            return;
        }

        var bsModal = null;
        var titleEl = document.getElementById('appPromptTitle');
        var labelEl = document.getElementById('appPromptLabel');
        var inputEl = document.getElementById('appPromptInput');
        var errorEl = document.getElementById('appPromptError');
        var okBtn = document.getElementById('appPromptOk');
        var defaultTitle = titleEl ? titleEl.textContent : 'Please enter';
        var defaultOk = okBtn ? okBtn.textContent : 'OK';

        window.ppmsPrompt = function (label, opts) {
            opts = opts || {};
            if (!bsModal) { bsModal = new bootstrap.Modal(modalEl); }

            titleEl.textContent = opts.title || defaultTitle;
            labelEl.textContent = label || '';
            okBtn.textContent = opts.okText || defaultOk;
            inputEl.type = opts.password ? 'password' : 'text';
            inputEl.placeholder = opts.placeholder || '';
            inputEl.value = '';
            errorEl.textContent = '';
            errorEl.classList.add('d-none');

            return new Promise(function (resolve) {
                var settled = false;

                function cleanup() {
                    okBtn.removeEventListener('click', onOk);
                    inputEl.removeEventListener('keydown', onKey);
                    inputEl.removeEventListener('input', clearError);
                    modalEl.removeEventListener('hidden.bs.modal', onHide);
                    modalEl.removeEventListener('shown.bs.modal', onShown);
                }
                function clearError() { errorEl.classList.add('d-none'); }
                function fail(msg) {
                    errorEl.textContent = msg;
                    errorEl.classList.remove('d-none');
                    inputEl.focus();
                }
                function onOk() {
                    var v = inputEl.value;
                    // Jaanch yahin kar lete hain — warna modal band hone ke baad
                    // galti batani padti hai aur user ko dobara sab likhna padta hai.
                    if (opts.required && v.trim() === '') {
                        fail(opts.errorText || 'This cannot be left blank.');
                        return;
                    }
                    if (opts.minLength && v.length < opts.minLength) {
                        fail(opts.errorText || ('Must be at least ' + opts.minLength + ' characters.'));
                        return;
                    }
                    settled = true;
                    cleanup();
                    bsModal.hide();
                    resolve(v);
                }
                function onKey(e) { if (e.key === 'Enter') { e.preventDefault(); onOk(); } }
                function onHide() {
                    if (settled) { return; }
                    cleanup();
                    resolve(null);           // Cancel / cross / Esc
                }
                function onShown() { inputEl.focus(); }

                okBtn.addEventListener('click', onOk);
                inputEl.addEventListener('keydown', onKey);
                inputEl.addEventListener('input', clearError);
                modalEl.addEventListener('hidden.bs.modal', onHide);
                modalEl.addEventListener('shown.bs.modal', onShown);
                bsModal.show();
            });
        };
    })();

    // ═══════════════════════════════════════════
    // CSRF token — JSON bhejne wale fetch ke liye
    // ───────────────────────────────────────────
    // <form> se jaane wale POST me token apne aap chala jaata hai. Par jo POST
    // fetch() se JSON bhejte hain unme kuch nahi jaata tha — server unhe verify
    // hi nahi kar paata tha.
    //
    // ppmsFetch() bilkul fetch() jaisa hai, bas token header me daal deta hai.
    // Server side: Program.cs me HeaderName = "RequestVerificationToken" set hai
    // aur action par [ValidateAntiForgeryToken] laga hai.
    // ═══════════════════════════════════════════
    window.ppmsCsrfToken = function () {
        var el = document.querySelector('input[name="__RequestVerificationToken"]');
        return el ? el.value : '';
    };

    window.ppmsFetch = function (url, options) {
        options = options || {};
        var headers = new Headers(options.headers || {});
        headers.set('RequestVerificationToken', window.ppmsCsrfToken());
        return fetch(url, Object.assign({}, options, {
            headers: headers,
            credentials: options.credentials || 'same-origin'
        }));
    };

    // ═══════════════════════════════════════════
    // Toast — chhote "ho gaya" type sandesh ke liye
    // Page hilta nahi, khud gayab ho jaata hai.
    //   ppmsToast('Saved', { type: 'success' | 'danger' | 'info' })
    // ═══════════════════════════════════════════
    window.ppmsToast = function (message, opts) {
        opts = opts || {};
        var box = document.getElementById('appToastContainer');
        if (!box) { return; }
        var el = document.createElement('div');
        el.className = 'toast align-items-center border-0 text-bg-' + (opts.type || 'dark');
        el.setAttribute('role', 'status');
        el.innerHTML = '<div class="d-flex">'
            + '<div class="toast-body"></div>'
            + '<button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>'
            + '</div>';
        el.querySelector('.toast-body').textContent = message;   // textContent = HTML inject nahi ho sakta
        box.appendChild(el);
        var t = new bootstrap.Toast(el, { delay: opts.delay || 4000 });
        el.addEventListener('hidden.bs.toast', function () { el.remove(); });
        t.show();
    };

    // ═══════════════════════════════════════════
    // Auto-dismiss TempData alert messages after 5s
    // ═══════════════════════════════════════════
    document.querySelectorAll('.alert-dismissible').forEach(function (alert) {
        setTimeout(function () {
            var bsAlert = bootstrap.Alert.getOrCreateInstance(alert);
            if (bsAlert) bsAlert.close();
        }, 5000);
    });

    // ═══════════════════════════════════════════
    // Required Field Validation — kaunsa khaana, aur kahan
    // ───────────────────────────────────────────
    // Pehle ye sirf laal border laga kar submit rok deta tha — koi sandesh nahi.
    // User ko lagta tha button hi kaam nahi kar raha, khaaskar jab khaali khaana
    // page me neeche ho aur dikh hi na raha ho.
    //
    // Ab: har khaali khaane ke NEECHE uska naam le kar sandesh, form ke UPAR sabki
    // ek list, aur pehle khaali khaane par apne aap scroll + focus.
    // ═══════════════════════════════════════════
    (function () {
        var body = document.body;
        var MSG_REQUIRED = body.getAttribute('data-msg-required') || 'This field is required.';
        var MSG_FILL = body.getAttribute('data-msg-fill') || 'Please fill in:';
        var MSG_ONE = body.getAttribute('data-msg-one-field') || 'Please fill in this field before saving.';

        function clean(t) {
            return t.replace(/\s+/g, ' ').replace(/[*:]\s*$/, '').trim();
        }

        // Khaane ka naam nikaalo — pehle uska <label>, warna placeholder, warna name.
        function labelOf(field) {
            var id = field.getAttribute('id');
            if (id && window.CSS && CSS.escape) {
                var byFor = document.querySelector('label[for="' + CSS.escape(id) + '"]');
                if (byFor && byFor.textContent.trim()) { return clean(byFor.textContent); }
            }
            var wrap = field.closest('.mb-1, .mb-2, .mb-3, .col, [class*="col-"]') || field.parentElement;
            var lbl = wrap ? wrap.querySelector('label') : null;
            if (lbl && lbl.textContent.trim()) { return clean(lbl.textContent); }
            if (field.getAttribute('placeholder')) { return clean(field.getAttribute('placeholder')); }
            var n = field.getAttribute('name') || 'This field';
            return n.split('.').pop();          // "Form.FullName" -> "FullName"
        }

        function isEmpty(field) {
            if (field.type === 'checkbox' || field.type === 'radio') { return !field.checked; }
            return !field.value || String(field.value).trim() === '';
        }

        // Khaane ke neeche sandesh — ek hi baar banta hai, dobara istemaal hota hai.
        function markInvalid(field, message) {
            field.classList.add('is-invalid');
            var wrap = field.parentElement;
            if (!wrap) { return; }
            var fb = null;
            for (var i = 0; i < wrap.children.length; i++) {
                if (wrap.children[i].classList.contains('js-field-error')) { fb = wrap.children[i]; break; }
            }
            if (!fb) {
                fb = document.createElement('div');
                fb.className = 'invalid-feedback js-field-error';
                wrap.appendChild(fb);
            }
            fb.textContent = message;
            fb.style.display = 'block';
        }

        function clearInvalid(field) {
            field.classList.remove('is-invalid');
            var wrap = field.parentElement;
            if (!wrap) { return; }
            for (var i = 0; i < wrap.children.length; i++) {
                if (wrap.children[i].classList.contains('js-field-error')) {
                    wrap.children[i].style.display = 'none';
                    break;
                }
            }
        }

        function summaryBox(form) {
            for (var i = 0; i < form.children.length; i++) {
                if (form.children[i].classList.contains('js-form-error-summary')) { return form.children[i]; }
            }
            return null;
        }

        // Form ke sabse upar sabki list — lamba form ho to bhi ek nazar me pata chale.
        function showSummary(form, names) {
            var box = summaryBox(form);
            if (!box) {
                box = document.createElement('div');
                box.className = 'alert alert-danger py-2 px-3 small js-form-error-summary';
                box.setAttribute('role', 'alert');
                form.insertBefore(box, form.firstChild);
            }
            box.textContent = MSG_FILL + ' ' + names.join(', ');
            box.style.display = 'block';
        }

        function hideSummary(form) {
            var box = summaryBox(form);
            if (box) { box.style.display = 'none'; }
        }

        document.querySelectorAll('form').forEach(function (form) {
            // Bharte hi laal nishaan hata do — dobara submit karke pata na karna pade.
            function onFix(e) {
                var f = e.target;
                if (f && f.hasAttribute && f.hasAttribute('required') && !isEmpty(f)) {
                    clearInvalid(f);
                    if (!form.querySelector('.is-invalid')) { hideSummary(form); }
                }
            }
            form.addEventListener('input', onFix, true);
            form.addEventListener('change', onFix, true);

            form.addEventListener('submit', function (e) {
                var missing = [];
                var firstBad = null;

                form.querySelectorAll('[required]').forEach(function (field) {
                    // Chhupe hue khaane (jaise band switch ke andar) ki jaanch mat karo.
                    if (field.disabled) { return; }
                    if (field.type !== 'hidden' && field.offsetParent === null) { return; }

                    if (isEmpty(field)) {
                        var name = labelOf(field);
                        markInvalid(field, name + ' — ' + MSG_REQUIRED);
                        missing.push(name);
                        if (!firstBad) { firstBad = field; }
                    } else {
                        clearInvalid(field);
                    }
                });

                if (missing.length === 0) {
                    hideSummary(form);
                    return;
                }

                e.preventDefault();
                e.stopPropagation();

                if (missing.length > 1) {
                    showSummary(form, missing);
                } else {
                    hideSummary(form);
                    markInvalid(firstBad, labelOf(firstBad) + ' — ' + MSG_ONE);
                }

                // Pehle khaali khaane tak le jao aur cursor wahin rakho.
                if (firstBad) {
                    firstBad.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    setTimeout(function () {
                        try { firstBad.focus({ preventScroll: true }); } catch (_) { }
                    }, 250);
                }
            });
        });
    })();

    // ═══════════════════════════════════════════
    // Dynamic Table Data Labels for Mobile Card View
    // ═══════════════════════════════════════════
    document.querySelectorAll('table.table').forEach(function (table) {
        var headers = Array.from(table.querySelectorAll('thead th')).map(function (th) {
            return th.textContent.trim();
        });
        if (headers.length > 0) {
            table.querySelectorAll('tbody tr').forEach(function (tr) {
                var cells = tr.querySelectorAll('td');
                if (cells.length > 1) {
                    cells.forEach(function (td, index) {
                        if (headers[index] && headers[index] !== '') {
                            td.setAttribute('data-label', headers[index]);
                        }
                    });
                }
            });
        }
    });

})();
