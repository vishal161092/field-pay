/**
 * de_estimate_builder
 * -----------------------------------------------------------------------------
 * "Damage Estimate" journey for a Aeris field agent, run from the Salesforce
 * Field Service app after a customer raises a complaint. Clone-origin:
 * Damage-estimate journey, reworked into a guided, mobile-first wizard:
 *
 *   1. Identify   — Aeris Split-AC diagram with copyable part numbers.
 *   2. Build      — search a part (REAL data via EstimateBuilderController),
 *                   see the Indoor/Outdoor component hierarchy + recommended
 *                   parts, add parts/alternates to the cart, see the estimate.
 *   3. AMC        — pitch AMC (embeds c:amcRecommendations + reuses
 *                   AmcOrderController); applying it drops labour and re-prices.
 *   4. Save       — Work_Estimate__c linked to BOTH the Work Order and Asset.
 *   5. Share/Pay  — mock WhatsApp send, then collect payment (c:de_payment_collector).
 *
 * Existing components/Apex are reused, never modified. New server logic lives in
 * de_EstimateBuilderController.
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import DE_AERIS_AC from '@salesforce/resourceUrl/de_aerisAc';

// Reused (unchanged) existing Apex
import getTechContext from '@salesforce/apex/EstimateBuilderController.getTechContext';
import getInventorySummaries from '@salesforce/apex/EstimateBuilderController.getInventorySummaries';
import createAmcOrders from '@salesforce/apex/AmcOrderController.createAmcOrders';

// New (de_) Apex
import resolveProductsByCodes from '@salesforce/apex/de_EstimateBuilderController.resolveProductsByCodes';
import getPartAlternativesJson from '@salesforce/apex/de_EstimateBuilderController.getPartAlternativesLive';
import getInitContext from '@salesforce/apex/de_EstimateBuilderController.getInitContext';
import saveDamageEstimate from '@salesforce/apex/de_EstimateBuilderController.saveDamageEstimate';
import sendWhatsAppEstimate from '@salesforce/apex/de_EstimateBuilderController.sendWhatsAppEstimate';
import createPartsConsumed from '@salesforce/apex/de_EstimateBuilderController.createPartsConsumed';

const STAGES = ['identify', 'build', 'share', 'pay'];

// The 10 pointers on the Aeris Split-AC identification chart. Each has a UNIQUE
// ProductCode; at runtime resolveProductsByCodes maps it to a real Product2 (id +
// price) when one exists — those show LIVE van/ASP inventory (and out-of-stock →
// alternates). Codes with no real product are "reference-only" and show a stable
// mock stock/price so the list always looks populated. Names for the parts that
// exist as real products mirror the actual Product2 names.
const PART_CHIPS = [
    { no: 1, name: 'Air Filter', partNumber: '4010A306010A', code: 'VAC-FILTER', section: 'Indoor', desc: 'Removes dust & particles from air' },
    { no: 2, name: 'Filter Frame', partNumber: '4010A306020A', code: 'VAC-ECOIL', section: 'Indoor', desc: 'Holds the air filter in place' },
    { no: 3, name: 'Horizontal Louver', partNumber: '4010A306030A', code: 'VAC-REMOTE', section: 'Indoor', desc: 'Adjusts air flow up & down' },
    { no: 4, name: 'Control PCB', partNumber: '4010A306040A', code: 'VAC-PCB', section: 'Indoor', desc: 'Main control & display board' },
    { no: 5, name: 'Indoor Blower Fan Motor', partNumber: '4010A306050A', code: 'VAC-BLOWER', section: 'Indoor', desc: 'Drives the indoor blower fan' },
    { no: 6, name: 'Outdoor Fan Motor', partNumber: '4010A407060A', code: 'VAC-ODFAN', section: 'Outdoor', desc: 'Drives the outdoor fan blade' },
    { no: 7, name: 'Condenser Coil', partNumber: '4010A407070A', code: 'VAC-CCOIL', section: 'Outdoor', desc: 'Releases heat from refrigerant' },
    { no: 8, name: 'Rotary Compressor', partNumber: '4010A307080A', code: 'VAC-COMP', section: 'Outdoor', desc: 'Compresses refrigerant & circulates' },
    { no: 9, name: 'Copper Piping & Refrigerant Kit (R32)', partNumber: '4010A407090A', code: 'VAC-PIPE-R32', section: 'Outdoor', desc: 'Copper piping & R32 refrigerant charge' },
    { no: 10, name: 'Mounting Base', partNumber: '4010A407100A', code: 'VAC-CAP', section: 'Outdoor', desc: 'Supports & holds the outdoor unit' }
];

const inr = (n) =>
    (Number(n) || 0).toLocaleString('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 });

export default class De_estimate_builder extends LightningElement {
    @api recordId;
    @api objectApiName;

    diagramUrl = DE_AERIS_AC;

    // ---- Wizard ----
    @track stage = 'identify';

    // ---- Context ----
    @track ctx = {}; // { workOrderId, workOrderNumber, assetId, assetName, accountId, accountName }
    techContext = {};
    aspLocationIds = [];

    // ---- Identify parts (the 10 chart parts, enriched with real/mock stock) ----
    searchTerm = ''; // filters the identify list client-side
    @track identifyParts = []; // [{ no, name, partNumber, desc, code, productId, mock, unitPrice, van, asp, outOfStock, expanded, alternates, ... }]

    // ---- Cart ----
    @track cart = [];
    _keySeq = 0;
    laborCharge = 560;
    coverageSource = 'Warranty';

    // ---- AMC ----
    showAmcModal = false;
    @track amcApplied = null; // { id, durationLabel, amount, discountPercent, orderNumber }
    amcPlacing = false;

    // ---- Save / share / pay ----
    isLoading = false;
    savedEstimateId;
    savedEstimateName;
    @track waResult = null; // { toPhone, body, sentAt }
    waSending = false;
    waPhone = '';
    partsConsumedDone = false; // guard so we log Parts Consumed only once per payment

    // =====================================================================
    // Lifecycle
    // =====================================================================
    async connectedCallback() {
        this.loadContext();
    }

    async loadContext() {
        try {
            const [init, tech] = await Promise.all([
                getInitContext({ recordId: this.recordId }),
                getTechContext()
            ]);
            this.ctx = init || {};
            this.techContext = tech || {};
            this.aspLocationIds = (this.techContext.aspLocations || []).map((l) => l.locationId);
            // Prefill the WhatsApp number with the resolved customer contact.
            if (this.ctx.contactPhone) {
                this.waPhone = this.ctx.contactPhone;
            }
        } catch (e) {
            // Non-fatal — the journey still works without pre-resolved context.
        }
        // Build the Identify parts list (needs tech context for live inventory).
        await this.loadIdentifyCatalog();
    }

    // =====================================================================
    // Identify catalog — the 10 chart parts enriched with real/mock inventory
    // =====================================================================
    /**
     * Resolves the 10 chart codes to real Product2 data (id + price) and fetches
     * live inventory for the ones that exist. Codes with no real product fall back
     * to a deterministic mock stock/price so the list always looks populated.
     */
    async loadIdentifyCatalog() {
        const codes = PART_CHIPS.map((c) => c.code);
        let byCode = {};
        try {
            const resolvedJson = await resolveProductsByCodes({ codesJson: JSON.stringify(codes) });
            const resolved = resolvedJson ? JSON.parse(resolvedJson) : [];
            resolved.forEach((r) => {
                byCode[r.productCode] = r;
            });
        } catch (e) {
            byCode = {}; // fall back to all-mock
        }

        // Live inventory for the resolved (real) products only.
        const realIds = Object.values(byCode)
            .filter((r) => r && r.productId)
            .map((r) => r.productId);
        let inv = {};
        if (realIds.length) {
            try {
                const summaries = await getInventorySummaries({
                    productIds: realIds,
                    vanLocationId: this.techContext.vanLocationId,
                    aspLocationIds: this.aspLocationIds
                });
                (summaries || []).forEach((s) => {
                    inv[s.productId] = s;
                });
            } catch (e) {
                inv = {};
            }
        }

        this.identifyParts = PART_CHIPS.map((chip) => this.buildIdentifyPart(chip, byCode[chip.code], inv));
    }

    /** Merge a chart chip with its resolved product + live inventory (or mock). */
    buildIdentifyPart(chip, resolved, inv) {
        const hasProduct = !!(resolved && resolved.productId);
        let van;
        let asp;
        let price;
        let mock;
        if (hasProduct) {
            const summary = inv[resolved.productId];
            van = summary ? summary.technicianQty || 0 : 0;
            asp = summary ? summary.aspQty || 0 : 0;
            price = (summary && summary.unitPrice) || resolved.unitPrice || 0;
            mock = false;
        } else {
            // Reference-only part with no real Product2 — show stable mock inventory.
            const m = this.mockStock(chip.no);
            van = m.van;
            asp = m.asp;
            price = this.mockPrice(chip.no);
            mock = true;
        }
        // Only real products can be genuinely out of stock (→ alternates).
        const outOfStock = !mock && van + asp <= 0;
        return {
            no: chip.no,
            name: chip.name,
            partNumber: chip.partNumber,
            desc: chip.desc,
            code: chip.code,
            productId: hasProduct ? resolved.productId : null,
            mock,
            unitPrice: price,
            priceLabel: inr(price),
            van,
            asp,
            outOfStock,
            stockLabel: outOfStock ? 'Out of stock' : `Van ${van} · ASP ${asp}`,
            stockClass: outOfStock ? 'de-stock de-stock_out' : 'de-stock de-stock_in',
            // Inline alternate expander (shown for out-of-stock parts)
            expanded: false,
            altLoaded: false,
            altLoading: false,
            alternates: []
        };
    }

    /** Deterministic mock van/ASP counts for reference-only parts (always in stock). */
    mockStock(no) {
        return { van: 2 + ((no * 3) % 6), asp: 4 + ((no * 5) % 8) };
    }

    /** Deterministic mock unit price for reference-only parts. */
    mockPrice(no) {
        return 350 + no * 120;
    }

    // =====================================================================
    // Progress indicator
    // =====================================================================
    get steps() {
        const labels = { identify: 'Identify', build: 'Estimate', share: 'Share', pay: 'Payment' };
        const currentIdx = STAGES.indexOf(this.stage);
        return STAGES.map((s, i) => ({
            value: s,
            label: labels[s],
            cls:
                'de-step' +
                (i === currentIdx ? ' de-step_active' : '') +
                (i < currentIdx ? ' de-step_done' : '')
        }));
    }

    get isIdentify() { return this.stage === 'identify'; }
    get isBuild() { return this.stage === 'build'; }
    get isShare() { return this.stage === 'share'; }
    get isPay() { return this.stage === 'pay'; }

    get headerSubtitle() {
        if (this.ctx.accountName) {
            return this.ctx.assetName ? `${this.ctx.accountName} · ${this.ctx.assetName}` : this.ctx.accountName;
        }
        return 'Aeris Field Service';
    }

    // =====================================================================
    // Stage 1 — Identify: filter, add-to-cart, inline alternates
    // =====================================================================
    handleTermChange(event) {
        this.searchTerm = event.target.value;
    }

    goToBuild() {
        this.stage = 'build';
    }

    /** The 10 identify parts, filtered by the search box and decorated with cart state. */
    get identifyPartsView() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        const qty = this.cartQtyByKey;
        return this.identifyParts
            .filter((p) => {
                if (!term) return true;
                return (
                    (p.name || '').toLowerCase().includes(term) ||
                    (p.partNumber || '').toLowerCase().includes(term) ||
                    (p.code || '').toLowerCase().includes(term) ||
                    (p.desc || '').toLowerCase().includes(term)
                );
            })
            .map((p) => {
                const key = p.productId || `code:${p.code}`;
                const inCartQty = qty[key] || 0;
                const inCart = inCartQty > 0;
                const base = p.outOfStock ? 'de-part de-part_out' : 'de-part';
                // Decorate alternates with their own cart state so the expander
                // shows which alternate has already been added to the estimate.
                const alternates = (p.alternates || []).map((a) => {
                    const aQty = qty[a.productId || `code:${a.code}`] || 0;
                    const aInCart = aQty > 0;
                    return {
                        ...a,
                        inCart: aInCart,
                        cartQtyLabel: aInCart ? `In cart · ${aQty}` : '',
                        rowClass: aInCart ? 'de-alt-row de-alt-row_incart' : 'de-alt-row'
                    };
                });
                return {
                    ...p,
                    alternates,
                    inCart,
                    cartQtyLabel: inCart ? `In cart · ${inCartQty}` : '',
                    partClass: inCart ? `${base} de-part_incart` : base
                };
            });
    }

    handleAddPartFromIdentify(event) {
        const code = event.currentTarget.dataset.code;
        const ref = this.identifyParts.find((p) => p.code === code);
        if (ref) {
            this.pushLine({
                productId: ref.productId,
                code: ref.code,
                displayName: ref.name,
                unitPrice: ref.unitPrice
            });
            this.toast('Added', `${ref.name} added to the estimate.`, 'success');
        }
    }

    // =====================================================================
    // Inline alternates — expand a section right below an out-of-stock part
    // =====================================================================
    async handleToggleAlternates(event) {
        const id = event.currentTarget.dataset.id;
        const part = this.findIdentifyPart(id);
        if (!part) return;

        const willExpand = !part.expanded;
        this.setIdentifyPart(id, { expanded: willExpand });
        if (!willExpand || part.altLoaded) {
            return;
        }

        this.setIdentifyPart(id, { altLoading: true });
        try {
            const rowsJson = await getPartAlternativesJson({
                productId: id,
                vanLocationId: this.techContext.vanLocationId,
                aspLocationIdsJson: JSON.stringify(this.aspLocationIds || [])
            });
            const rows = rowsJson ? JSON.parse(rowsJson) : [];
            const alts = (rows || [])
                .filter((r) => !(r.reason && /recommend/i.test(r.reason)))
                .map((r) => this.toSuggestion(r));
            this.setIdentifyPart(id, { alternates: alts, altLoaded: true, altLoading: false });
        } catch (e) {
            this.setIdentifyPart(id, { alternates: [], altLoaded: true, altLoading: false });
        }
    }

    toSuggestion(r) {
        const rows = r.inventory || [];
        const tech = this.sumRole(rows, 'VAN');
        const asp = this.sumRole(rows, 'ASP');
        return {
            productId: r.productId,
            name: r.name,
            reason: r.reason,
            unitPrice: r.unitPrice || 0,
            priceLabel: inr(r.unitPrice || 0),
            stockLabel: tech + asp <= 0 ? 'Out of stock' : `Van ${tech} · ASP ${asp}`
        };
    }

    sumRole(rows, role) {
        return (rows || [])
            .filter((r) => r.locationRole === role)
            .reduce((sum, r) => sum + (r.quantityOnHand || 0), 0);
    }

    findIdentifyPart(id) {
        return this.identifyParts.find((p) => p.productId === id);
    }

    /** Immutably patch a single identify part row. */
    setIdentifyPart(id, patch) {
        this.identifyParts = this.identifyParts.map((p) =>
            p.productId === id ? { ...p, ...patch } : p
        );
    }

    // =====================================================================
    // Cart
    // =====================================================================
    // Alternates (from an out-of-stock part's expander) always carry a real
    // productId, so add them straight to the cart.
    handleAddSuggestion(event) {
        const id = event.currentTarget.dataset.id;
        const pool = [];
        this.identifyParts.forEach((p) => pool.push(...(p.alternates || [])));
        const ref = pool.find((r) => r.productId === id);
        if (ref) {
            this.pushLine({
                productId: ref.productId,
                code: null,
                displayName: ref.name,
                unitPrice: ref.unitPrice
            });
            this.toast('Added', `${ref.name} added to the estimate.`, 'success');
        }
    }

    /** Stable merge key so real products dedupe by id and mock parts dedupe by code. */
    lineKey(productId, code) {
        return productId || `code:${code}`;
    }

    pushLine({ productId, code, displayName, unitPrice }) {
        // Merge duplicates by bumping quantity.
        const mergeKey = this.lineKey(productId, code);
        const existing = this.cart.find((l) => this.lineKey(l.productId, l.code) === mergeKey);
        if (existing) {
            this.cart = this.cart.map((l) =>
                this.lineKey(l.productId, l.code) === mergeKey
                    ? { ...l, quantity: l.quantity + 1 }
                    : l
            );
            return;
        }
        this.cart = [
            ...this.cart,
            {
                key: `line-${this._keySeq++}`,
                productId: productId || null,
                code: code || null,
                displayName,
                quantity: 1,
                unitPrice: unitPrice || 0
            }
        ];
    }

    handleIncrement(event) {
        const key = event.currentTarget.dataset.key;
        this.cart = this.cart.map((l) => (l.key === key ? { ...l, quantity: l.quantity + 1 } : l));
    }

    handleDecrement(event) {
        const key = event.currentTarget.dataset.key;
        this.cart = this.cart.map((l) =>
            l.key === key ? { ...l, quantity: Math.max(1, l.quantity - 1) } : l
        );
    }

    handleRemoveLine(event) {
        const key = event.currentTarget.dataset.key;
        this.cart = this.cart.filter((l) => l.key !== key);
    }

    get cartRows() {
        return this.cart.map((l) => {
            const qty = l.quantity || 0;
            const unit = l.unitPrice || 0;
            return {
                ...l,
                lineTotal: qty * unit,
                lineTotalLabel: inr(qty * unit),
                unitPriceLabel: inr(unit),
                // Only show the per-unit breakdown when it adds information (qty > 1);
                // at qty 1 the line total already equals the unit price.
                showUnit: qty > 1,
                unitTimesLabel: `${inr(unit)} × ${qty}`
            };
        });
    }

    /** merge-key -> total quantity in the cart (for "In cart" badges on the list). */
    get cartQtyByKey() {
        const map = {};
        this.cart.forEach((l) => {
            const k = this.lineKey(l.productId, l.code);
            map[k] = (map[k] || 0) + (l.quantity || 0);
        });
        return map;
    }

    get hasCart() {
        return this.cart.length > 0;
    }

    get partsTotal() {
        return this.cart.reduce((sum, l) => sum + (l.quantity || 0) * (l.unitPrice || 0), 0);
    }

    handleLaborChange(event) {
        this.laborCharge = event.target.value;
    }

    get laborChargeNumber() {
        const n = parseFloat(this.laborCharge);
        return isNaN(n) ? 0 : n;
    }

    // Labour is waived once an AMC is applied.
    get labourApplies() {
        return !this.amcApplied;
    }

    // Keep the labour row visible whenever a charge exists — when an AMC waives
    // it we strike it through and show ₹0 rather than hiding the line.
    get showLabourRow() {
        return this.laborChargeNumber > 0;
    }

    get labourLabel() {
        return inr(this.laborChargeNumber);
    }

    get amcAmount() {
        return this.amcApplied ? this.amcApplied.amount : 0;
    }

    get amcLabel() {
        return inr(this.amcAmount);
    }

    get partsTotalLabel() {
        return inr(this.partsTotal);
    }

    get grandTotal() {
        return this.partsTotal + (this.labourApplies ? this.laborChargeNumber : 0) + this.amcAmount;
    }

    get grandTotalLabel() {
        return inr(this.grandTotal);
    }

    get coverageOptions() {
        return [
            { label: 'Warranty', value: 'Warranty' },
            { label: 'Contract', value: 'Contract' }
        ];
    }

    handleCoverageChange(event) {
        this.coverageSource = event.detail.value;
    }

    // =====================================================================
    // Stage — AMC pitch (embed c:de_amc_recommendation + reuse AmcOrderController)
    // The pitch UI lives entirely in the cloned c:de_amc_recommendation child; it
    // emits an `apply` event with the chosen plan. This host owns the single
    // order-creation + labour-waive flow so no duplicate orders are placed.
    // =====================================================================
    // Reflected into the child so the applied plan shows "Applied ✓".
    get appliedAmcPlanId() {
        return this.amcApplied ? this.amcApplied.id : null;
    }

    openAmc() {
        this.showAmcModal = true;
    }

    closeAmc() {
        this.showAmcModal = false;
    }

    async handleApplyAmc(event) {
        const plan = event.detail;
        if (!plan || !plan.id) return;
        this.amcPlacing = true;
        let orderNumber = null;
        try {
            // Reuse the existing AMC order Apex so a real Order is created too.
            const results = await createAmcOrders({
                contextId: this.recordId,
                plans: [
                    {
                        amcType: plan.amcType || 'Comprehensive',
                        durationYears: plan.durationYears,
                        amount: plan.amount,
                        discountPercent: plan.discountPercent
                    }
                ]
            });
            orderNumber = results && results.length ? results[0].orderNumber : null;
        } catch (e) {
            // Soft-fail: still apply to the estimate so the demo continues.
            orderNumber = null;
        }
        this.amcApplied = {
            id: plan.id,
            durationLabel: plan.durationLabel,
            amount: plan.amount,
            discountPercent: plan.discountPercent,
            orderNumber
        };
        this.amcPlacing = false;
        this.showAmcModal = false;
        const note = orderNumber ? ` Order ${orderNumber} created.` : '';
        this.toast('AMC applied', `${plan.durationLabel} plan applied — labour waived.${note}`, 'success');
    }

    removeAmc() {
        this.amcApplied = null;
        this.toast('AMC removed', 'Labour charge is included again.', 'info');
    }

    get amcAppliedLabel() {
        return this.amcApplied ? `AMC ${this.amcApplied.durationLabel} · ${this.amcLabel}` : '';
    }

    // =====================================================================
    // Stage — Save (Work_Estimate__c linked to WO + Asset)
    // =====================================================================
    get canSave() {
        return this.hasCart || this.laborChargeNumber > 0 || !!this.amcApplied;
    }

    buildLines() {
        const lines = this.cart.map((l) => ({
            productId: l.productId,
            quantity: l.quantity,
            discount: 0,
            description: l.displayName,
            unitPrice: l.unitPrice,
            lineType: 'Part'
        }));
        if (this.labourApplies && this.laborChargeNumber > 0) {
            lines.push({
                productId: null,
                quantity: 1,
                discount: 0,
                description: 'Labour charges',
                unitPrice: this.laborChargeNumber,
                lineType: 'Labor'
            });
        }
        if (this.amcApplied) {
            lines.push({
                productId: null,
                quantity: 1,
                discount: 0,
                description: `AMC (Comprehensive) — ${this.amcApplied.durationLabel}`,
                unitPrice: this.amcApplied.amount,
                lineType: 'Part'
            });
        }
        return lines;
    }

    async handleSave() {
        if (!this.canSave) {
            this.toast('Nothing to save', 'Add a part, a labour charge or an AMC first.', 'warning');
            return;
        }
        this.isLoading = true;
        try {
            // Send as a JSON string — the nested wrapper object did not survive
            // the FSL imperative-Apex boundary (fields arrived blank).
            const res = await saveDamageEstimate({
                inputJson: JSON.stringify({
                    estimateId: this.savedEstimateId,
                    assetId: this.ctx.assetId,
                    workOrderId: this.ctx.workOrderId,
                    coverageSource: this.coverageSource,
                    status: 'Final',
                    lines: this.buildLines()
                })
            });
            this.savedEstimateId = res.estimateId;
            this.savedEstimateName = res.estimateName;
            // Keep resolved links for the WhatsApp/payment stages.
            this.ctx = { ...this.ctx, assetId: res.assetId, workOrderId: res.workOrderId };
            this.toast('Estimate saved', `${res.estimateName} linked to the Work Order and Asset.`, 'success');
            this.stage = 'share';
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // =====================================================================
    // Stage 3 — Share via WhatsApp (mock)
    // =====================================================================
    handlePhoneChange(event) {
        this.waPhone = event.target.value;
    }

    async handleSendWhatsApp() {
        this.waSending = true;
        try {
            const res = await sendWhatsAppEstimate({
                estimateId: this.savedEstimateId,
                toPhone: this.waPhone
            });
            this.waResult = res;
            this.toast('Sent on WhatsApp', `Estimate sent to ${res.toPhone}.`, 'success');
        } catch (e) {
            this.showError(e);
        } finally {
            this.waSending = false;
        }
    }

    get waBodyLines() {
        if (!this.waResult || !this.waResult.body) return [];
        // Render the message as clean formatted lines instead of raw WhatsApp
        // markdown: section headings are bold, and blank lines in the source
        // become vertical spacing on the next line (empty <p> collapse to 0).
        const raw = this.waResult.body.split('\n');
        const out = [];
        let pendingGap = false;
        raw.forEach((t, i) => {
            if (t.trim() === '') {
                pendingGap = true;
                return;
            }
            const trimmed = t.trim();
            const bold = out.length === 0 || trimmed === 'Items' || trimmed.startsWith('Total');
            let cls = 'de-wa__line';
            if (bold) cls += ' de-wa__line_bold';
            if (pendingGap) cls += ' de-wa__line_gap';
            out.push({ id: i, text: t, cls });
            pendingGap = false;
        });
        return out;
    }

    get whatsAppSent() {
        return !!this.waResult;
    }

    goToPay() {
        this.stage = 'pay';
    }

    // Payment component resolves its own context from the Work Order.
    get paymentRecordId() {
        return this.ctx.workOrderId || this.recordId;
    }

    // The embedded payment collector fires `paid` the moment the mock payment
    // succeeds. That's our cue to record what the customer actually paid for as
    // Parts Consumed against the Work Order — one ProductConsumed row per part line
    // in the cart (labour/AMC lines carry no productId and are skipped server-side).
    async handlePaymentPaid() {
        if (this.partsConsumedDone) {
            return;
        }
        const lines = this.cart
            .filter((l) => l.productId)
            .map((l) => ({ productId: l.productId, quantity: l.quantity || 1 }));
        // Nothing to consume. When launched from an Asset with no Work Order the
        // Apex resolves the latest WO (or logs nothing) — the saved estimate stands
        // either way, so we pass both ids and let the server decide.
        if (!lines.length) {
            return;
        }
        this.partsConsumedDone = true;
        try {
            // JSON string at the boundary — nested lists don't marshal reliably in
            // the FSL mobile imperative-Apex runtime (same contract as save).
            const res = await createPartsConsumed({
                inputJson: JSON.stringify({
                    workOrderId: this.ctx.workOrderId,
                    assetId: this.ctx.assetId,
                    lines
                })
            });
            const count = res && res.createdCount ? res.createdCount : 0;
            if (count > 0) {
                this.toast('Parts consumed', `${count} part(s) recorded on the Work Order.`, 'success');
            }
        } catch (e) {
            // Non-blocking: payment already succeeded, so don't fail the journey.
            this.partsConsumedDone = false;
            this.showError(e);
        }
    }

    // The embedded payment collector fires `close` when the tech taps Done. As the
    // quick-action host we close the action screen so the app returns to the record
    // it was launched from. CloseActionScreenEvent is a no-op outside an action
    // context (e.g. a record-page placement), so this is safe everywhere.
    handlePaymentClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // =====================================================================
    // Navigation helpers
    // =====================================================================
    backToIdentify() { this.stage = 'identify'; }
    backToBuild() { this.stage = 'build'; }
    backToShare() { this.stage = 'share'; }

    // =====================================================================
    // Utilities
    // =====================================================================
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    showError(e) {
        const message = (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
        this.toast('Error', message, 'error');
    }
}
