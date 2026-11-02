/**
 * amcRecommendations
 * -----------------------------------------------------------------------------
 * Aeris AMC (Annual Maintenance Contract) upsell for field technicians.
 * Surfaced as a Screen quick action — object-specific (Account / Asset /
 * ServiceAppointment) or GLOBAL (like the Collect Payment action).
 *
 * The recommendation cards are mocked client-side (this is a demo), but
 * "Order Now" / "Place Order" create REAL Order records via Apex so the flow
 * ends on a navigable order.
 *
 * Design goals:
 *  - Premium, mobile-first sheet consistent with the Aeris technicianHome app.
 *  - Resolves its own customer Account server-side, so it works with NO record
 *    context (global action) as well as from a record.
 *  - Every server call is guarded; failures toast instead of blanking the sheet.
 *
 * @author Aeris Field Service
 */
import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

import getContext from '@salesforce/apex/AmcOrderController.getContext';
import createAmcOrders from '@salesforce/apex/AmcOrderController.createAmcOrders';

/**
 * Mocked recommendation catalogue. Prices mirror the reference design:
 *   1 Year  ₹3,800   (no discount)
 *   2 Year  ₹6,460   (15% off ₹7,600)  — Popular
 *   3 Year  ₹9,120   (20% off ₹11,400) — Best value / Recommended
 */
const AMC_TYPE = 'Comprehensive';
const RAW_PLANS = [
    { id: 'amc-1yr', durationYears: 1, listAmount: 3800, discountPercent: 0 },
    { id: 'amc-2yr', durationYears: 2, listAmount: 7600, discountPercent: 15, badge: 'Popular' },
    { id: 'amc-3yr', durationYears: 3, listAmount: 11400, discountPercent: 20, badge: 'Best value', recommended: true }
];

const inr = (n) =>
    (n || 0).toLocaleString('en-IN', {
        style: 'currency',
        currency: 'INR',
        maximumFractionDigits: 0
    });

export default class AmcRecommendations extends NavigationMixin(LightningElement) {
    // Provided automatically for record actions; undefined for a global action.
    @api recordId;
    @api objectApiName;

    // ---- View state ---------------------------------------------------------
    @track step = 'browse'; // browse | success
    @track loading = true;
    @track placing = false;

    accountName;
    _contextLoaded = false;

    // Cart holds plan ids; plan bodies come from the computed `plans` getter.
    @track cartIds = [];

    // T&C bottom-sheet
    @track termsPlanId = null;

    // Success screen
    @track createdOrders = [];

    // ========================================================================
    // Lifecycle
    // ========================================================================
    async connectedCallback() {
        try {
            const ctx = await getContext({ contextId: this.recordId });
            this.accountName = ctx?.accountName;
            this._contextLoaded = true;
        } catch (e) {
            // Non-fatal: the header just omits the customer name. Ordering still
            // resolves the account server-side at submit time.
            this._contextLoaded = true;
        } finally {
            this.loading = false;
        }
    }

    get isBrowse() {
        return this.step === 'browse';
    }

    get isSuccess() {
        return this.step === 'success';
    }

    // ========================================================================
    // Header
    // ========================================================================
    get customerLabel() {
        return this.accountName ? `For ${this.accountName}` : 'Recommended cover for this customer';
    }

    // ========================================================================
    // Plans (mock catalogue -> display model)
    // ========================================================================
    get plans() {
        return RAW_PLANS.map((p) => this._decorate(p));
    }

    get recommendedPlan() {
        const raw = RAW_PLANS.find((p) => p.recommended) || RAW_PLANS[RAW_PLANS.length - 1];
        return this._decorate(raw);
    }

    get otherPlans() {
        const recId = this.recommendedPlan.id;
        return RAW_PLANS.filter((p) => p.id !== recId).map((p) => this._decorate(p));
    }

    _decorate(p) {
        const amount = Math.round(p.listAmount * (1 - p.discountPercent / 100));
        const perMonth = Math.round(amount / (p.durationYears * 12));
        const inCart = this.cartIds.includes(p.id);
        return {
            id: p.id,
            amcType: AMC_TYPE,
            durationYears: p.durationYears,
            durationLabel: `${p.durationYears} Year${p.durationYears > 1 ? 's' : ''}`,
            amount,
            amountLabel: inr(amount),
            listAmount: p.listAmount,
            listAmountLabel: inr(p.listAmount),
            discountPercent: p.discountPercent,
            discountLabel: p.discountPercent > 0 ? `${p.discountPercent}% OFF` : null,
            hasDiscount: p.discountPercent > 0,
            perMonthLabel: `≈ ${inr(perMonth)}/mo`,
            badge: p.badge,
            recommended: !!p.recommended,
            inCart,
            addLabel: inCart ? 'In Cart' : 'Add to Cart',
            features: this._features(p),
            // convenience for card class binding
            cardClass: p.recommended ? 'amc-card amc-card_hero' : 'amc-card'
        };
    }

