/**
 * de_payment_collector
 * -----------------------------------------------------------------------------
 * Trimmed for embedding inside the damage-estimate
 * journey (c:de_estimate_builder). The one meaningful addition: it accepts a
 * `bill-amount` from the host so the finalized estimate total is auto-loaded as
 * the amount to collect — no re-keying by the technician.
 *
 * Everything else is a faithful clone: amount → method → (card | upi | link |
 * cash) → processing → success, recording via the existing PaymentMockController.
 * Existing components/Apex are reused, never modified.
 */
import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import recordMockPayment from '@salesforce/apex/PaymentMockController.recordMockPayment';
import getPaymentContext from '@salesforce/apex/PaymentMockController.getPaymentContext';

// Demo fallback (used only when neither a bill amount nor record context exists).
const DEMO_AMOUNT = 4500;
const DEMO_CUSTOMER = 'Sharma Residence';
const DEMO_REFERENCE = 'WO-1024';

const METHODS = [
    { key: 'card', label: 'Card', emoji: '💳', desc: 'Debit / credit card' },
    { key: 'upi', label: 'UPI', emoji: '📱', desc: 'Scan QR to pay' },
    { key: 'link', label: 'Payment Link', emoji: '🔗', desc: 'Share with customer' },
    { key: 'cash', label: 'Cash', emoji: '💵', desc: 'Collected in cash' }
];

export default class De_payment_collector extends LightningElement {
    @api recordId; // WorkOrder or ServiceAppointment Id

    // Finalized estimate total pushed down from the host — the amount to bill.
    _billAmount;
    @api
    get billAmount() {
        return this._billAmount;
    }
    set billAmount(value) {
        this._billAmount = value;
        // Keep the collectable amount in sync while sitting on the amount step.
        if (this._billAmountValid() && this.step === 'amount') {
            this.amount = Number(value);
        }
    }

    // Optional host-supplied labels (fall back to record context / demo defaults).
    @api customerName;
    @api reference = DEMO_REFERENCE;

    step = 'amount';
    amount = DEMO_AMOUNT;
    method;
    methodLabel;
    txnId;
    paidAtLabel;
    recordedOffline = false;

    accountName = DEMO_CUSTOMER;

    // Pre-filled mock card details (demo only — not validated or stored anywhere).
    cardNumber = '4111 1111 1111 1111';
    cardExpiry = '12/27';
    cardCvv = '123';
    cardName = 'Rahul Sharma';

    // ---- Prefill (works for WorkOrder or ServiceAppointment) -----------------
    connectedCallback() {
        // A host-supplied customer name wins immediately.
        if (this.customerName) this.accountName = this.customerName;
        // The finalized bill amount is the source of truth when present.
        if (this._billAmountValid()) this.amount = Number(this._billAmount);
        this._loadContext();
    }

    async _loadContext() {
        if (!this.recordId) return;
        try {
            const ctx = await getPaymentContext({ recordId: this.recordId });
            if (!ctx) return;
            // Record context fills any gaps, but never overrides the finalized bill.
            if (ctx.reference && !this.reference) this.reference = ctx.reference;
            if (ctx.customerName && !this.customerName) this.accountName = ctx.customerName;
            if (ctx.suggestedAmount && !this._billAmountValid()) this.amount = ctx.suggestedAmount;
        } catch (e) {
            // Prefill is best-effort; the tech can still enter the amount manually.
        }
    }

    _billAmountValid() {
        return this._billAmount != null && Number(this._billAmount) > 0;
    }

    // ---- Step flags ----------------------------------------------------------
    get isAmount() { return this.step === 'amount'; }
    get isMethod() { return this.step === 'method'; }
    get isCard() { return this.step === 'card'; }
    get isUpi() { return this.step === 'upi'; }
    get isLink() { return this.step === 'link'; }
    get isCash() { return this.step === 'cash'; }
    get isProcessing() { return this.step === 'processing'; }
    get isSuccess() { return this.step === 'success'; }

