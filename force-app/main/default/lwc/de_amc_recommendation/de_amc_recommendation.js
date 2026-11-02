/**
 * de_amc_recommendation
 * -----------------------------------------------------------------------------
 * Clone of c:amcRecommendations, trimmed to only what the damage-estimate
 * journey needs: the AMC pitch (recommended hero + more plans + T&C). It does
 * NOT place orders itself — instead it emits an `apply` event so the host
 * (c:de_estimate_builder) owns the single order-creation + labour-waive flow.
 *
 * Original ordering / cart / success screens were intentionally dropped.
 */
import { LightningElement, api } from 'lwc';

const AMC_TYPE = 'Comprehensive';
const RAW_PLANS = [
    { id: 'amc-1yr', durationYears: 1, listAmount: 3800, discountPercent: 0 },
    { id: 'amc-2yr', durationYears: 2, listAmount: 7600, discountPercent: 15, badge: 'Popular' },
    { id: 'amc-3yr', durationYears: 3, listAmount: 11400, discountPercent: 20, badge: 'Best value', recommended: true }
];

const inr = (n) =>
    (n || 0).toLocaleString('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 });

export default class De_amc_recommendation extends LightningElement {
    @api recordId;
    @api customerName;
    @api appliedPlanId;

    // T&C bottom-sheet
    termsPlanId = null;

    get customerLabel() {
        return this.customerName ? `For ${this.customerName}` : 'Recommended cover for this customer';
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
        const applied = this.appliedPlanId === p.id;
        return {
            id: p.id,
            amcType: AMC_TYPE,
            durationYears: p.durationYears,
            durationLabel: `${p.durationYears} Year${p.durationYears > 1 ? 's' : ''}`,
            amount,
            amountLabel: inr(amount),
            listAmountLabel: inr(p.listAmount),
            discountPercent: p.discountPercent,
            discountLabel: p.discountPercent > 0 ? `${p.discountPercent}% OFF` : null,
            hasDiscount: p.discountPercent > 0,
            perMonthLabel: `≈ ${inr(perMonth)}/mo`,
            badge: p.badge,
            applied,
            applyLabel: applied ? 'Applied ✓' : 'Apply',
            features: this._features(p),
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

    // Emit the chosen plan up to the host — it creates the order + waives labour.
    handleApply(event) {
        const id = event.currentTarget.dataset.id;
        const plan = [this.recommendedPlan, ...this.otherPlans].find((p) => p.id === id);
        if (!plan) return;
        this.dispatchEvent(
            new CustomEvent('apply', {
                detail: {
                    id: plan.id,
                    amcType: AMC_TYPE,
                    durationYears: plan.durationYears,
                    durationLabel: plan.durationLabel,
                    amount: plan.amount,
                    discountPercent: plan.discountPercent
                }
            })
        );
    }

    // ---- T&C bottom-sheet ----
    get showTerms() {
        return this.termsPlanId != null;
    }

    get termsPlan() {
        return [this.recommendedPlan, ...this.otherPlans].find((p) => p.id === this.termsPlanId);
    }

    handleShowTerms(event) {
        this.termsPlanId = event.currentTarget.dataset.id;
    }

    handleCloseTerms() {
        this.termsPlanId = null;
    }
}
