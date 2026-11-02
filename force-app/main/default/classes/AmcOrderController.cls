/**
 * AmcOrderController
 * -----------------------------------------------------------------------------
 * Server support for the amcRecommendations LWC (Aeris AMC upsell demo).
 *
 * The recommendation cards themselves are mocked client-side, but "Order Now" /
 * "Place Order" create REAL Order header records so the demo produces navigable
 * records. Each selected AMC plan becomes one Order on the customer's Account,
 * with the AMC details captured on custom fields.
 *
 *  - getContext():      resolves the customer Account for the current context
 *                       (explicit record, or the technician's current job) so the
 *                       component works as a global action with no record context.
 *  - createAmcOrders(): inserts one Order per selected plan; returns the created
 *                       order Ids + numbers for the success screen.
 *
 * Runs in the technician's own context (with sharing).
 */
public with sharing class AmcOrderController {

    /** Customer context shown in the component header. */
    public class AmcContext {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
    }

    /** One selected AMC plan sent from the client. */
    public class AmcPlanInput {
        @AuraEnabled public String amcType;
        @AuraEnabled public Integer durationYears;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal discountPercent;
    }

    /** Created-order handle returned to the success screen. */
    public class OrderResult {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
    }

    /**
     * Resolve the customer Account for the given context record. Accepts the
     * record the action was launched from (Account / Asset / WorkOrder /
     * ServiceAppointment / ServiceResource) or null; falls back to the running
     * technician's current-job Account so a GLOBAL action still has context.
     */
    @AuraEnabled(cacheable=true)
    public static AmcContext getContext(Id contextId) {
        AmcContext ctx = new AmcContext();
        Id acctId = resolveAccountId(contextId);
        if (acctId != null) {
            for (Account a : [SELECT Name FROM Account WHERE Id = :acctId LIMIT 1]) {
                ctx.accountId = a.Id;
                ctx.accountName = a.Name;
            }
        }
        return ctx;
    }

    /**
     * Create one Order per selected AMC plan on the resolved Account.
     * @param contextId record the action launched from (may be null for global).
     * @param plans     selected AMC plans (cart or a single "Order Now" plan).
     */
    @AuraEnabled
    public static List<OrderResult> createAmcOrders(Id contextId, List<AmcPlanInput> plans) {
        if (plans == null || plans.isEmpty()) {
            throw new AuraHandledException('No AMC plan was selected.');
        }
        Id acctId = resolveAccountId(contextId);
        if (acctId == null) {
            throw new AuraHandledException(
                'No customer account is available in this context to create an AMC order. Open this from a job or account.'
            );
        }

        List<Order> orders = new List<Order>();
        for (AmcPlanInput p : plans) {
            orders.add(new Order(
                AccountId = acctId,
                EffectiveDate = Date.today(),
                Status = 'Draft',
                AMC_Type__c = p.amcType,
                AMC_Duration_Years__c = p.durationYears,
                AMC_Amount__c = p.amount,
                AMC_Discount_Percent__c = p.discountPercent,
                Description = 'AMC order (mock) — ' + p.amcType + ' · ' + p.durationYears + ' Year'
            ));
        }

        try {
            insert orders;
        } catch (DmlException e) {
            throw new AuraHandledException('Could not create the AMC order: ' + e.getDmlMessage(0));
        }

        Map<Id, String> numbers = new Map<Id, String>();
        for (Order o : [SELECT Id, OrderNumber FROM Order WHERE Id IN :orders]) {
            numbers.put(o.Id, o.OrderNumber);
        }

        List<OrderResult> results = new List<OrderResult>();
        for (Order o : orders) {
            OrderResult r = new OrderResult();
            r.orderId = o.Id;
            r.orderNumber = numbers.get(o.Id);
            results.add(r);
        }
        return results;
    }

    /**
     * Map any supported context record to its customer Account. Delegates the
     * "current job" resolution to TechnicianHomeController so both components
     * agree on what the technician is currently working on.
     */
    private static Id resolveAccountId(Id contextId) {
        if (contextId != null) {
            String sobjType = String.valueOf(contextId.getSObjectType());
            if (sobjType == 'Account') {
                return contextId;
            }
            if (sobjType == 'Asset') {
                for (Asset a : [SELECT AccountId FROM Asset WHERE Id = :contextId AND AccountId != null LIMIT 1]) {
                    return a.AccountId;
                }
            }
            if (sobjType == 'WorkOrder') {
                for (WorkOrder w : [SELECT AccountId FROM WorkOrder WHERE Id = :contextId AND AccountId != null LIMIT 1]) {
                    return w.AccountId;
                }
            }
            if (sobjType == 'ServiceAppointment') {
                for (ServiceAppointment s : [SELECT AccountId FROM ServiceAppointment WHERE Id = :contextId AND AccountId != null LIMIT 1]) {
                    return s.AccountId;
                }
            }
            if (sobjType == 'ServiceResource') {
                return TechnicianHomeController.getContextAccountId(contextId);
            }
        }
        // Global action / no usable context: fall back to the running technician's current job.
        return TechnicianHomeController.getContextAccountId(null);
    }
}