    _features(p) {
        const feats = [
            'Unlimited breakdown visits',
            '100% genuine Aeris spare parts',
            'Gas top-up & refill included',
            `${p.durationYears * 2} preventive maintenance visits`
        ];
        if (p.recommended) {
            feats.push('Priority same-day scheduling');
        }
        return feats;
    }

    // ========================================================================
    // Cart
    // ========================================================================
    get cartCount() {
        return this.cartIds.length;
    }

    get hasCart() {
        return this.cartIds.length > 0;
    }

    get cartTotalLabel() {
        const total = this.cartIds.reduce((sum, id) => {
            const plan = this.plans.find((p) => p.id === id);
            return sum + (plan ? plan.amount : 0);
        }, 0);
        return inr(total);
    }

    get placeOrderLabel() {
        return this.cartCount > 1 ? `Place ${this.cartCount} Orders` : 'Place Order';
    }

    handleAddToCart(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        if (this.cartIds.includes(id)) {
            // Toggle out — acts as "remove" for a friendlier single button.
            this.cartIds = this.cartIds.filter((x) => x !== id);
            return;
        }
        this.cartIds = [...this.cartIds, id];
        const plan = this.plans.find((p) => p.id === id);
        this._toast('Added to cart', `${plan.amcType} · ${plan.durationLabel} (${plan.amountLabel})`, 'success');
    }

    // ========================================================================
    // Ordering
    // ========================================================================
    handleOrderNow(event) {
        const id = event.currentTarget.dataset.id;
        const plan = this.plans.find((p) => p.id === id);
        if (plan) {
            this._placeOrders([plan]);
        }
    }

    handlePlaceOrder() {
        const plans = this.cartIds.map((id) => this.plans.find((p) => p.id === id)).filter(Boolean);
        if (plans.length) {
            this._placeOrders(plans);
        }
    }

    async _placeOrders(plans) {
        this.placing = true;
        const payload = plans.map((p) => ({
            amcType: p.amcType,
            durationYears: p.durationYears,
            amount: p.amount,
            discountPercent: p.discountPercent
        }));
        try {
            const results = await createAmcOrders({ contextId: this.recordId, plans: payload });
            this.createdOrders = (results || []).map((r, i) => ({
                orderId: r.orderId,
                orderNumber: r.orderNumber,
                summary: `${plans[i]?.amcType} · ${plans[i]?.durationLabel}`,
                amountLabel: plans[i]?.amountLabel
            }));
            this.step = 'success';
        } catch (e) {
            this._toast('Order failed', this._reduceErr(e), 'error');
        } finally {
            this.placing = false;
        }
    }

    // ========================================================================
    // Terms & conditions bottom-sheet
    // ========================================================================
    get showTerms() {
        return this.termsPlanId != null;
    }

    get termsPlan() {
        return this.plans.find((p) => p.id === this.termsPlanId);
    }

    handleShowTerms(event) {
        this.termsPlanId = event.currentTarget.dataset.id;
    }

    handleCloseTerms() {
        this.termsPlanId = null;
    }

    // ========================================================================
    // Success screen actions
    // ========================================================================
    get isSingleOrder() {
        return this.createdOrders.length === 1;
    }

    get successHeadline() {
        return this.isSingleOrder ? 'AMC order placed' : `${this.createdOrders.length} AMC orders placed`;
    }

    handleViewOrder() {
        const first = this.createdOrders[0];
        if (!first) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: first.orderId, objectApiName: 'Order', actionName: 'view' }
        });
        this.handleClose();
    }

    // ========================================================================
    // Close (quick-action lifecycle; no-op harmlessly outside an action)
    // ========================================================================
    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ========================================================================
    // Utilities
    // ========================================================================
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _reduceErr(e) {
        return (e && e.body && e.body.message) || e?.message || 'Something went wrong. Please try again.';
    }
}