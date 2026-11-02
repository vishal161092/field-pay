/**
 * Controller for the c:de_estimate_builder FSL-mobile LWC.
 * Resolves technician inventory context (van + ASP locations), searches products,
 * returns dual-location inventory, alternatives/replacements, the asset hierarchy,
 * and commits a Work_Estimate__c header + Estimate_Line_Item__c lines (parts + labor).
 *
 * Read methods are cacheable (stable keys, @wire/offline-friendly). commitEstimate
 * performs DML so it is imperative-only.
 */
public with sharing class EstimateBuilderController {

    // ---------------------------------------------------------------------
    // Tech context
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static TechContext getTechContext() {
        TechContext ctx = new TechContext();
        ctx.aspLocations = new List<LocationRef>();

        List<ServiceResource> resources = [
            SELECT Id, Name, LocationId, Location.Name
            FROM ServiceResource
            WHERE RelatedRecordId = :UserInfo.getUserId()
            LIMIT 1
        ];
        if (resources.isEmpty()) {
            return ctx; // not a service resource — nothing to resolve
        }
        ServiceResource sr = resources[0];
        ctx.serviceResourceId = sr.Id;
        ctx.vanLocationId = sr.LocationId;
        ctx.vanLocationName = sr.Location != null ? sr.Location.Name : null;

        // Primary territory for this resource
        List<ServiceTerritoryMember> members = [
            SELECT ServiceTerritoryId, ServiceTerritory.ASP_Inventory_Location__c,
                   ServiceTerritory.ASP_Inventory_Location__r.Name
            FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :sr.Id AND TerritoryType = 'P'
            ORDER BY EffectiveStartDate DESC NULLS LAST
            LIMIT 1
        ];
        if (members.isEmpty()) {
            return ctx;
        }
        Id territoryId = members[0].ServiceTerritoryId;

        // ASP location(s) via the standard junction
        for (ServiceTerritoryLocation stl : [
            SELECT LocationId, Location.Name
            FROM ServiceTerritoryLocation
            WHERE ServiceTerritoryId = :territoryId AND LocationId != null
        ]) {
            ctx.aspLocations.add(new LocationRef(stl.LocationId, stl.Location != null ? stl.Location.Name : null));
        }

        // Fallback: custom lookup on the territory when the junction is empty
        if (ctx.aspLocations.isEmpty() && members[0].ServiceTerritory.ASP_Inventory_Location__c != null) {
            ctx.aspLocations.add(new LocationRef(
                members[0].ServiceTerritory.ASP_Inventory_Location__c,
                members[0].ServiceTerritory.ASP_Inventory_Location__r != null
                    ? members[0].ServiceTerritory.ASP_Inventory_Location__r.Name : null
            ));
        }
        return ctx;
    }

    // ---------------------------------------------------------------------
    // Mode A: product search / scan
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static List<ProductRef> searchProducts(String term) {
        List<ProductRef> results = new List<ProductRef>();
        if (String.isBlank(term)) {
            return results;
        }
        String pattern = '%' + term + '%';
        Set<Id> productIds = new Set<Id>();

        for (Product2 p : [
            SELECT Id, Name, ProductCode, StockKeepingUnit
            FROM Product2
            WHERE IsActive = true
              AND (Name LIKE :pattern OR ProductCode LIKE :pattern OR StockKeepingUnit LIKE :pattern)
            ORDER BY Name
            LIMIT 50
        ]) {
            productIds.add(p.Id);
            results.add(new ProductRef(p.Id, p.Name, p.ProductCode, p.StockKeepingUnit));
        }

        // Also resolve a scanned/typed serial number to its product
        for (Asset a : [
            SELECT Product2Id, Product2.Name, Product2.ProductCode, Product2.StockKeepingUnit
            FROM Asset
            WHERE SerialNumber = :term AND Product2Id != null
            LIMIT 5
        ]) {
            if (!productIds.contains(a.Product2Id)) {
                productIds.add(a.Product2Id);
                results.add(new ProductRef(a.Product2Id, a.Product2.Name,
                    a.Product2.ProductCode, a.Product2.StockKeepingUnit));
            }
        }

        // Attach standard-pricebook unit price so the LWC can price cart lines
        Map<Id, Decimal> priceMap = getStandardPrices(productIds);
        for (ProductRef r : results) {
            r.unitPrice = priceMap.containsKey(r.productId) ? priceMap.get(r.productId) : 0;
        }
        return results;
    }

    // ---------------------------------------------------------------------
    // Dual-location inventory (Mode A & B)
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static List<InventoryRow> getDualLocationInventory(Id productId, Id vanLocationId, List<Id> aspLocationIds) {
        return buildInventory(new Set<Id>{ productId }, vanLocationId, aspLocationIds).get(productId);
    }

    /**
     * Bulk inventory summary for a set of products (used by the Tree-grid so every
     * component row can show its van/ASP availability + price in one round-trip).
     * Sums VAN rows -> technicianQty and ASP rows -> aspQty, and attaches the
     * standard-pricebook unit price.
     */
    @AuraEnabled(cacheable=true)
    public static List<InventorySummary> getInventorySummaries(List<Id> productIds, Id vanLocationId, List<Id> aspLocationIds) {
        List<InventorySummary> out = new List<InventorySummary>();
        if (productIds == null || productIds.isEmpty()) {
            return out;
        }
        Set<Id> ids = new Set<Id>(productIds);
        Map<Id, List<InventoryRow>> invByProduct = buildInventory(ids, vanLocationId, aspLocationIds);
        Map<Id, Decimal> priceMap = getStandardPrices(ids);

        for (Id pid : ids) {
            InventorySummary s = new InventorySummary();
            s.productId = pid;
            s.technicianQty = 0;
            s.aspQty = 0;
            for (InventoryRow r : invByProduct.get(pid)) {
                Decimal qty = r.quantityOnHand != null ? r.quantityOnHand : 0;
                if (r.locationRole == 'VAN') {
                    s.technicianQty += qty;
                } else if (r.locationRole == 'ASP') {
                    s.aspQty += qty;
                }
            }
            s.unitPrice = priceMap.containsKey(pid) ? priceMap.get(pid) : 0;
            out.add(s);
        }
        return out;
    }

    // ---------------------------------------------------------------------
    // Alternatives (Mode A) & replacements (Mode B) — same junction
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static List<AlternativeRow> getAlternatives(Id productId, Id vanLocationId, List<Id> aspLocationIds) {
        List<AlternativeRow> rows = new List<AlternativeRow>();
        List<Alternative_Part__c> alts = [
            SELECT Alternative_Product__c, Alternative_Product__r.Name, Rank__c, Reason__c
            FROM Alternative_Part__c
            WHERE Product__c = :productId AND Alternative_Product__c != null
            ORDER BY Rank__c NULLS LAST
        ];
        if (alts.isEmpty()) {
            return rows;
        }

        Set<Id> altProductIds = new Set<Id>();
        for (Alternative_Part__c ap : alts) {
            altProductIds.add(ap.Alternative_Product__c);
        }

        Map<Id, List<InventoryRow>> invByProduct = buildInventory(altProductIds, vanLocationId, aspLocationIds);
        Map<Id, Decimal> priceMap = getStandardPrices(altProductIds);

        for (Alternative_Part__c ap : alts) {
            AlternativeRow r = new AlternativeRow();
            r.productId = ap.Alternative_Product__c;
            r.name = ap.Alternative_Product__r != null ? ap.Alternative_Product__r.Name : null;
            r.rank = ap.Rank__c;
            r.reason = ap.Reason__c;
            r.unitPrice = priceMap.containsKey(ap.Alternative_Product__c) ? priceMap.get(ap.Alternative_Product__c) : 0;
            r.inventory = invByProduct.get(ap.Alternative_Product__c);
            rows.add(r);
        }
        return rows;
    }

    // ---------------------------------------------------------------------
    // Mode B: asset hierarchy
    // ---------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static AssetNode getAssetTree(Id assetId) {
        Asset seed = [SELECT Id, RootAssetId FROM Asset WHERE Id = :assetId LIMIT 1];
        Id rootId = seed.RootAssetId != null ? seed.RootAssetId : seed.Id;

        Map<Id, AssetNode> nodes = new Map<Id, AssetNode>();
        Map<Id, Id> parentOf = new Map<Id, Id>();
        for (Asset a : [
            SELECT Id, Name, ParentId, Product2Id, Product2.Name
            FROM Asset
            WHERE RootAssetId = :rootId OR Id = :rootId
            ORDER BY Name
        ]) {
            AssetNode n = new AssetNode();
            n.assetId = a.Id;
            n.name = a.Name;
            n.productId = a.Product2Id;
            n.productName = a.Product2 != null ? a.Product2.Name : null;
            n.children = new List<AssetNode>();
            nodes.put(a.Id, n);
            parentOf.put(a.Id, a.ParentId);
        }

        AssetNode root = nodes.get(rootId);
        for (Id id : nodes.keySet()) {
            Id parentId = parentOf.get(id);
            if (parentId != null && nodes.containsKey(parentId)) {
                nodes.get(parentId).children.add(nodes.get(id));
            }
        }
        return root;
    }

    /**
     * Resolves a typed/scanned reference to an Asset and returns its hierarchy.
     * Accepts an Asset record Id, else an Asset SerialNumber, else an Asset Name.
     * Returns null when nothing matches so the LWC can surface a "not found" toast.
     */
    @AuraEnabled(cacheable=true)
    public static AssetNode getAssetTreeByRef(String assetRef) {
        if (String.isBlank(assetRef)) {
            return null;
        }
        String ref = assetRef.trim();

        // 1) Try treating the reference as an Asset record Id
        Id assetId = null;
        try {
            Id candidate = (Id) ref;
            if (candidate.getSObjectType() == Asset.SObjectType) {
                assetId = candidate;
            }
        } catch (System.StringException e) {
            // not an Id — fall through to serial/name lookup
        }

        // 2) Fall back to SerialNumber, then Name
        if (assetId == null) {
            List<Asset> matches = [
                SELECT Id FROM Asset
                WHERE SerialNumber = :ref OR Name = :ref
                ORDER BY SerialNumber NULLS LAST
                LIMIT 1
            ];
            if (matches.isEmpty()) {
                return null;
            }
            assetId = matches[0].Id;
        }
        return getAssetTree(assetId);
    }

    // ---------------------------------------------------------------------
    // Commit
    // ---------------------------------------------------------------------
    @AuraEnabled
    public static Id commitEstimate(EstimateInput input) {
        try {
            Work_Estimate__c header = new Work_Estimate__c();
            if (String.isNotBlank(input.estimateId)) {
                header.Id = (Id) input.estimateId;
            }
            header.Asset__c = toId(input.assetId);
            header.Work_Order__c = toId(input.workOrderId);
            header.Work_Type__c = toId(input.workTypeId);
            header.Coverage_Source__c = input.coverageSource;
            header.Status__c = String.isNotBlank(input.status) ? input.status : 'Draft';
            upsert header;

            // Re-save semantics: clear existing lines first
            if (String.isNotBlank(input.estimateId)) {
                delete [SELECT Id FROM Estimate_Line_Item__c WHERE Estimate__c = :header.Id];
            }

            // Resolve missing unit prices for Part lines in bulk
            Set<Id> needPrice = new Set<Id>();
            for (LineInput li : input.lines) {
                if (!isLabor(li) && li.unitPrice == null && String.isNotBlank(li.productId)) {
                    needPrice.add((Id) li.productId);
                }
            }
            Map<Id, Decimal> priceMap = getStandardPrices(needPrice);

            List<Estimate_Line_Item__c> lines = new List<Estimate_Line_Item__c>();
            for (LineInput li : input.lines) {
                Estimate_Line_Item__c line = new Estimate_Line_Item__c();
                line.Estimate__c = header.Id;
                line.Line_Type__c = isLabor(li) ? 'Labor' : 'Part';
                line.Quantity__c = li.quantity != null ? li.quantity : 1;
                line.Discount__c = li.discount != null ? li.discount : 0;
                line.Description__c = li.description;
                if (isLabor(li)) {
                    line.Unit_Price__c = li.unitPrice != null ? li.unitPrice : 0;
                } else {
                    line.Product__c = toId(li.productId);
                    line.Unit_Price__c = li.unitPrice != null
                        ? li.unitPrice
                        : (priceMap.containsKey((Id) li.productId) ? priceMap.get((Id) li.productId) : 0);
                }
                lines.add(line);
            }
            if (!lines.isEmpty()) {
                insert lines;
            }
            return header.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Could not save estimate: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    private static Boolean isLabor(LineInput li) {
        return li.lineType != null && li.lineType.equalsIgnoreCase('Labor');
    }

    private static Id toId(String value) {
        return String.isNotBlank(value) ? (Id) value : null;
    }

    /** Standard-pricebook unit price per Product2 (mirrors WorkOrderController). */
    private static Map<Id, Decimal> getStandardPrices(Set<Id> productIds) {
        Map<Id, Decimal> priceMap = new Map<Id, Decimal>();
        if (productIds == null || productIds.isEmpty()) {
            return priceMap;
        }
        for (PricebookEntry pbe : [
            SELECT Product2Id, UnitPrice
            FROM PricebookEntry
            WHERE Product2Id IN :productIds AND IsActive = true AND Pricebook2.IsStandard = true
        ]) {
            priceMap.put(pbe.Product2Id, pbe.UnitPrice);
        }
        return priceMap;
    }

    /**
     * Builds inventory rows for a set of products across the van + ASP locations.
     * Every requested location produces a row (qty 0 when no ProductItem exists),
     * so the technician always sees a complete "0 available" picture.
     */
    private static Map<Id, List<InventoryRow>> buildInventory(Set<Id> productIds, Id vanLocationId, List<Id> aspLocationIds) {
        Map<Id, List<InventoryRow>> out = new Map<Id, List<InventoryRow>>();

        // Ordered list of locations with their role
        List<LocationSlot> slots = new List<LocationSlot>();
        Set<Id> locIds = new Set<Id>();
        if (vanLocationId != null) {
            slots.add(new LocationSlot(vanLocationId, 'VAN'));
            locIds.add(vanLocationId);
        }
        if (aspLocationIds != null) {
            for (Id locId : aspLocationIds) {
                if (locId != null) {
                    slots.add(new LocationSlot(locId, 'ASP'));
                    locIds.add(locId);
                }
            }
        }

        Map<Id, String> locNames = new Map<Id, String>();
        if (!locIds.isEmpty()) {
            for (Schema.Location loc : [SELECT Id, Name FROM Location WHERE Id IN :locIds]) {
                locNames.put(loc.Id, loc.Name);
            }
        }

        // qty keyed by productId + '|' + locationId
        Map<String, Decimal> qtyMap = new Map<String, Decimal>();
        if (!productIds.isEmpty() && !locIds.isEmpty()) {
            for (ProductItem pi : [
                SELECT Product2Id, LocationId, QuantityOnHand
                FROM ProductItem
                WHERE Product2Id IN :productIds AND LocationId IN :locIds
            ]) {
                String key = pi.Product2Id + '|' + pi.LocationId;
                Decimal current = qtyMap.containsKey(key) ? qtyMap.get(key) : 0;
                qtyMap.put(key, current + (pi.QuantityOnHand != null ? pi.QuantityOnHand : 0));
            }
        }

        for (Id productId : productIds) {
            List<InventoryRow> rows = new List<InventoryRow>();
            for (LocationSlot slot : slots) {
                InventoryRow row = new InventoryRow();
                row.locationId = slot.locId;
                row.locationName = locNames.get(slot.locId);
                row.locationRole = slot.role;
                String key = productId + '|' + slot.locId;
                row.quantityOnHand = qtyMap.containsKey(key) ? qtyMap.get(key) : 0;
                rows.add(row);
            }
            out.put(productId, rows);
        }
        return out;
    }

    private class LocationSlot {
        Id locId;
        String role;
        LocationSlot(Id locId, String role) {
            this.locId = locId;
            this.role = role;
        }
    }

    // ---------------------------------------------------------------------
    // Wrapper types
    // ---------------------------------------------------------------------
    public class TechContext {
        @AuraEnabled public Id serviceResourceId;
        @AuraEnabled public Id vanLocationId;
        @AuraEnabled public String vanLocationName;
        @AuraEnabled public List<LocationRef> aspLocations;
    }

    public class LocationRef {
        @AuraEnabled public Id locationId;
        @AuraEnabled public String name;
        public LocationRef(Id locationId, String name) {
            this.locationId = locationId;
            this.name = name;
        }
    }

    public class ProductRef {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
        @AuraEnabled public String sku;
        @AuraEnabled public Decimal unitPrice;
        public ProductRef(Id productId, String name, String productCode, String sku) {
            this.productId = productId;
            this.name = name;
            this.productCode = productCode;
            this.sku = sku;
        }
    }

    public class InventoryRow {
        @AuraEnabled public Id locationId;
        @AuraEnabled public String locationName;
        @AuraEnabled public String locationRole; // VAN | ASP
        @AuraEnabled public Decimal quantityOnHand;
    }

    public class InventorySummary {
        @AuraEnabled public Id productId;
        @AuraEnabled public Decimal technicianQty;
        @AuraEnabled public Decimal aspQty;
        @AuraEnabled public Decimal unitPrice;
    }

    public class AlternativeRow {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal rank;
        @AuraEnabled public String reason;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public List<InventoryRow> inventory;
    }

    public class AssetNode {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String name;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public List<AssetNode> children;
    }

    public class EstimateInput {
        @AuraEnabled public String estimateId;
        @AuraEnabled public String assetId;
        @AuraEnabled public String workOrderId;
        @AuraEnabled public String workTypeId;
        @AuraEnabled public String coverageSource;
        @AuraEnabled public String status;
        @AuraEnabled public List<LineInput> lines;
    }

    public class LineInput {
        @AuraEnabled public String productId;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal discount;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String lineType; // Part | Labor
    }
}