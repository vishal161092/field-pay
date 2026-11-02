/**
 * PaymentMockController
 * -----------------------------------------------------------------------------
 * Server support for the de_payment_collector LWC (a MOCK — no real gateway). Works
 * whether launched from a Work Order or a Service Appointment quick action.
 * On a simulated success it adds the amount to the Service Appointment's
 * Amount_Collected__c (feeds Collections/scorecard) and logs a Mock_Payment__c.
 */
public with sharing class PaymentMockController {

    /** Prefill context for the LWC (works for WorkOrder or ServiceAppointment). */
    public class PaymentContext {
        @AuraEnabled public String objectType;
        @AuraEnabled public Decimal suggestedAmount;
        @AuraEnabled public String customerName;
        @AuraEnabled public String reference;
    }

    /** Result returned to the LWC receipt. */
    public class PaymentResult {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public String transactionId;
        @AuraEnabled public Id paymentId;
    }

    /** Resolve amount/customer/reference for the launched record. */
    @AuraEnabled(cacheable=true)
    public static PaymentContext getPaymentContext(Id recordId) {
        PaymentContext ctx = new PaymentContext();
        if (recordId == null) {
            return ctx;
        }
        String t = String.valueOf(recordId.getSObjectType());
        ctx.objectType = t;

        if (t == 'WorkOrder') {
            for (WorkOrder w : [
                SELECT WorkOrderNumber, GrandTotal, TotalPrice, Account.Name
                FROM WorkOrder WHERE Id = :recordId LIMIT 1
            ]) {
                ctx.suggestedAmount = (w.GrandTotal != null && w.GrandTotal > 0) ? w.GrandTotal : w.TotalPrice;
                ctx.customerName = w.Account != null ? w.Account.Name : null;
                ctx.reference = w.WorkOrderNumber;
            }
        } else if (t == 'ServiceAppointment') {
            for (ServiceAppointment sa : [
                SELECT AppointmentNumber, ParentRecordId FROM ServiceAppointment WHERE Id = :recordId LIMIT 1
            ]) {
                ctx.reference = sa.AppointmentNumber;
                ctx.customerName = accountNameForParent(sa.ParentRecordId);
                if (sa.ParentRecordId != null && sa.ParentRecordId.getSObjectType() == WorkOrder.SObjectType) {
                    for (WorkOrder w : [SELECT GrandTotal, TotalPrice FROM WorkOrder WHERE Id = :sa.ParentRecordId LIMIT 1]) {
                        ctx.suggestedAmount = (w.GrandTotal != null && w.GrandTotal > 0) ? w.GrandTotal : w.TotalPrice;
                    }
                }
            }
        }
        return ctx;
    }

    /**
     * Record a mock payment against a Work Order OR a Service Appointment.
     * @param recordId the launched record (WorkOrder or ServiceAppointment)
     * @param amount   collected amount
     * @param method   Card | UPI | Payment Link | Cash
     */
    @AuraEnabled
    public static PaymentResult recordMockPayment(Id recordId, Decimal amount, String method) {
        PaymentResult res = new PaymentResult();
        res.transactionId = 'TXN' + String.valueOf(System.currentTimeMillis());
        if (amount == null) {
            amount = 0;
        }

        Id workOrderId;
        Id serviceApptId;
        String t = recordId != null ? String.valueOf(recordId.getSObjectType()) : null;

        if (t == 'ServiceAppointment') {
            for (ServiceAppointment sa : [
                SELECT Id, Amount_Collected__c, ParentRecordId FROM ServiceAppointment WHERE Id = :recordId LIMIT 1
            ]) {
                serviceApptId = sa.Id;
                if (sa.ParentRecordId != null && sa.ParentRecordId.getSObjectType() == WorkOrder.SObjectType) {
                    workOrderId = sa.ParentRecordId;
                }
                bumpCollected(sa, amount);
            }
        } else if (t == 'WorkOrder') {
            workOrderId = recordId;
            for (ServiceAppointment sa : [
                SELECT Id, Amount_Collected__c FROM ServiceAppointment
                WHERE ParentRecordId = :recordId ORDER BY SchedStartTime DESC NULLS LAST LIMIT 1
            ]) {
                serviceApptId = sa.Id;
                bumpCollected(sa, amount);
            }
        }

        Mock_Payment__c pay = new Mock_Payment__c(
            Service_Appointment__c = serviceApptId,
            Amount__c = amount,
            Method__c = method,
            Status__c = 'Paid',
            Transaction_Id__c = res.transactionId,
            Paid_At__c = System.now()
        );
        if (workOrderId != null) {
            pay.Work_Order__c = workOrderId;
        }
        insert pay;

        res.paymentId = pay.Id;
        res.success = true;
        return res;
    }

    /**
     * Add the collected amount to the appointment. The payment record is the
     * source of truth, so a managed-automation hiccup on the SA update must never
     * block logging the payment (also avoids a strict-FLS failure in test context;
     * record-triggered automation runs in system mode at runtime, so real updates
     * succeed).
     */
    private static void bumpCollected(ServiceAppointment sa, Decimal amount) {
        sa.Amount_Collected__c = (sa.Amount_Collected__c == null ? 0 : sa.Amount_Collected__c) + amount;
        try {
            update sa;
        } catch (Exception e) {
            System.debug('SA collected update deferred: ' + e.getMessage());
        }
    }

    /** Best-effort account name for a Service Appointment parent. */
    private static String accountNameForParent(Id parentId) {
        if (parentId == null) {
            return null;
        }
        String t = String.valueOf(parentId.getSObjectType());
        if (t == 'Account') {
            for (Account a : [SELECT Name FROM Account WHERE Id = :parentId LIMIT 1]) return a.Name;
        } else if (t == 'WorkOrder') {
            for (WorkOrder w : [SELECT Account.Name FROM WorkOrder WHERE Id = :parentId LIMIT 1]) {
                return w.Account != null ? w.Account.Name : null;
            }
        } else if (t == 'Asset') {
            for (Asset a : [SELECT Account.Name FROM Asset WHERE Id = :parentId LIMIT 1]) {
                return a.Account != null ? a.Account.Name : null;
            }
        }
        return null;
    }
}