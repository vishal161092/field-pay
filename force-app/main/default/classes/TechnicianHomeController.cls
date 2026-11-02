/**
 * TechnicianHomeController
 * -----------------------------------------------------------------------------
 * Server support for the technicianHome LWC.
 *
 *  - ping():           lightweight online/offline probe. There is no built-in
 *                      connectivity flag in Field Service Mobile, so the client
 *                      derives it on demand: a successful (cacheable=false) call
 *                      means online; any failure means offline.
 *  - getScorecard():   weighted composite performance score (0-100) with a
 *                      component breakdown — self-rendered, NOT a CRM Analytics
 *                      dashboard (weakly supported on FSL Mobile).
 *  - getLeaderboard(): territory ranking by score / collections / jobs / rating.
 *
 * Reads run in the technician's own context (with sharing).
 */
public with sharing class TechnicianHomeController {

    /**
     * Online probe. Returns current server time (epoch millis) so the client can
     * stamp a "last synced" label. Never cached — an offline device fails fast.
     */
    @AuraEnabled(cacheable=false)
    public static Long ping() {
        return System.now().getTime();
    }

    /** The technician's next open appointment. */
    public class NextJob {
        @AuraEnabled public Id id;
        @AuraEnabled public String customer;
        @AuraEnabled public String title;
        @AuraEnabled public Datetime startTime;
        @AuraEnabled public String address;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
    }

    /** Everything the home screen header + Today strip + hero needs, in one call. */
    public class HomeData {
        @AuraEnabled public Id resourceId;
        @AuraEnabled public String firstName;
        @AuraEnabled public String fullName;
        @AuraEnabled public Boolean checkedIn = false;
        @AuraEnabled public Datetime checkedInDate;
        @AuraEnabled public Integer jobsRemaining = 0;
        @AuraEnabled public Integer jobsCompleted = 0;
        @AuraEnabled public Decimal amountCollected = 0;
        @AuraEnabled public NextJob nextJob;
        @AuraEnabled public Decimal score;   // composite performance score (0-100)
        @AuraEnabled public Integer rank;     // territory leaderboard rank (by score)
    }

    /**
     * Single reliable source for the home screen (resolves the running user's
     * ServiceResource server-side). Replaces the GraphQL wires that returned no
     * data in the Field Service mobile app.
     */
    @AuraEnabled(cacheable=false)
    public static HomeData getHome() {
        HomeData home = new HomeData();

        List<ServiceResource> resources = [
            SELECT Id, RelatedRecordId, Checked_In_Out__c, Checked_In_Out_Date__c
            FROM ServiceResource
            WHERE RelatedRecordId = :UserInfo.getUserId()
            LIMIT 1
        ];
        if (resources.isEmpty()) {
            home.firstName = UserInfo.getFirstName();
            home.fullName = UserInfo.getName();
            return home;
        }
        ServiceResource sr = resources[0];
        home.resourceId = sr.Id;
        home.checkedIn = sr.Checked_In_Out__c == true;
        home.checkedInDate = sr.Checked_In_Out_Date__c;
        home.firstName = UserInfo.getFirstName();
        home.fullName = UserInfo.getName();

        Set<String> doneStatuses = new Set<String>{ 'Completed', 'Cannot Complete', 'Canceled' };
        List<ServiceAppointment> todays = [
            SELECT Id, Subject, Status, SchedStartTime, ParentRecordId,
                   Street, City, State, PostalCode, Latitude, Longitude, Amount_Collected__c
            FROM ServiceAppointment
            WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :sr.Id)
              AND SchedStartTime = TODAY
            ORDER BY SchedStartTime ASC
            LIMIT 200
        ];

        ServiceAppointment next;
        for (ServiceAppointment sa : todays) {
            if (doneStatuses.contains(sa.Status)) {
                home.jobsCompleted++;
                if (sa.Amount_Collected__c != null) {
                    home.amountCollected += sa.Amount_Collected__c;
                }
            } else {
                home.jobsRemaining++;
                if (next == null) {
                    next = sa;
                }
            }
        }

        if (next != null) {
            NextJob nj = new NextJob();
            nj.id = next.Id;
            nj.title = next.Subject != null ? next.Subject : 'Service appointment';
            nj.startTime = next.SchedStartTime;
            nj.latitude = next.Latitude;
            nj.longitude = next.Longitude;
            List<String> parts = new List<String>();
            if (next.Street != null) parts.add(next.Street);
            if (next.City != null) parts.add(next.City);
            if (next.State != null) parts.add(next.State);
            if (next.PostalCode != null) parts.add(next.PostalCode);
            nj.address = String.join(parts, ', ');
            nj.customer = accountNameForParent(next.ParentRecordId);
            home.nextJob = nj;
        }

        // Score + territory rank for the Home teaser (one leaderboard build).
        Leaderboard lb = buildLeaderboard('score', sr.Id);
        home.rank = lb.myRank;
        for (LeaderboardEntry e : lb.entries) {
            if (e.isMe) { home.score = e.value; }
        }
        if (home.score == null) {
            Map<Id, ResourceMetrics> selfM = aggregateMetrics(new Set<Id>{ sr.Id });
            home.score = scoreFor(selfM.get(sr.Id)).score;
        }
        return home;
    }

    /** Best-effort account name for a Service Appointment parent record. */
    private static String accountNameForParent(Id parentId) {
        if (parentId == null) {
            return 'Customer';
        }
        String t = String.valueOf(parentId.getSObjectType());
        if (t == 'Account') {
            for (Account a : [SELECT Name FROM Account WHERE Id = :parentId LIMIT 1]) return a.Name;
        } else if (t == 'WorkOrder') {
            for (WorkOrder w : [SELECT Account.Name FROM WorkOrder WHERE Id = :parentId LIMIT 1]) {
                return w.Account != null ? w.Account.Name : 'Customer';
            }
        } else if (t == 'Asset') {
            for (Asset a : [SELECT Account.Name FROM Asset WHERE Id = :parentId LIMIT 1]) {
                return a.Account != null ? a.Account.Name : 'Customer';
            }
        }
        return 'Customer';
    }

    // =========================================================================
    // SOS emergency
    // =========================================================================

    // Default SOS recipient (admin = dispatcher) when SOS_Setting__mdt has no
    // 'Default' record. Override org-wide by creating that Custom Metadata record.
    private static final String DEFAULT_RECIPIENT_USERNAME = '';

    /** Result of an SOS trigger, returned to the LWC confirmation panel. */
    public class SosResult {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public Id sosId;
        @AuraEnabled public Id absenceId;
        @AuraEnabled public Integer apptCount = 0;
        @AuraEnabled public String adminName;
        @AuraEnabled public String dispatcherName;
        @AuraEnabled public String mapsUrl;
    }

    /**
     * Raise an emergency SOS from the mobile home screen. In one transaction:
     * (1) shares the technician's GPS location with the admin, (2) creates a
     * high-priority route-optimisation Task, and (3) shares the day's service
     * appointments with the dispatcher — via an SOS_Alert__c record + Custom
     * Notifications (bell + mobile push). Recipients come from SOS_Setting__mdt.
     */
    @AuraEnabled
    public static SosResult raiseSos(Decimal latitude, Decimal longitude, Decimal accuracy) {
        SosResult res = new SosResult();

        List<ServiceResource> srs = [
            SELECT Id, Name FROM ServiceResource
            WHERE RelatedRecordId = :UserInfo.getUserId() LIMIT 1
        ];
        Id resourceId = srs.isEmpty() ? null : srs[0].Id;
        String techName = srs.isEmpty() ? UserInfo.getName() : srs[0].Name;

        List<ServiceAppointment> todays = new List<ServiceAppointment>();
        if (resourceId != null) {
            todays = [
                SELECT AppointmentNumber, Subject, Status, SchedStartTime,
                       Street, City, State, PostalCode
                FROM ServiceAppointment
                WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :resourceId)
                  AND SchedStartTime = TODAY
                ORDER BY SchedStartTime ASC
                LIMIT 200
            ];
        }
        res.apptCount = todays.size();
        String summary = buildApptSummary(todays);

        String mapsUrl = (latitude != null && longitude != null)
            ? 'https://www.google.com/maps?q=' + latitude + ',' + longitude
            : null;
        res.mapsUrl = mapsUrl;

        // Recipients from config (SOS_Setting__mdt 'Default'), else the org default,
        // else the running user (resolveUser's final fallback).
        SOS_Setting__mdt cfg = SOS_Setting__mdt.getInstance('Default');
        String adminUname = (cfg != null && String.isNotBlank(cfg.Admin_Username__c))
            ? cfg.Admin_Username__c : DEFAULT_RECIPIENT_USERNAME;
        String dispUname = (cfg != null && String.isNotBlank(cfg.Dispatcher_Username__c))
            ? cfg.Dispatcher_Username__c : DEFAULT_RECIPIENT_USERNAME;
        Id adminId = resolveUser(adminUname);
        Id dispatcherId = resolveUser(dispUname);
        String ownerPref = (cfg != null && String.isNotBlank(cfg.Task_Owner__c)) ? cfg.Task_Owner__c : 'admin';
        Id taskOwnerId = ownerPref == 'dispatcher' ? dispatcherId
            : (ownerPref == 'current' ? UserInfo.getUserId() : adminId);
        res.adminName = nameOf(adminId);
        res.dispatcherName = nameOf(dispatcherId);

        // 1 + 3) Persist the SOS record (location + day's appointments).
        SOS_Alert__c sos = new SOS_Alert__c(
            Technician__c = resourceId,
            Technician_User__c = UserInfo.getUserId(),
            Reported_At__c = System.now(),
            Latitude__c = latitude,
            Longitude__c = longitude,
            Location_Accuracy__c = accuracy,
            Maps_URL__c = mapsUrl,
            Status__c = 'New',
            Appointment_Count__c = res.apptCount,
            Appointment_Summary__c = summary
        );
        insert sos;
        res.sosId = sos.Id;

        // 1b) Mark the technician unavailable so the dispatcher/optimiser stops
        //     scheduling onto them: a ResourceAbsence (Type = 'SOS') from the
        //     moment SOS is tapped for the next 12 hours. Guarded — an emergency
        //     must never fail because the absence couldn't be logged (e.g. the
        //     'SOS' Type picklist value isn't deployed yet, or FSL scheduling is off).
        if (resourceId != null) {
            try {
                ResourceAbsence absence = new ResourceAbsence(
                    ResourceId = resourceId,
                    Type = 'SOS',
                    Start = System.now(),
                    End = System.now().addHours(12),
                    Description = 'Auto-created from an emergency SOS raised by ' + techName + '.',
                    // The Field Service scheduling console (Gantt) only renders
                    // absences the managed package considers approved. A raw Apex
                    // insert leaves FSL__Approved__c = false, so the absence is
                    // hidden on the Gantt — force it true so the dispatcher sees it.
                    FSL__Approved__c = true
                );
                // The Gantt also only renders absences that carry a RecordType;
                // an Apex insert leaves RecordTypeId null (invisible). Set it
                // explicitly — 'Non Availability' = the resource is fully
                // unavailable (correct for an emergency).
                Id absenceRtId = resourceAbsenceRecordTypeId();
                if (absenceRtId != null) { absence.RecordTypeId = absenceRtId; }
                insert absence;
                res.absenceId = absence.Id;
            } catch (Exception e) {
                System.debug('SOS ResourceAbsence creation failed: ' + e.getMessage());
            }
        }

        // 2) Route-optimisation Task.
        insert new Task(
            OwnerId = taskOwnerId,
            Subject = 'SOS — Optimise route for ' + techName,
            Description = 'EMERGENCY SOS raised by ' + techName + '.\n'
                + 'Location: ' + (mapsUrl != null ? mapsUrl : 'unavailable') + '\n'
                + 'Jobs today: ' + res.apptCount + '\n\n' + summary,
            ActivityDate = Date.today(),
            Priority = 'High',
            Status = 'Not Started',
            WhatId = sos.Id
        );

        // Notifications (bell + mobile) — never let a hiccup roll back the DML.
        sendSosNotifications(sos.Id, techName, res.apptCount, mapsUrl, adminId, dispatcherId);

        res.success = true;
        return res;
    }

    /**
     * RecordType for the SOS ResourceAbsence. The FSL Gantt only renders
     * absences that carry a RecordType, so we must set one. Prefer
     * 'Non Availability'; fall back to any active ResourceAbsence RecordType;
     * null if the org has none (then it inserts record-type-less, as before).
     */
    private static Id resourceAbsenceRecordTypeId() {
        Id fallback = null;
        for (RecordType rt : [
            SELECT Id, DeveloperName FROM RecordType
            WHERE SobjectType = 'ResourceAbsence' AND IsActive = true
        ]) {
            if (rt.DeveloperName == 'Non_Availability') { return rt.Id; }
            fallback = rt.Id;
        }
        return fallback;
    }

    private static String buildApptSummary(List<ServiceAppointment> appts) {
        if (appts.isEmpty()) { return 'No appointments scheduled today.'; }
        List<String> lines = new List<String>();
        for (ServiceAppointment sa : appts) {
            String t = sa.SchedStartTime != null ? sa.SchedStartTime.format('h:mm a') : '—';
            List<String> addr = new List<String>();
            if (sa.Street != null) { addr.add(sa.Street); }
            if (sa.City != null) { addr.add(sa.City); }
            if (sa.State != null) { addr.add(sa.State); }
            if (sa.PostalCode != null) { addr.add(sa.PostalCode); }
            lines.add('• ' + t + '  ' + sa.AppointmentNumber + '  ' + (sa.Subject != null ? sa.Subject : '')
                + '  [' + sa.Status + ']  ' + String.join(addr, ', '));
        }
        return String.join(lines, '\n');
    }

    private static Id resolveUser(String username) {
        if (String.isBlank(username)) { return UserInfo.getUserId(); }
        List<User> us = [SELECT Id FROM User WHERE Username = :username AND IsActive = true LIMIT 1];
        return us.isEmpty() ? UserInfo.getUserId() : us[0].Id;
    }

    private static String nameOf(Id userId) {
        if (userId == null) { return null; }
        List<User> us = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
        return us.isEmpty() ? null : us[0].Name;
    }

    // Serialised PageReference for the SOS notification tap target: the Field
    // Service scheduling console (Gantt) at /lightning/page/schedulingConsole,
    // so a dispatcher lands where they can reassign the day's route rather than
    // on the raw SOS_Alert__c record.
    private static final String CONSOLE_PAGE_REF =
        '{"type":"standard__webPage","attributes":{"url":"/lightning/page/schedulingConsole"}}';

    private static void sendSosNotifications(Id targetId, String techName, Integer apptCount,
                                             String mapsUrl, Id adminId, Id dispatcherId) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'SOS_Emergency' LIMIT 1
            ];
            if (types.isEmpty()) { return; }
            Id typeId = types[0].Id;

            Messaging.CustomNotification adminNotif = new Messaging.CustomNotification();
            adminNotif.setNotificationTypeId(typeId);
            adminNotif.setTargetId(targetId);
            adminNotif.setTargetPageRef(CONSOLE_PAGE_REF);
            adminNotif.setTitle('🚨 SOS: ' + techName + ' needs help');
            adminNotif.setBody('Location + ' + apptCount + ' job(s) today shared. Tap to open the scheduling console.');
            adminNotif.send(new Set<String>{ String.valueOf(adminId) });

            if (dispatcherId != null && dispatcherId != adminId) {
                Messaging.CustomNotification dispNotif = new Messaging.CustomNotification();
                dispNotif.setNotificationTypeId(typeId);
                dispNotif.setTargetId(targetId);
                dispNotif.setTargetPageRef(CONSOLE_PAGE_REF);
                dispNotif.setTitle('🚨 SOS: reassign ' + techName + '\'s route');
                dispNotif.setBody(apptCount + ' appointment(s) today need coverage. Tap to open the scheduling console.');
                dispNotif.send(new Set<String>{ String.valueOf(dispatcherId) });
            }
        } catch (Exception e) {
            System.debug('SOS notification failed: ' + e.getMessage());
        }
    }

    // =========================================================================
    // Performance scorecard + leaderboard
    // =========================================================================

    private static final Integer SCORE_TARGET = 70;
    private static final Decimal COLLECTIONS_TARGET = 50000; // ₹ per tech per month

    /** Per-resource metrics for the current month (built by aggregateMetrics). */
    private class ResourceMetrics {
        Integer assigned = 0;
        Integer completed = 0;
        Integer cannotComplete = 0;
        Integer onTime = 0;
        Integer slaEligible = 0;
        Decimal ratingSum = 0;
        Integer ratingCount = 0;
        Decimal collected = 0;
        Set<Date> completedDays = new Set<Date>();
    }

    /**
     * Single-SOQL aggregator: current-month appointment metrics keyed by
     * ServiceResource. Shared by the scorecard, leaderboard and home teaser so
     * one query serves the running tech AND all territory peers.
     */
    private static Map<Id, ResourceMetrics> aggregateMetrics(Set<Id> resourceIds) {
        Map<Id, ResourceMetrics> byRes = new Map<Id, ResourceMetrics>();
        for (Id rid : resourceIds) {
            byRes.put(rid, new ResourceMetrics());
        }
        if (resourceIds.isEmpty()) {
            return byRes;
        }
        Datetime monthStart = Datetime.newInstance(Date.today().toStartOfMonth(), Time.newInstance(0, 0, 0, 0));
        for (AssignedResource ar : [
            SELECT ServiceResourceId,
                   ServiceAppointment.Status, ServiceAppointment.SchedStartTime,
                   ServiceAppointment.ActualEndTime, ServiceAppointment.DueDate,
                   ServiceAppointment.Customer_Rating__c, ServiceAppointment.Amount_Collected__c
            FROM AssignedResource
            WHERE ServiceResourceId IN :resourceIds
              AND ServiceAppointment.SchedStartTime >= :monthStart
            LIMIT 20000
        ]) {
            ResourceMetrics m = byRes.get(ar.ServiceResourceId);
            if (m == null) { continue; }
            ServiceAppointment sa = ar.ServiceAppointment;
            m.assigned++;
            if (sa.Status == 'Completed') {
                m.completed++;
                if (sa.SchedStartTime != null) { m.completedDays.add(sa.SchedStartTime.date()); }
                if (sa.Amount_Collected__c != null) { m.collected += sa.Amount_Collected__c; }
                if (sa.DueDate != null && sa.ActualEndTime != null) {
                    m.slaEligible++;
                    if (sa.ActualEndTime <= sa.DueDate) { m.onTime++; }
                }
                if (sa.Customer_Rating__c != null) { m.ratingSum += sa.Customer_Rating__c; m.ratingCount++; }
            } else if (sa.Status == 'Cannot Complete') {
                m.cannotComplete++;
            }
        }
        return byRes;
    }

    /** One weighted component of the performance score. */
    public class ScoreComponent {
        @AuraEnabled public String name;
        @AuraEnabled public Decimal points;
        @AuraEnabled public Integer maxPoints;
        @AuraEnabled public Integer achievedPct;
        @AuraEnabled public Integer thresholdPct;
        @AuraEnabled public String colorState; // green | amber | red
        @AuraEnabled public Boolean live = false;
    }

    /** The composite performance scorecard. */
    public class Scorecard {
        @AuraEnabled public Decimal score = 0;
        @AuraEnabled public Integer target = SCORE_TARGET;
        @AuraEnabled public String status = 'Below the incentive line';
        @AuraEnabled public Boolean onTrack = false;
        @AuraEnabled public List<ScoreComponent> components = new List<ScoreComponent>();
        @AuraEnabled public String biggestOpportunity;
    }

    private static ScoreComponent comp(String name, Integer weight, Decimal achieved, Integer threshold, Boolean live) {
        ScoreComponent c = new ScoreComponent();
        c.name = name;
        c.maxPoints = weight;
        c.thresholdPct = threshold;
        c.achievedPct = (Integer) Math.round(achieved);
        c.live = live;
        Decimal ratio = threshold > 0 ? (achieved / threshold) : 0;
        if (ratio > 1) { ratio = 1; }
        c.points = (Decimal.valueOf(weight) * ratio).setScale(1);
        Decimal colorRatio = threshold > 0 ? (achieved / threshold) : 0;
        c.colorState = colorRatio >= 1 ? 'green' : (colorRatio >= 0.75 ? 'amber' : 'red');
        return c;
    }

    /** Build the weighted scorecard from a resource's metrics. */
    private static Scorecard scoreFor(ResourceMetrics m) {
        Scorecard sc = new Scorecard();
        if (m == null) { m = new ResourceMetrics(); }

        Decimal slaPct = m.slaEligible > 0 ? (m.onTime * 100.0 / m.slaEligible) : 0;
        Decimal complPct = m.assigned > 0 ? (m.completed * 100.0 / m.assigned) : 0;
        Decimal ratingPct = m.ratingCount > 0 ? ((m.ratingSum / m.ratingCount) / 5 * 100) : 0;
        Decimal collPct = COLLECTIONS_TARGET > 0 ? (m.collected / COLLECTIONS_TARGET * 100) : 0;
        Integer bizDays = businessDaysElapsed();
        Decimal checkinPct = bizDays > 0 ? (m.completedDays.size() * 100.0 / bizDays) : 0;
        Decimal ftfPct = (m.completed + m.cannotComplete) > 0
            ? (m.completed * 100.0 / (m.completed + m.cannotComplete))
            : (m.completed > 0 ? 100 : 0);

        sc.components.add(comp('SLA Adherence', 25, slaPct, 80, true));
        sc.components.add(comp('Job Completion', 20, complPct, 90, false));
        sc.components.add(comp('Customer Rating', 20, ratingPct, 80, false));
        sc.components.add(comp('Collections', 15, collPct, 70, true));
        sc.components.add(comp('Check-in Adherence', 10, checkinPct, 80, true));
        sc.components.add(comp('First-Time-Fix', 10, ftfPct, 85, false));

        Decimal total = 0;
        for (ScoreComponent c : sc.components) { total += c.points; }
        sc.score = total.setScale(1);
        sc.onTrack = sc.score >= SCORE_TARGET;
        sc.status = sc.onTrack ? 'On track — above the incentive line' : 'Below the incentive line';

        ScoreComponent best;
        Decimal bestGap = -1;
        for (ScoreComponent c : sc.components) {
            Decimal gap = c.maxPoints - c.points;
            if (gap > bestGap) { bestGap = gap; best = c; }
        }
        if (best != null && bestGap >= 1) {
            sc.biggestOpportunity = best.name + ' — ' + String.valueOf(Math.round(bestGap)) + ' pts on the table';
        }
        return sc;
    }

    /** Weekdays from the start of the month through today (min 1). */
    private static Integer businessDaysElapsed() {
        Date d = Date.today().toStartOfMonth();
        Date today = Date.today();
        Integer n = 0;
        while (d <= today) {
            String dow = Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('EEE');
            if (dow != 'Sat' && dow != 'Sun') { n++; }
            d = d.addDays(1);
        }
        return n == 0 ? 1 : n;
    }

    /**
     * The running technician's composite performance scorecard for this month.
     * @param resourceId ServiceResource Id; when blank, resolves from the user.
     */
    @AuraEnabled(cacheable=true)
    public static Scorecard getScorecard(Id resourceId) {
        Id srId = resourceId != null ? resourceId : resolveResourceId();
        if (srId == null) {
            return new Scorecard();
        }
        return scoreFor(aggregateMetrics(new Set<Id>{ srId }).get(srId));
    }

    /** A ranked leaderboard row. */
    public class LeaderboardEntry implements Comparable {
        @AuraEnabled public Integer rank;
        @AuraEnabled public Id resourceId;
        @AuraEnabled public String name;
        @AuraEnabled public String initials;
        @AuraEnabled public Decimal value = 0;
        @AuraEnabled public String valueLabel;
        @AuraEnabled public Boolean isMe = false;
        @AuraEnabled public Decimal gapToNext;
        @AuraEnabled public String gapLabel;

        public Integer compareTo(Object o) {
            Decimal a = value == null ? 0 : value;
            Decimal b = ((LeaderboardEntry) o).value == null ? 0 : ((LeaderboardEntry) o).value;
            if (a < b) { return 1; }   // descending
            if (a > b) { return -1; }
            return 0;
        }
    }

    /** A territory leaderboard for one metric. */
    public class Leaderboard {
        @AuraEnabled public String metric;
        @AuraEnabled public String territoryName;
        @AuraEnabled public Integer myRank;
        @AuraEnabled public List<LeaderboardEntry> entries = new List<LeaderboardEntry>();
    }

    /**
     * Territory leaderboard for the running technician.
     * @param metric score | collections | jobs | rating
     */
    @AuraEnabled(cacheable=true)
    public static Leaderboard getLeaderboard(String metric) {
        return buildLeaderboard(metric, resolveResourceId());
    }

    private static Leaderboard buildLeaderboard(String metric, Id myRid) {
        Leaderboard lb = new Leaderboard();
        lb.metric = metric;
        if (myRid == null) {
            return lb;
        }

        List<ServiceTerritoryMember> mine = [
            SELECT ServiceTerritoryId, ServiceTerritory.Name
            FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :myRid
            ORDER BY TerritoryType, EffectiveStartDate DESC NULLS LAST
            LIMIT 1
        ];
        if (mine.isEmpty()) {
            return lb;
        }
        Id territoryId = mine[0].ServiceTerritoryId;
        lb.territoryName = mine[0].ServiceTerritory.Name;

        Map<Id, String> nameById = new Map<Id, String>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId, ServiceResource.Name
            FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId = :territoryId
              AND ServiceResource.IsActive = true
            LIMIT 200
        ]) {
            nameById.put(stm.ServiceResourceId, stm.ServiceResource.Name);
        }
        if (!nameById.containsKey(myRid)) {
            nameById.put(myRid, 'You');
        }

        Map<Id, ResourceMetrics> metricsById = aggregateMetrics(nameById.keySet());

        List<LeaderboardEntry> ranked = new List<LeaderboardEntry>();
        for (Id rid : nameById.keySet()) {
            LeaderboardEntry e = new LeaderboardEntry();
            e.resourceId = rid;
            e.name = nameById.get(rid);
            e.initials = initialsOf(e.name);
            e.isMe = (rid == myRid);
            e.value = valueForMetric(metric, metricsById.get(rid));
            e.valueLabel = labelForMetric(metric, e.value);
            ranked.add(e);
        }
        ranked.sort();

        // Assign true ranks + gap-to-next across the full field.
        for (Integer i = 0; i < ranked.size(); i++) {
            LeaderboardEntry e = ranked[i];
            e.rank = i + 1;
            if (i > 0) {
                e.gapToNext = ranked[i - 1].value - e.value;
                e.gapLabel = gapLabelFor(metric, e.gapToNext);
            }
            if (e.isMe) { lb.myRank = e.rank; }
        }

        // Show the top N; always include the current user's row if outside it.
        Integer topN = 10;
        Boolean meIncluded = false;
        for (Integer i = 0; i < ranked.size() && i < topN; i++) {
            lb.entries.add(ranked[i]);
            if (ranked[i].isMe) { meIncluded = true; }
        }
        if (!meIncluded) {
            for (LeaderboardEntry e : ranked) {
                if (e.isMe) { lb.entries.add(e); break; }
            }
        }
        return lb;
    }

    private static Decimal valueForMetric(String metric, ResourceMetrics m) {
        if (m == null) { return 0; }
        if (metric == 'collections') { return m.collected == null ? 0 : m.collected; }
        if (metric == 'jobs') { return m.completed; }
        if (metric == 'rating') { return m.ratingCount > 0 ? (m.ratingSum / m.ratingCount).setScale(1) : 0; }
        return scoreFor(m).score;
    }

    private static String labelForMetric(String metric, Decimal v) {
        if (metric == 'collections') { return formatInr(v); }
        if (metric == 'jobs') { return String.valueOf((Integer) v) + ' jobs'; }
        if (metric == 'rating') { return v.setScale(1) + '★'; }
        return v.setScale(1) + ' pts';
    }

    private static String gapLabelFor(String metric, Decimal gap) {
        if (gap == null || gap <= 0) { return null; }
        if (metric == 'collections') { return formatInr(gap) + ' to move up 1 rank'; }
        if (metric == 'jobs') { return String.valueOf((Integer) Math.ceil(gap)) + ' jobs to move up'; }
        if (metric == 'rating') { return '+' + gap.setScale(1) + ' rating to move up'; }
        return String.valueOf((Integer) Math.ceil(gap)) + ' pts to move up 1 rank';
    }

    private static String formatInr(Decimal v) {
        if (v == null) { v = 0; }
        if (v >= 100000) { return '₹' + (v / 100000).setScale(1) + 'L'; }
        if (v >= 1000) { return '₹' + (Integer) (v / 1000) + 'K'; }
        return '₹' + (Integer) v;
    }

    private static String initialsOf(String name) {
        if (String.isBlank(name)) { return '?'; }
        List<String> parts = name.trim().split('\\s+');
        String s = parts[0].substring(0, 1);
        if (parts.size() > 1) { s += parts[parts.size() - 1].substring(0, 1); }
        return s.toUpperCase();
    }

    /**
     * Resolve the Account for the technician's current context: the account on
     * their most recent Service Appointment's parent (WorkOrder/Account/Asset).
     * Used to scope the browse screens (Orders, Contracts, …) "by current job".
     */
    @AuraEnabled(cacheable=true)
    public static Id getContextAccountId(Id resourceId) {
        Id srId = resourceId != null ? resourceId : resolveResourceId();
        if (srId == null) {
            return null;
        }
        for (AssignedResource ar : [
            SELECT ServiceAppointment.ParentRecordId
            FROM AssignedResource
            WHERE ServiceResourceId = :srId
              AND ServiceAppointment.ParentRecordId != null
            ORDER BY ServiceAppointment.SchedStartTime DESC NULLS LAST
            LIMIT 10
        ]) {
            Id parentId = ar.ServiceAppointment.ParentRecordId;
            String sobjType = String.valueOf(parentId.getSObjectType());
            if (sobjType == 'Account') {
                return parentId;
            }
            if (sobjType == 'WorkOrder') {
                for (WorkOrder wo : [SELECT AccountId FROM WorkOrder WHERE Id = :parentId AND AccountId != null LIMIT 1]) {
                    return wo.AccountId;
                }
            }
            if (sobjType == 'Asset') {
                for (Asset a : [SELECT AccountId FROM Asset WHERE Id = :parentId AND AccountId != null LIMIT 1]) {
                    return a.AccountId;
                }
            }
        }
        return null;
    }

    /** A single row for the generic browse panels (Orders, Products, …). */
    public class BrowseRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String objectApiName; // for tap-through; null = no nav
        @AuraEnabled public String primary;
        @AuraEnabled public String secondary;
        @AuraEnabled public Decimal amount;        // formatted client-side
    }

    /** Result wrapper for a browse panel: a heading plus its rows. */
    public class BrowseResult {
        @AuraEnabled public String title;
        @AuraEnabled public List<BrowseRow> rows = new List<BrowseRow>();
    }

    private static BrowseRow row(Id id, String obj, String primary, String secondary, Decimal amount) {
        BrowseRow r = new BrowseRow();
        r.id = id;
        r.objectApiName = obj;
        r.primary = primary;
        r.secondary = secondary;
        r.amount = amount;
        return r;
    }

    /**
     * Generic data source for the in-component browse panels. `mode` maps to a
     * tile: orders | products | rates | contracts | payments | amcpayments.
     * Account-scoped modes fall back to recent records so a panel is never empty.
     */
    @AuraEnabled(cacheable=true)
    public static BrowseResult getBrowseList(Id resourceId, String mode) {
        BrowseResult res = new BrowseResult();
        Id acctId = getContextAccountId(resourceId);
        String acctName;
        if (acctId != null) {
            for (Account a : [SELECT Name FROM Account WHERE Id = :acctId LIMIT 1]) {
                acctName = a.Name;
            }
        }

        if (mode == 'today') {
            res.title = 'Today\'s Schedule';
            Id srId = resourceId != null ? resourceId : resolveResourceId();
            if (srId != null) {
                for (ServiceAppointment sa : [
                    SELECT Subject, Status, AppointmentNumber, SchedStartTime
                    FROM ServiceAppointment
                    WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :srId)
                      AND SchedStartTime = TODAY
                    ORDER BY SchedStartTime ASC
                    LIMIT 50
                ]) {
                    String sub = sa.SchedStartTime != null
                        ? (sa.SchedStartTime.format('h:mm a') + ' · ' + sa.Status)
                        : sa.Status;
                    res.rows.add(row(sa.Id, 'ServiceAppointment',
                        sa.Subject != null ? sa.Subject : sa.AppointmentNumber, sub, null));
                }
            }
        } else if (mode == 'appointments') {
            res.title = 'My service appointments';
            Id srId = resourceId != null ? resourceId : resolveResourceId();
            if (srId != null) {
                for (ServiceAppointment sa : [
                    SELECT Subject, Status, AppointmentNumber, SchedStartTime
                    FROM ServiceAppointment
                    WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :srId)
                    ORDER BY SchedStartTime DESC NULLS LAST
                    LIMIT 50
                ]) {
                    String subtitle = sa.Status + (sa.SchedStartTime != null ? ' · ' + sa.SchedStartTime.format('d MMM, h:mm a') : '');
                    res.rows.add(row(sa.Id, 'ServiceAppointment',
                        sa.Subject != null ? sa.Subject : sa.AppointmentNumber, subtitle, null));
                }
            }
        } else if (mode == 'products') {
            res.title = 'Inventory';
            for (Product2 p : [
                SELECT Name, ProductCode FROM Product2 WHERE IsActive = true ORDER BY Name LIMIT 50
            ]) {
                res.rows.add(row(p.Id, 'Product2', p.Name, p.ProductCode, null));
            }
        } else if (mode == 'rates') {
            res.title = 'Price list';
            for (PricebookEntry pe : [
                SELECT Product2.Name, UnitPrice FROM PricebookEntry
                WHERE IsActive = true AND Pricebook2.IsStandard = true
                ORDER BY Product2.Name LIMIT 50
            ]) {
                res.rows.add(row(pe.Id, null, pe.Product2.Name, 'Unit price', pe.UnitPrice));
            }
        } else if (mode == 'contracts' || mode == 'amcpayments') {
            List<Contract> contracts = acctId != null ? [
                SELECT ContractNumber, Status, ContractTerm, StartDate FROM Contract
                WHERE AccountId = :acctId ORDER BY StartDate DESC NULLS LAST LIMIT 50
            ] : new List<Contract>();
            if (contracts.isEmpty()) {
                acctName = null;
                contracts = [
                    SELECT ContractNumber, Status, ContractTerm, StartDate FROM Contract
                    ORDER BY CreatedDate DESC LIMIT 50
                ];
            }
            res.title = mode == 'amcpayments' ? 'AMC payments' : ('AMC contracts' + (acctName != null ? ' · ' + acctName : ''));
            for (Contract c : contracts) {
                String term = c.ContractTerm != null ? (c.Status + ' · ' + c.ContractTerm + ' mo') : c.Status;
                res.rows.add(row(c.Id, 'Contract', c.ContractNumber, term, null));
            }
        } else if (mode == 'payments') {
            res.title = 'Payments collected';
            Id srId = resourceId != null ? resourceId : resolveResourceId();
            if (srId != null) {
                for (ServiceAppointment sa : [
                    SELECT Subject, AppointmentNumber, Amount_Collected__c
                    FROM ServiceAppointment
                    WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :srId)
                      AND Amount_Collected__c != null
                    ORDER BY SchedStartTime DESC NULLS LAST LIMIT 50
                ]) {
                    res.rows.add(row(sa.Id, 'ServiceAppointment', sa.Subject, sa.AppointmentNumber, sa.Amount_Collected__c));
                }
            }
        } else {
            // default: orders
            List<Order> orders = acctId != null ? [
                SELECT OrderNumber, Status, TotalAmount FROM Order
                WHERE AccountId = :acctId ORDER BY EffectiveDate DESC NULLS LAST, CreatedDate DESC LIMIT 50
            ] : new List<Order>();
            if (orders.isEmpty()) {
                acctName = null;
                orders = [SELECT OrderNumber, Status, TotalAmount FROM Order ORDER BY CreatedDate DESC LIMIT 50];
            }
            res.title = 'Orders' + (acctName != null ? ' · ' + acctName : ' · Recent');
            for (Order o : orders) {
                res.rows.add(row(o.Id, 'Order', o.OrderNumber, o.Status, o.TotalAmount));
            }
        }
        return res;
    }

    /** Resolve the running user's ServiceResource, if any. */
    private static Id resolveResourceId() {
        List<ServiceResource> resources = [
            SELECT Id FROM ServiceResource
            WHERE RelatedRecordId = :UserInfo.getUserId()
            LIMIT 1
        ];
        return resources.isEmpty() ? null : resources[0].Id;
    }
}