    get methods() { return METHODS; }

    get amountLabel() {
        return this._fmt(this.amount);
    }

    get amountValid() {
        return this.amount != null && Number(this.amount) > 0;
    }

    get customerLabel() {
        return this.accountName ? this.accountName : (this.reference ? this.reference : 'Customer');
    }

    get payLabel() {
        return 'Pay ' + this.amountLabel;
    }

    get paymentLink() {
        const wo = this.reference || 'REF';
        const amt = this.amount != null ? Math.round(Number(this.amount)) : 0;
        return `https://pay.aeris.example/${wo}/${amt}`;
    }

    // ---- Amount step ---------------------------------------------------------
    handleAmountChange(event) {
        this.amount = event.detail.value;
    }

    goToMethod() {
        if (!this.amountValid) {
            this._toast('Enter an amount', 'Please enter an amount greater than zero.', 'warning');
            return;
        }
        this.step = 'method';
    }

    // ---- Method selection ----------------------------------------------------
    chooseMethod(event) {
        const key = event.currentTarget.dataset.key;
        this.step = key; // card | upi | link | cash
    }

    backToMethod() { this.step = 'method'; }
    backToAmount() { this.step = 'amount'; }

    // ---- Payment link helpers ------------------------------------------------
    copyLink() {
        const link = this.paymentLink;
        if (navigator.clipboard) {
            navigator.clipboard.writeText(link).then(
                () => this._toast('Link copied', 'Payment link copied to clipboard.', 'success'),
                () => this._toast('Copied', link, 'info')
            );
        } else {
            this._toast('Payment link', link, 'info');
        }
    }

    shareLink() {
        const link = this.paymentLink;
        if (navigator.share) {
            navigator.share({ title: 'Aeris payment', text: 'Pay for your service', url: link }).catch(() => {});
        } else {
            this._toast('Share link', 'Send this link to the customer: ' + link, 'info');
        }
    }

    // ---- Pay (all methods converge here) ------------------------------------
    handleCard() { this._pay('Card'); }
    handleUpi() { this._pay('UPI'); }
    handleLink() { this._pay('Payment Link'); }
    handleCash() { this._pay('Cash'); }

    async _pay(method) {
        this.method = method;
        this.methodLabel = method;
        this.step = 'processing';
        try {
            const res = await recordMockPayment({
                recordId: this.recordId,
                amount: Number(this.amount),
                method
            });
            this.txnId = res && res.transactionId ? res.transactionId : this._localTxn();
        } catch (e) {
            // Mock: still show success so the tech isn't blocked; flag for later sync.
            this.txnId = this._localTxn();
            this.recordedOffline = true;
        }
        this.paidAtLabel = new Date().toLocaleString();
        this.step = 'success';
        // Let the host know the finalized estimate has been collected.
        this.dispatchEvent(
            new CustomEvent('paid', {
                detail: { amount: Number(this.amount), method, transactionId: this.txnId }
            })
        );
    }

    // ---- Finish --------------------------------------------------------------
    done() {
        // Tell the host the journey is complete so it can close the action screen
        // and return to the launching record. We deliberately don't import
        // lightning/actions here (kept out of this embeddable child); the host owns
        // that. We still reset locally so any non-closing context is left tidy.
        this.dispatchEvent(new CustomEvent('close'));
        this.step = 'amount';
        this.amount = this._billAmountValid() ? Number(this._billAmount) : DEMO_AMOUNT;
        this.method = undefined;
        this.methodLabel = undefined;
        this.txnId = undefined;
        this.paidAtLabel = undefined;
        this.recordedOffline = false;
        this._loadContext();
    }

    // ---- Utils ---------------------------------------------------------------
    _localTxn() {
        return 'TXN' + Date.now();
    }

    _fmt(v) {
        const n = Number(v);
        if (!v || isNaN(n)) return '₹0';
        return n.toLocaleString('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 });
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
