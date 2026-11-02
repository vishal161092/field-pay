/**
 * de_EstimateBuilderController
 * -----------------------------------------------------------------------------
 * Server support for the c:de_estimate_builder LWC — the "Damage Estimate"
 * journey a Aeris field agent runs from the Salesforce Field Service app.
 *
 * This is a NEW class (de_ prefix). It does NOT modify any existing component.
 * Where the story reuses existing behaviour the LWC calls the existing
 * EstimateBuilderController (search / inventory / alternatives) and
 * AmcOrderController (AMC orders) directly — this class only adds the pieces
 * those don't provide:
 *
 *   - getAcComponentTree() : the Aeris Split-AC component hierarchy
 *                            (Indoor / Outdoor) built from REAL Product2 +
 *                            standard-pricebook data in the org.
 *   - getInitContext()     : resolves BOTH the Work Order and the Asset for the
 *                            launching record (queries the sibling) + Account.
 *   - saveDamageEstimate() : upserts Work_Estimate__c linked to BOTH the Work
 *                            Order and the Asset, and (re)writes its line items.
 *   - sendWhatsAppEstimate(): builds a MOCK WhatsApp message for the estimate.
 *
 * Runs in the agent's own context (with sharing).
 */
public with sharing class de_EstimateBuilderController {

    // Canonical Aeris Split-AC bill of materials, keyed by real ProductCode.
    // These products already exist in the org — nothing here is seeded.
    private static final List<String> INDOOR_CODES = new List<String>{
        'VAC-FILTER', 'VAC-BLOWER', 'VAC-ECOIL', 'VAC-PCB', 'VAC-REMOTE'
    };
    private static final List<String> OUTDOOR_CODES = new List<String>{
        'VAC-CCOIL', 'VAC-COMP', 'VAC-ODFAN', 'VAC-CAP', 'VAC-PIPE-R32'
    };
    private static final String INDOOR_PARENT_CODE = 'VAC-IDU';
    private static final String OUTDOOR_PARENT_CODE = 'VAC-ODU';

    // =====================================================================
    // AC component hierarchy (REAL product + pricebook data)
    // =====================================================================
    /**
     * Returns the Split-AC component hierarchy as two group nodes (Indoor /
     * Outdoor), each with its child parts. Unit price comes from the standard
     * pricebook. Inventory is fetched separately by the LWC (reusing
     * EstimateBuilderController.getInventorySummaries) so this stays cacheable.
     */
    // Returns the tree as a JSON string, not List<TreeGroup>. Nested Apex-defined
    // collections (TreeGroup.parts) do NOT marshal across the Field Service mobile
    // app's imperative-Apex boundary — the call errors there even though it works
    // in Lightning Experience. Same class of issue as the saveDamageEstimate param
    // fix: pass complex shapes as JSON and (de)serialize at the edges.
    //
    // The tree is built from the REAL Asset hierarchy of the launching record so
    // only the parts actually installed on THIS unit are shown. Recommended add-ons
    // and out-of-stock alternates (Alternative_Part__c, fetched separately by the
    // LWC) then complement this set. Falls back to the canonical Split-AC BOM only
    // when the record has no resolvable asset hierarchy, so the journey is never
    // empty.
    @AuraEnabled(cacheable=true)
    public static String getAcComponentTree(String recordId) {
        Id rootAssetId = resolveRootAsset(recordId);
        if (rootAssetId != null) {
            List<TreeGroup> assetGroups = buildAssetTree(rootAssetId);
            if (!assetGroups.isEmpty()) {
                return JSON.serialize(assetGroups);
            }
        }
        return JSON.serialize(buildCanonicalTree());
    }

    /** Resolve the root Asset for a launching WorkOrder or Asset record. */
    private static Id resolveRootAsset(String recordIdStr) {
        Id recordId = toId(recordIdStr);
        if (recordId == null) {
            return null;
        }
        String t = String.valueOf(recordId.getSObjectType());
        Id assetId = null;
        if (t == 'Asset') {
            assetId = recordId;
        } else if (t == 'WorkOrder') {
            for (WorkOrder w : [SELECT AssetId FROM WorkOrder WHERE Id = :recordId LIMIT 1]) {
                assetId = w.AssetId;
            }
        }
        if (assetId == null) {
            return null;
        }
        for (Asset a : [SELECT Id, RootAssetId FROM Asset WHERE Id = :assetId LIMIT 1]) {
            return a.RootAssetId != null ? a.RootAssetId : a.Id;
        }
        return null;
    }

    /**
     * Build the component tree from the asset hierarchy. Each direct child of the
     * root becomes a section (Indoor Unit / Outdoor Unit / …); its own children are
     * that section's parts. A leaf that hangs directly off the root (e.g. a
     * Refrigerant Kit) becomes a single-item section of its own.
     */
    private static List<TreeGroup> buildAssetTree(Id rootAssetId) {
        List<Asset> all = [
            SELECT Id, Name, ParentId, Product2Id, Product2.Name, Product2.ProductCode,
                   Product2.StockKeepingUnit
            FROM Asset
            WHERE RootAssetId = :rootAssetId
            ORDER BY Name
        ];

        Map<Id, List<Asset>> childrenByParent = new Map<Id, List<Asset>>();
        Set<Id> productIds = new Set<Id>();
        for (Asset a : all) {
            if (a.ParentId != null) {
                if (!childrenByParent.containsKey(a.ParentId)) {
                    childrenByParent.put(a.ParentId, new List<Asset>());
                }
                childrenByParent.get(a.ParentId).add(a);
            }
            if (a.Product2Id != null) {
                productIds.add(a.Product2Id);
            }
        }
        Map<Id, Decimal> priceMap = standardPrices(productIds);

        List<TreeGroup> groups = new List<TreeGroup>();
        List<Asset> topChildren = childrenByParent.get(rootAssetId);
        if (topChildren == null) {
            return groups;
        }
        for (Asset node : topChildren) {
            TreeGroup g = new TreeGroup();
            g.label = node.Name;
            g.icon = iconForGroup(node.Name);
            g.parentProductId = node.Product2Id;
            g.parentName = node.Product2 != null ? node.Product2.Name : node.Name;
            g.parts = new List<PartRef>();

            List<Asset> partAssets = childrenByParent.get(node.Id);
            if (partAssets != null && !partAssets.isEmpty()) {
                // Structural node (e.g. Indoor/Outdoor Unit): its children are the parts.
                for (Asset pa : partAssets) {
                    PartRef r = partRefFor(pa, priceMap);
                    if (r != null) {
                        g.parts.add(r);
                    }
                }
            } else {
                // Leaf directly under the root (e.g. Refrigerant Kit): the node IS the part.
                PartRef r = partRefFor(node, priceMap);
                if (r != null) {
                    g.parts.add(r);
                }
            }
            if (!g.parts.isEmpty()) {
                groups.add(g);
            }
        }
        return groups;
    }

    private static PartRef partRefFor(Asset a, Map<Id, Decimal> priceMap) {
        if (a.Product2Id == null) {
            return null;
        }
        PartRef r = new PartRef();
        r.productId = a.Product2Id;
        r.name = (a.Product2 != null && a.Product2.Name != null) ? a.Product2.Name : a.Name;
        r.productCode = a.Product2 != null ? a.Product2.ProductCode : null;
        r.sku = a.Product2 != null ? a.Product2.StockKeepingUnit : null;
        r.unitPrice = priceMap.containsKey(a.Product2Id) ? priceMap.get(a.Product2Id) : 0;
        return r;
    }

    private static String iconForGroup(String name) {
        String n = (name == null ? '' : name).toLowerCase();
        if (n.contains('indoor')) {
            return 'utility:home';
        }
        if (n.contains('outdoor')) {
            return 'utility:frame_web';
        }
        return 'utility:package';
    }

    // Canonical Split-AC BOM — the original hardcoded hierarchy, kept only as a
    // fallback for records with no resolvable asset hierarchy.
    private static List<TreeGroup> buildCanonicalTree() {
        Set<String> allCodes = new Set<String>();
        allCodes.addAll(INDOOR_CODES);
        allCodes.addAll(OUTDOOR_CODES);
        allCodes.add(INDOOR_PARENT_CODE);
        allCodes.add(OUTDOOR_PARENT_CODE);

        Map<String, Product2> byCode = new Map<String, Product2>();
        Set<Id> productIds = new Set<Id>();
        for (Product2 p : [
            SELECT Id, Name, ProductCode, StockKeepingUnit
            FROM Product2
            WHERE ProductCode IN :allCodes AND IsActive = true
        ]) {
            byCode.put(p.ProductCode, p);
            productIds.add(p.Id);
        }

        Map<Id, Decimal> priceMap = standardPrices(productIds);

        List<TreeGroup> groups = new List<TreeGroup>();
        groups.add(buildGroup('Indoor Unit', 'utility:home', byCode.get(INDOOR_PARENT_CODE), INDOOR_CODES, byCode, priceMap));
        groups.add(buildGroup('Outdoor Unit', 'utility:frame_web', byCode.get(OUTDOOR_PARENT_CODE), OUTDOOR_CODES, byCode, priceMap));
        return groups;
    }

    private static TreeGroup buildGroup(String label, String icon, Product2 parent,
                                        List<String> childCodes, Map<String, Product2> byCode,
                                        Map<Id, Decimal> priceMap) {
        TreeGroup g = new TreeGroup();
        g.label = label;
        g.icon = icon;
        g.parts = new List<PartRef>();
        if (parent != null) {
            g.parentProductId = parent.Id;
            g.parentName = parent.Name;
        }
        for (String code : childCodes) {
            Product2 p = byCode.get(code);
            if (p == null) {
                continue;
            }
            PartRef r = new PartRef();
            r.productId = p.Id;
            r.name = p.Name;
            r.productCode = p.ProductCode;
            r.sku = p.StockKeepingUnit;
            r.unitPrice = priceMap.containsKey(p.Id) ? priceMap.get(p.Id) : 0;
            g.parts.add(r);
        }
        return g;
    }

    // =====================================================================
    // Launch context — resolve BOTH Work Order and Asset (+ Account)
    // =====================================================================
    /**
     * Given the launching record (a Work Order OR an Asset, or null), returns
     * both linked records so the estimate can be tied to each one. When the
     * launch record is a Work Order we read its Asset; when it's an Asset we
     * find its most recent Work Order.
     */
    @AuraEnabled(cacheable=true)
    public static InitContext getInitContext(Id recordId) {
        InitContext ctx = new InitContext();
        if (recordId == null) {
            return ctx;
        }
        String t = String.valueOf(recordId.getSObjectType());
        ctx.launchObject = t;

        if (t == 'WorkOrder') {
            for (WorkOrder w : [
                SELECT Id, WorkOrderNumber, AssetId, Asset.Name, AccountId, Account.Name,
                       ContactId, Contact.Name, Contact.MobilePhone, Contact.Phone
                FROM WorkOrder WHERE Id = :recordId LIMIT 1
            ]) {
                ctx.workOrderId = w.Id;
                ctx.workOrderNumber = w.WorkOrderNumber;
                ctx.assetId = w.AssetId;
                ctx.assetName = w.Asset != null ? w.Asset.Name : null;
                ctx.accountId = w.AccountId;
                ctx.accountName = w.Account != null ? w.Account.Name : null;
                if (w.ContactId != null) {
                    ctx.contactId = w.ContactId;
                    ctx.contactName = w.Contact.Name;
                    ctx.contactPhone = firstNonBlank(w.Contact.MobilePhone, w.Contact.Phone);
                }
            }
        } else if (t == 'Asset') {
            for (Asset a : [
                SELECT Id, Name, AccountId, Account.Name,
                       ContactId, Contact.Name, Contact.MobilePhone, Contact.Phone
                FROM Asset WHERE Id = :recordId LIMIT 1
            ]) {
                ctx.assetId = a.Id;
                ctx.assetName = a.Name;
                ctx.accountId = a.AccountId;
                ctx.accountName = a.Account != null ? a.Account.Name : null;
                if (a.ContactId != null) {
                    ctx.contactId = a.ContactId;
                    ctx.contactName = a.Contact.Name;
                    ctx.contactPhone = firstNonBlank(a.Contact.MobilePhone, a.Contact.Phone);
                }
            }
            // Sibling: most recent Work Order for this asset
            for (WorkOrder w : [
                SELECT Id, WorkOrderNumber, ContactId, Contact.Name, Contact.MobilePhone, Contact.Phone
                FROM WorkOrder WHERE AssetId = :recordId ORDER BY CreatedDate DESC LIMIT 1
            ]) {
                ctx.workOrderId = w.Id;
                ctx.workOrderNumber = w.WorkOrderNumber;
                if (ctx.contactId == null && w.ContactId != null) {
                    ctx.contactId = w.ContactId;
                    ctx.contactName = w.Contact.Name;
                    ctx.contactPhone = firstNonBlank(w.Contact.MobilePhone, w.Contact.Phone);
                }
            }
        }

        // Fallback: no directly-linked contact — use a contact on the account,
        // preferring one that has a mobile number.
        if (ctx.contactId == null && ctx.accountId != null) {
            List<Contact> contacts = [
                SELECT Id, Name, MobilePhone, Phone FROM Contact
                WHERE AccountId = :ctx.accountId
                ORDER BY MobilePhone NULLS LAST, CreatedDate ASC
                LIMIT 1
            ];
            if (!contacts.isEmpty()) {
                ctx.contactId = contacts[0].Id;
                ctx.contactName = contacts[0].Name;
                ctx.contactPhone = firstNonBlank(contacts[0].MobilePhone, contacts[0].Phone);
            }
        }
        return ctx;
    }

    private static String firstNonBlank(String a, String b) {
        if (String.isNotBlank(a)) {
            return a;
        }
        return String.isNotBlank(b) ? b : null;
    }

    // =====================================================================
    // Save — Work_Estimate__c linked to BOTH Work Order and Asset
    // =====================================================================
    @AuraEnabled
    public static SaveResult saveDamageEstimate(String inputJson) {
        try {
            // The LWC sends the estimate as a JSON string and we deserialize it
            // here. Passing the wrapper object directly proved unreliable in the
            // FSL runtime (nested fields arrived blank), so JSON is the contract.
            EstimateInput input = (EstimateInput) JSON.deserialize(inputJson, EstimateInput.class);

            // Resolve the sibling so both links are always populated.
            Id assetId = toId(input.assetId);
            Id workOrderId = toId(input.workOrderId);
            if (workOrderId != null && assetId == null) {
                for (WorkOrder w : [SELECT AssetId FROM WorkOrder WHERE Id = :workOrderId AND AssetId != null LIMIT 1]) {
                    assetId = w.AssetId;
                }
            } else if (assetId != null && workOrderId == null) {
                for (WorkOrder w : [SELECT Id FROM WorkOrder WHERE AssetId = :assetId ORDER BY CreatedDate DESC LIMIT 1]) {
                    workOrderId = w.Id;
                }
            }

            Work_Estimate__c header = new Work_Estimate__c();
            if (String.isNotBlank(input.estimateId)) {
                header.Id = (Id) input.estimateId;
            }
            header.Asset__c = assetId;
            header.Work_Order__c = workOrderId;
            header.Coverage_Source__c = String.isNotBlank(input.coverageSource) ? input.coverageSource : 'Warranty';
            header.Status__c = String.isNotBlank(input.status) ? input.status : 'Draft';
            upsert header;

            // Re-save semantics: clear existing lines first.
            if (String.isNotBlank(input.estimateId)) {
                delete [SELECT Id FROM Estimate_Line_Item__c WHERE Estimate__c = :header.Id];
            }

            List<Estimate_Line_Item__c> lines = new List<Estimate_Line_Item__c>();
            if (input.lines != null) {
                for (LineInput li : input.lines) {
                    Boolean isLabor = li.lineType != null && li.lineType.equalsIgnoreCase('Labor');
                    Estimate_Line_Item__c line = new Estimate_Line_Item__c();
                    line.Estimate__c = header.Id;
                    line.Line_Type__c = isLabor ? 'Labor' : 'Part';
                    line.Quantity__c = li.quantity != null ? li.quantity : 1;
                    // Discount__c feeds the (1 - Discount) formula, so store a fraction (0-1).
                    line.Discount__c = li.discount != null ? li.discount : 0;
                    line.Description__c = li.description;
                    line.Unit_Price__c = li.unitPrice != null ? li.unitPrice : 0;
                    if (!isLabor) {
                        line.Product__c = toId(li.productId);
                    }
                    lines.add(line);
                }
            }
            if (!lines.isEmpty()) {
                insert lines;
            }

            SaveResult res = new SaveResult();
            res.estimateId = header.Id;
            res.assetId = assetId;
            res.workOrderId = workOrderId;
            for (Work_Estimate__c we : [SELECT Name FROM Work_Estimate__c WHERE Id = :header.Id LIMIT 1]) {
                res.estimateName = we.Name;
            }
            return res;
        } catch (Exception e) {
            throw new AuraHandledException('Could not save the estimate: ' + e.getMessage());
        }
    }

    // =====================================================================
    // Mock WhatsApp send
    // =====================================================================
    /**
     * Builds a MOCK WhatsApp message for the given estimate. No real message is
     * sent — this returns the formatted body + a fake message id so the LWC can
     * show a realistic "sent" confirmation.
     */
    @AuraEnabled
    public static WhatsAppResult sendWhatsAppEstimate(Id estimateId, String toPhone) {
        WhatsAppResult res = new WhatsAppResult();
        res.toPhone = String.isNotBlank(toPhone) ? toPhone : '+91 90000 00000';
        res.messageId = 'WA-MOCK-' + String.valueOf(System.currentTimeMillis());
        res.sentAt = System.now().format('dd MMM yyyy, hh:mm a');

        if (estimateId == null) {
            res.body = 'Your Aeris service estimate is ready.';
            return res;
        }

        Work_Estimate__c est;
        for (Work_Estimate__c we : [
            SELECT Name, Total_Estimated_Price__c, Asset__r.Name, Work_Order__r.WorkOrderNumber
            FROM Work_Estimate__c WHERE Id = :estimateId LIMIT 1
        ]) {
            est = we;
        }
        List<Estimate_Line_Item__c> lines = [
            SELECT Line_Type__c, Description__c, Quantity__c, Unit_Price__c, Total_Price__c,
                   Product__r.Name
            FROM Estimate_Line_Item__c WHERE Estimate__c = :estimateId ORDER BY Line_Type__c
        ];

        String body = 'Aeris Service Estimate';
        if (est != null) {
            body += '\nRef: ' + est.Name;
            if (est.Work_Order__r != null && est.Work_Order__r.WorkOrderNumber != null) {
                body += '  ·  WO ' + est.Work_Order__r.WorkOrderNumber;
            }
            if (est.Asset__r != null && est.Asset__r.Name != null) {
                body += '\nUnit: ' + est.Asset__r.Name;
            }
        }
        body += '\n\nItems';
        for (Estimate_Line_Item__c l : lines) {
            String label = l.Line_Type__c == 'Labor'
                ? (String.isNotBlank(l.Description__c) ? l.Description__c : 'Labour')
                : (l.Product__r != null ? l.Product__r.Name : (String.isNotBlank(l.Description__c) ? l.Description__c : 'Part'));
            String qtyStr = (l.Quantity__c != null && l.Quantity__c > 1)
                ? ' ×' + String.valueOf(l.Quantity__c.setScale(0))
                : '';
            Decimal amt = l.Total_Price__c != null ? l.Total_Price__c : 0;
            body += '\n• ' + label + qtyStr + ' — ₹' + amt.setScale(0).format();
        }
        if (est != null && est.Total_Estimated_Price__c != null) {
            body += '\n\nTotal: ₹' + est.Total_Estimated_Price__c.setScale(0).format();
        }
        res.body = body;
        return res;
    }

    // =====================================================================
    // FSL-safe alternates
    // =====================================================================
    /**
     * Thin wrapper over the reused EstimateBuilderController.getAlternatives so the
     * "Recommended add-ons" and inline out-of-stock alternates work in the Field
     * Service mobile app. That method returns AlternativeRow with a nested
     * inventory[] list, which does NOT marshal across the FSL imperative-Apex
     * boundary — the call errors in the app. Here we invoke it Apex-to-Apex (no
     * boundary) and hand back JSON for the LWC to parse. aspLocationIds arrives as
     * a JSON string for the same boundary reason (inbound list params).
     *
     * NON-cacheable (live): stock is location-specific and changes as inventory is
     * seeded/consumed, so this MUST read fresh every time. The cacheable variants
     * (…Json / …JsonV2) proved unfixable in practice — the Lightning durable "Aura
     * action" cache persists a result keyed by (action, params, user) and survives
     * FSL "clear cache", desktop logout/login, and even a method rename (the client
     * replays the last stored result). That produced the reported bug: a response
     * cached BEFORE stock was seeded kept showing "Out of stock" for parts that were
     * in fact in stock (e.g. Air Filter/Compressor read 0 while a pre-stocked Remote
     * in the same response read 8). A non-cacheable action has no durable entry, so
     * every open hits the server and reflects current inventory. Building an estimate
     * is an online activity (search/save/WhatsApp are also non-cacheable and work for
     * mapped technicians), so the offline trade-off is acceptable — offline, the
     * alternates/recommended section simply stays empty (LWC catch) rather than lying.
     */
    @AuraEnabled
    public static String getPartAlternativesLive(String productId, String vanLocationId, String aspLocationIdsJson) {
        List<Id> aspIds = new List<Id>();
        if (String.isNotBlank(aspLocationIdsJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(aspLocationIdsJson)) {
                String val = o == null ? null : String.valueOf(o);
                if (String.isNotBlank(val)) {
                    aspIds.add((Id) val);
                }
            }
        }
        List<EstimateBuilderController.AlternativeRow> rows =
            EstimateBuilderController.getAlternatives(toId(productId), toId(vanLocationId), aspIds);
        return JSON.serialize(rows);
    }

    // =====================================================================
    // Identify catalog — resolve the fixed chart codes to real Product2 data
    // =====================================================================
    /**
     * Resolves a list of ProductCodes (the 10 identification-chart parts) to their
     * real Product2 id, name, SKU and standard-pricebook price. Returned as a JSON
     * string of PartRef (flat wrapper, but JSON keeps the FSL contract uniform).
     *
     * A code that has no active Product2 comes back with productId == null so the
     * LWC can fall back to a mock stock/price for that "reference-only" part. Live
     * inventory for the resolved ids is fetched separately by the LWC (reusing
     * EstimateBuilderController.getInventorySummaries), so this stays cacheable.
     */
    @AuraEnabled(cacheable=true)
    public static String resolveProductsByCodes(String codesJson) {
        List<String> codes = new List<String>();
        if (String.isNotBlank(codesJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(codesJson)) {
                if (o != null) {
                    codes.add(String.valueOf(o));
                }
            }
        }

        Map<String, Product2> byCode = new Map<String, Product2>();
        Set<Id> productIds = new Set<Id>();
        if (!codes.isEmpty()) {
            for (Product2 p : [
                SELECT Id, Name, ProductCode, StockKeepingUnit
                FROM Product2
                WHERE ProductCode IN :codes AND IsActive = true
            ]) {
                byCode.put(p.ProductCode, p);
                productIds.add(p.Id);
            }
        }
        Map<Id, Decimal> priceMap = standardPrices(productIds);

        List<PartRef> out = new List<PartRef>();
        for (String code : codes) {
            PartRef r = new PartRef();
            r.productCode = code;
            Product2 p = byCode.get(code);
            if (p != null) {
                r.productId = p.Id;
                r.name = p.Name;
                r.sku = p.StockKeepingUnit;
                r.unitPrice = priceMap.containsKey(p.Id) ? priceMap.get(p.Id) : 0;
            }
            out.add(r);
        }
        return JSON.serialize(out);
    }

    // =====================================================================
    // Parts Consumed — log ProductConsumed rows against the Work Order
    // =====================================================================
    /**
     * Called once the customer's payment is collected. Creates one ProductConsumed
     * record per selected part line, linked to the Work Order, so the parts the
     * customer paid for are recorded as consumed against the job.
     *
     * Input arrives as a JSON string ({ workOrderId, lines:[{productId, quantity}] })
     * for the same FSL imperative-Apex marshalling reason as saveDamageEstimate —
     * nested lists / complex params don't survive the mobile boundary as typed
     * objects. Only part lines (with a productId) are sent; labour/AMC lines are
     * excluded on the client.
     *
     * When launched from an Asset the client may not have a Work Order id; in that
     * case we resolve the Asset's LATEST Work Order (most recent CreatedDate) and log
     * against it. If the Asset has no Work Order at all, nothing is logged and the
     * already-saved estimate simply stands (createdCount stays 0, no error).
     *
     * ProductConsumed identifies the product through a PricebookEntry (Product2Id
     * is a derived, non-writable field), so we resolve each part to a PricebookEntry
     * in the Work Order's own pricebook — falling back to the standard pricebook when
     * the Work Order has none. A part with no matching active entry is skipped rather
     * than failing the whole batch (createdCount reflects what was actually logged).
     */
    @AuraEnabled
    public static PartsConsumedResult createPartsConsumed(String inputJson) {
        PartsConsumedResult result = new PartsConsumedResult();
        try {
            PartsConsumedInput input =
                (PartsConsumedInput) JSON.deserialize(inputJson, PartsConsumedInput.class);

            if (input.lines == null || input.lines.isEmpty()) {
                return result; // nothing to consume — createdCount stays 0
            }

            // Resolve the Work Order: use the one passed, else fall back to the
            // Asset's latest Work Order (launched-from-Asset path).
            Id workOrderId = toId(input.workOrderId);
            if (workOrderId == null) {
                Id assetId = toId(input.assetId);
                if (assetId != null) {
                    for (WorkOrder w : [
                        SELECT Id FROM WorkOrder WHERE AssetId = :assetId
                        ORDER BY CreatedDate DESC LIMIT 1
                    ]) {
                        workOrderId = w.Id;
                    }
                }
            }
            if (workOrderId == null) {
                return result; // no Work Order to log against — estimate still stands
            }

            // The ProductConsumed's PricebookEntry must live in the Work Order's
            // pricebook; resolve it (null → standard pricebook).
            Id woPricebookId = null;
            for (WorkOrder w : [SELECT Pricebook2Id FROM WorkOrder WHERE Id = :workOrderId LIMIT 1]) {
                woPricebookId = w.Pricebook2Id;
            }

            Set<Id> productIds = new Set<Id>();
            for (ConsumedLine cl : input.lines) {
                Id pid = toId(cl.productId);
                if (pid != null) {
                    productIds.add(pid);
                }
            }
            Map<Id, Id> pbeByProduct = pricebookEntries(productIds, woPricebookId);

            List<ProductConsumed> toCreate = new List<ProductConsumed>();
            for (ConsumedLine cl : input.lines) {
                Id pid = toId(cl.productId);
                if (pid == null || !pbeByProduct.containsKey(pid)) {
                    continue; // no consumable pricebook entry → skip this line
                }
                ProductConsumed pc = new ProductConsumed();
                pc.WorkOrderId = workOrderId;
                pc.PricebookEntryId = pbeByProduct.get(pid);
                pc.QuantityConsumed = cl.quantity != null && cl.quantity > 0 ? cl.quantity : 1;
                toCreate.add(pc);
            }

            if (!toCreate.isEmpty()) {
                insert toCreate;
            }
            result.workOrderId = workOrderId;
            result.createdCount = toCreate.size();
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Could not record parts consumed: ' + e.getMessage());
        }
    }

    /**
     * Map of Product2Id -> active PricebookEntryId. Prefers entries in the given
     * pricebook (the Work Order's); when none is supplied, uses the standard
     * pricebook — matching how the rest of this journey is priced.
     */
    private static Map<Id, Id> pricebookEntries(Set<Id> productIds, Id pricebookId) {
        Map<Id, Id> byProduct = new Map<Id, Id>();
        if (productIds == null || productIds.isEmpty()) {
            return byProduct;
        }
        List<PricebookEntry> entries = (pricebookId != null)
            ? [SELECT Id, Product2Id FROM PricebookEntry
               WHERE Product2Id IN :productIds AND IsActive = true AND Pricebook2Id = :pricebookId]
            : [SELECT Id, Product2Id FROM PricebookEntry
               WHERE Product2Id IN :productIds AND IsActive = true AND Pricebook2.IsStandard = true];
        for (PricebookEntry pbe : entries) {
            byProduct.put(pbe.Product2Id, pbe.Id);
        }
        return byProduct;
    }

    // =====================================================================
    // Helpers
    // =====================================================================
    private static Id toId(String value) {
        return String.isNotBlank(value) ? (Id) value : null;
    }

    private static Map<Id, Decimal> standardPrices(Set<Id> productIds) {
        Map<Id, Decimal> priceMap = new Map<Id, Decimal>();
        if (productIds == null || productIds.isEmpty()) {
            return priceMap;
        }
        for (PricebookEntry pbe : [
            SELECT Product2Id, UnitPrice FROM PricebookEntry
            WHERE Product2Id IN :productIds AND IsActive = true AND Pricebook2.IsStandard = true
        ]) {
            priceMap.put(pbe.Product2Id, pbe.UnitPrice);
        }
        return priceMap;
    }

    // =====================================================================
    // Wrapper types
    // =====================================================================
    public class TreeGroup {
        @AuraEnabled public String label;
        @AuraEnabled public String icon;
        @AuraEnabled public Id parentProductId;
        @AuraEnabled public String parentName;
        @AuraEnabled public List<PartRef> parts;
    }

    public class PartRef {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
        @AuraEnabled public String sku;
        @AuraEnabled public Decimal unitPrice;
    }

    public class InitContext {
        @AuraEnabled public String launchObject;
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactPhone;
    }

    public class EstimateInput {
        @AuraEnabled public String estimateId;
        @AuraEnabled public String assetId;
        @AuraEnabled public String workOrderId;
        @AuraEnabled public String coverageSource;
        @AuraEnabled public String status;
        @AuraEnabled public List<LineInput> lines;
    }

    public class LineInput {
        @AuraEnabled public String productId;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal discount; // fraction 0-1
        @AuraEnabled public String description;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String lineType; // Part | Labor
    }

    public class SaveResult {
        @AuraEnabled public Id estimateId;
        @AuraEnabled public String estimateName;
        @AuraEnabled public Id assetId;
        @AuraEnabled public Id workOrderId;
    }

    public class WhatsAppResult {
        @AuraEnabled public String messageId;
        @AuraEnabled public String toPhone;
        @AuraEnabled public String body;
        @AuraEnabled public String sentAt;
    }

    public class PartsConsumedInput {
        @AuraEnabled public String workOrderId;
        @AuraEnabled public String assetId;
        @AuraEnabled public List<ConsumedLine> lines;
    }

    public class ConsumedLine {
        @AuraEnabled public String productId;
        @AuraEnabled public Decimal quantity;
    }

    public class PartsConsumedResult {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public Integer createdCount = 0;
    }
}
