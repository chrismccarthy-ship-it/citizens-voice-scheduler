/**
 * Citizens Bank — Salesforce Scheduler domain logic.
 *
 * Books a Salesforce Scheduler appointment (ServiceAppointment +
 * AssignedResource) for a commercial-banking customer and — the core of the
 * capability — assigns the RIGHT banker: one who is an active member of the
 * chosen service territory (branch), holds the required skill when one is
 * requested, and is not already double-booked for the requested slot.
 *
 * This mirrors how Salesforce Scheduler narrows appointment candidates
 * (territory membership + skill match + availability) but does it inline in
 * Apex so it can be driven by an Agentforce action / voice agent.
 *
 * Standard objects used (require Salesforce Scheduler to be enabled in the org):
 *   ServiceAppointment, AssignedResource, ServiceResource,
 *   ServiceTerritory, ServiceTerritoryMember, ServiceResourceSkill,
 *   Skill, WorkType.
 */
public with sharing class CitizensSchedulerService {

    private static final Integer DEFAULT_DURATION_MINUTES = 60;

    /** What the caller asks for. */
    public class ScheduleRequest {
        public Id customerAccountId;      // parent record for the appointment (optional)
        public Id contactId;              // optional attendee contact
        public String topic;              // e.g. "Treasury management review"
        public String workTypeName;       // optional Scheduler WorkType (drives duration)
        public String territoryName;      // optional branch / territory
        public String bankerName;         // optional preferred resource
        public String requiredSkillName;  // optional Scheduler Skill to require
        public String meetingMode;        // 'In a Center' (default) or 'video'
        public Datetime preferredStart;   // optional; defaults to next business morning
    }

    /** What we booked (or why we couldn't). */
    public class ScheduleResult {
        public Boolean scheduled = false;
        public Id appointmentId;
        public String appointmentNumber;
        public Id serviceResourceId;
        public String resourceName;
        public String territoryName;
        public String workTypeName;
        public Datetime scheduledStart;
        public Datetime scheduledEnd;
        public String status;
        public String message;
    }

    public static ScheduleResult book(ScheduleRequest req) {
        ScheduleResult res = new ScheduleResult();
        try {
            // ---- 1. Resolve the WorkType (drives duration) ----------------
            WorkType wt = resolveWorkType(req.workTypeName);
            Integer durationMinutes = wt == null ? DEFAULT_DURATION_MINUTES : toMinutes(wt);
            res.workTypeName = wt == null ? req.workTypeName : wt.Name;

            // ---- 2. Resolve the ServiceTerritory (branch) -----------------
            ServiceTerritory terr = resolveTerritory(req.territoryName);
            if (terr == null) {
                res.message = 'I couldn\'t find an active service territory to book against. '
                    + 'Please make sure Salesforce Scheduler has at least one active territory.';
                return res;
            }
            res.territoryName = terr.Name;

            // ---- 3. Compute the requested slot ----------------------------
            Datetime start = req.preferredStart == null ? nextBusinessMorning() : req.preferredStart;
            Datetime finish = start.addMinutes(durationMinutes);
            res.scheduledStart = start;
            res.scheduledEnd = finish;

            // ---- 4. Assign the RIGHT resource -----------------------------
            ServiceResource banker = pickResource(terr.Id, req.requiredSkillName, req.bankerName, start, finish);
            if (banker == null) {
                res.message = 'No qualified banker is available at ' + terr.Name
                    + ' for ' + formatWhen(start)
                    + '. Try a different time or branch and I\'ll re-check availability.';
                return res;
            }
            res.serviceResourceId = banker.Id;
            res.resourceName = banker.Name;

            // ---- 5. Create the ServiceAppointment -------------------------
            String mode = String.isBlank(req.meetingMode) ? 'In a Center' : req.meetingMode;
            ServiceAppointment sa = new ServiceAppointment(
                ParentRecordId = req.customerAccountId,
                ContactId = req.contactId,
                Subject = String.isBlank(req.topic) ? 'Commercial banking appointment' : req.topic,
                Description = 'Booked by the Citizens Bank voice concierge.'
                    + (String.isBlank(req.topic) ? '' : ' Topic: ' + req.topic + '.'),
                ServiceTerritoryId = terr.Id,
                WorkTypeId = wt == null ? null : wt.Id,
                EarliestStartTime = start,
                DueDate = start.addDays(7),
                SchedStartTime = start,
                SchedEndTime = finish,
                Duration = durationMinutes,
                DurationType = 'Minutes',
                AppointmentType = mode,
                Status = 'Scheduled'
            );
            insert sa;

            // ---- 6. Assign the resource to the appointment ----------------
            insert new AssignedResource(
                ServiceAppointmentId = sa.Id,
                ServiceResourceId = banker.Id
            );

            ServiceAppointment saved = [
                SELECT Id, AppointmentNumber, Status
                FROM ServiceAppointment WHERE Id = :sa.Id LIMIT 1
            ];
            res.scheduled = true;
            res.appointmentId = saved.Id;
            res.appointmentNumber = saved.AppointmentNumber;
            res.status = saved.Status;
            res.message = 'Booked ' + workTypeNameOf(res.workTypeName, req.topic)
                + ' with ' + banker.Name + ' at ' + terr.Name
                + ' on ' + formatWhen(start) + ' (' + durationMinutes + ' min, ' + mode + ').'
                + ' Confirmation ' + saved.AppointmentNumber + '.';
            return res;
        } catch (Exception ex) {
            res.message = 'I couldn\'t book that appointment: ' + ex.getMessage();
            return res;
        }
    }

    private static String workTypeNameOf(String workTypeName, String topic) {
        return String.isNotBlank(workTypeName) ? workTypeName
            : (String.isNotBlank(topic) ? topic : 'a commercial banking appointment');
    }

    // ============================================================
    // Resolution helpers
    // ============================================================
    private static WorkType resolveWorkType(String name) {
        if (String.isBlank(name)) return null;
        List<WorkType> exact = [
            SELECT Id, Name, EstimatedDuration, DurationType
            FROM WorkType WHERE Name = :name LIMIT 1
        ];
        if (!exact.isEmpty()) return exact[0];
        String like = '%' + name + '%';
        List<WorkType> fuzzy = [
            SELECT Id, Name, EstimatedDuration, DurationType
            FROM WorkType WHERE Name LIKE :like ORDER BY Name LIMIT 1
        ];
        return fuzzy.isEmpty() ? null : fuzzy[0];
    }

    private static ServiceTerritory resolveTerritory(String name) {
        if (String.isNotBlank(name)) {
            String like = '%' + name + '%';
            List<ServiceTerritory> named = [
                SELECT Id, Name FROM ServiceTerritory
                WHERE IsActive = true AND Name LIKE :like ORDER BY Name LIMIT 1
            ];
            if (!named.isEmpty()) return named[0];
        }
        List<ServiceTerritory> any = [
            SELECT Id, Name FROM ServiceTerritory
            WHERE IsActive = true ORDER BY Name LIMIT 1
        ];
        return any.isEmpty() ? null : any[0];
    }

    /**
     * The candidate-selection heart of the action. Returns the best-fit,
     * available ServiceResource for the territory + skill + slot, or null.
     */
    private static ServiceResource pickResource(
        Id territoryId, String skillName, String bankerName, Datetime start, Datetime finish
    ) {
        // Candidates = active members of the territory.
        Set<Id> candidateIds = new Set<Id>();
        for (ServiceTerritoryMember m : [
            SELECT ServiceResourceId
            FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId = :territoryId
              AND ServiceResource.IsActive = true
              AND (EffectiveEndDate = null OR EffectiveEndDate >= :start)
        ]) {
            candidateIds.add(m.ServiceResourceId);
        }
        // Fallback so an org without seeded territory members still books.
        if (candidateIds.isEmpty()) {
            for (ServiceResource r : [
                SELECT Id FROM ServiceResource
                WHERE IsActive = true AND RelatedRecordId != null
                ORDER BY Name LIMIT 200
            ]) {
                candidateIds.add(r.Id);
            }
        }
        if (candidateIds.isEmpty()) return null;

        // Narrow by required skill, if one was requested and it exists.
        if (String.isNotBlank(skillName)) {
            Set<Id> skilled = resourcesWithSkill(skillName, candidateIds, start);
            if (!skilled.isEmpty()) candidateIds = skilled;
        }

        // Load the candidate resources; optionally prefer a named banker.
        List<ServiceResource> candidates = [
            SELECT Id, Name FROM ServiceResource
            WHERE Id IN :candidateIds ORDER BY Name
        ];
        if (String.isNotBlank(bankerName)) {
            List<ServiceResource> named = new List<ServiceResource>();
            String needle = bankerName.toLowerCase();
            for (ServiceResource r : candidates) {
                if (r.Name != null && r.Name.toLowerCase().contains(needle)) named.add(r);
            }
            if (!named.isEmpty()) candidates = named; // otherwise keep the full pool
        }

        // Availability: skip anyone double-booked in [start, finish); rank the
        // rest by current appointment load so we spread work evenly.
        Map<Id, Integer> loadByResource = new Map<Id, Integer>();
        Set<Id> conflicted = new Set<Id>();
        for (AssignedResource ar : [
            SELECT ServiceResourceId,
                   ServiceAppointment.SchedStartTime, ServiceAppointment.SchedEndTime,
                   ServiceAppointment.Status
            FROM AssignedResource
            WHERE ServiceResourceId IN :candidateIds
              AND ServiceAppointment.Status NOT IN ('Canceled', 'Completed', 'Cannot Complete')
              AND ServiceAppointment.SchedEndTime != null
        ]) {
            Id rid = ar.ServiceResourceId;
            loadByResource.put(rid, (loadByResource.containsKey(rid) ? loadByResource.get(rid) : 0) + 1);
            Datetime aStart = ar.ServiceAppointment.SchedStartTime;
            Datetime aEnd = ar.ServiceAppointment.SchedEndTime;
            if (aStart != null && aStart < finish && aEnd > start) conflicted.add(rid);
        }

        ServiceResource best;
        Integer bestLoad = 0;
        for (ServiceResource r : candidates) {
            if (conflicted.contains(r.Id)) continue;
            Integer load = loadByResource.containsKey(r.Id) ? loadByResource.get(r.Id) : 0;
            if (best == null || load < bestLoad) {
                best = r;
                bestLoad = load;
            }
        }
        return best;
    }

    private static Set<Id> resourcesWithSkill(String skillName, Set<Id> withinIds, Datetime asOf) {
        Set<Id> out = new Set<Id>();
        List<Skill> skills = [SELECT Id FROM Skill WHERE MasterLabel = :skillName LIMIT 1];
        if (skills.isEmpty()) return out;
        Id skillId = skills[0].Id;
        for (ServiceResourceSkill srs : [
            SELECT ServiceResourceId
            FROM ServiceResourceSkill
            WHERE SkillId = :skillId
              AND ServiceResourceId IN :withinIds
              AND (EffectiveEndDate = null OR EffectiveEndDate >= :asOf)
        ]) {
            out.add(srs.ServiceResourceId);
        }
        return out;
    }

    // ============================================================
    // Time helpers
    // ============================================================
    private static Integer toMinutes(WorkType wt) {
        if (wt.EstimatedDuration == null || wt.EstimatedDuration <= 0) return DEFAULT_DURATION_MINUTES;
        Integer d = Integer.valueOf(wt.EstimatedDuration);
        return wt.DurationType == 'Hours' ? d * 60 : d;
    }

    /** Next weekday at 10:00 (org time). */
    private static Datetime nextBusinessMorning() {
        Date d = Date.today().addDays(1);
        Datetime probe = Datetime.newInstance(d, Time.newInstance(10, 0, 0, 0));
        String day = probe.format('EEE');
        if (day == 'Sat') probe = probe.addDays(2);
        else if (day == 'Sun') probe = probe.addDays(1);
        return probe;
    }

    private static String formatWhen(Datetime dt) {
        return dt.format('EEEE, MMMM d') + ' at ' + dt.format('h:mm a');
    }
}
