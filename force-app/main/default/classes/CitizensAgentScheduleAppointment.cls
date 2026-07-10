/**
 * Citizens Bank — Agentforce action: Schedule Appointment.
 *
 * Exposes appointment booking to the Citizens Bank voice / chat concierge.
 * Resolves the customer Account + primary Contact, then delegates the
 * Salesforce Scheduler booking and banker assignment to
 * CitizensSchedulerService.
 *
 * Wire this up as an action on the agent's topic in Agent Builder
 * (Setup -> Agentforce Studio) and add it to the voice channel to expose it
 * to the voice agent. Requires Salesforce Scheduler to be enabled.
 */
public with sharing class CitizensAgentScheduleAppointment {

    public class Request {
        @InvocableVariable(label='Topic' description='What the meeting is about, e.g. "Treasury management review" or "Commercial line of credit consultation".' required=true)
        public String topic;
        @InvocableVariable(label='Customer Account Name' description='Optional. Name (or partial name) of the customer Account the appointment is for.')
        public String customerAccountName;
        @InvocableVariable(label='Customer Account Id' description='Optional. Explicit customer Account Id. Takes precedence over the name.')
        public Id customerAccountId;
        @InvocableVariable(label='Preferred Date/Time' description='Optional. When the customer wants to meet. Defaults to the next business morning at 10:00.')
        public Datetime preferredDateTime;
        @InvocableVariable(label='Work Type' description='Optional Salesforce Scheduler work type name. Drives the appointment duration.')
        public String workTypeName;
        @InvocableVariable(label='Branch / Territory' description='Optional service territory (branch) name to book at. Defaults to the first active territory.')
        public String territoryName;
        @InvocableVariable(label='Preferred Banker' description='Optional. Name (or partial name) of a specific banker to request.')
        public String bankerName;
        @InvocableVariable(label='Required Skill' description='Optional Salesforce Scheduler skill the assigned banker must hold.')
        public String requiredSkillName;
        @InvocableVariable(label='Meeting Mode' description='"In a Center" (in branch) or "video". Defaults to In a Center.')
        public String meetingMode;
    }

    public class Response {
        @InvocableVariable(label='Summary Message') public String summary;
        @InvocableVariable(label='Scheduled') public Boolean scheduled;
        @InvocableVariable(label='Appointment Id') public Id appointmentId;
        @InvocableVariable(label='Appointment Number') public String appointmentNumber;
        @InvocableVariable(label='Assigned Banker') public String assignedBanker;
        @InvocableVariable(label='Branch') public String branch;
        @InvocableVariable(label='Scheduled Start') public Datetime scheduledStart;
        @InvocableVariable(label='Status') public String status;
    }

    @InvocableMethod(label='CB: Schedule Appointment'
        description='Book a Salesforce Scheduler appointment for the customer and assign an available, qualified banker.'
        category='Citizens Banking')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            Response r = new Response();

            Id accId = resolveAccountId(req.customerAccountId, req.customerAccountName);
            Id contactId = resolveContactId(accId);

            CitizensSchedulerService.ScheduleRequest sr = new CitizensSchedulerService.ScheduleRequest();
            sr.customerAccountId = accId;
            sr.contactId = contactId;
            sr.topic = req.topic;
            sr.workTypeName = req.workTypeName;
            sr.territoryName = req.territoryName;
            sr.bankerName = req.bankerName;
            sr.requiredSkillName = req.requiredSkillName;
            sr.meetingMode = req.meetingMode;
            sr.preferredStart = req.preferredDateTime;

            CitizensSchedulerService.ScheduleResult result = CitizensSchedulerService.book(sr);

            r.scheduled = result.scheduled;
            r.appointmentId = result.appointmentId;
            r.appointmentNumber = result.appointmentNumber;
            r.assignedBanker = result.resourceName;
            r.branch = result.territoryName;
            r.scheduledStart = result.scheduledStart;
            r.status = result.status;
            r.summary = result.message;
            out.add(r);
        }
        return out;
    }

    private static Id resolveAccountId(Id explicitId, String name) {
        if (explicitId != null) return explicitId;
        if (String.isBlank(name)) return null;
        List<Account> exact = [SELECT Id FROM Account WHERE Name = :name LIMIT 1];
        if (!exact.isEmpty()) return exact[0].Id;
        String like = '%' + name + '%';
        List<Account> fuzzy = [SELECT Id FROM Account WHERE Name LIKE :like ORDER BY Name LIMIT 1];
        return fuzzy.isEmpty() ? null : fuzzy[0].Id;
    }

    private static Id resolveContactId(Id accountId) {
        if (accountId == null) return null;
        List<Contact> c = [
            SELECT Id FROM Contact WHERE AccountId = :accountId ORDER BY CreatedDate ASC LIMIT 1
        ];
        return c.isEmpty() ? null : c[0].Id;
    }
}
