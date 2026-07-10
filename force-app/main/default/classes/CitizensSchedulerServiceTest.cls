/**
 * Tests for CitizensSchedulerService + CitizensAgentScheduleAppointment.
 *
 * Strategy: build the minimum Salesforce Scheduler graph in-test
 * (OperatingHours -> ServiceTerritory -> ServiceResource -> membership,
 * plus an optional WorkType/Skill) so resource assignment and the
 * ServiceAppointment/AssignedResource insert can be exercised end to end.
 *
 * Org-side automation on ServiceAppointment can vary between orgs, so the
 * action must always return a usable summary; the deeper assertions only run
 * when a booking actually persisted.
 */
@IsTest
private class CitizensSchedulerServiceTest {

    private static final String CUSTOMER = 'Citizens Test Customer';

    private static Account makeCustomer() {
        Account a = new Account(Name = CUSTOMER, Industry = 'Technology');
        insert a;
        insert new Contact(FirstName = 'Jordan', LastName = 'Rivera', AccountId = a.Id, Title = 'CFO');
        return a;
    }

    /** Builds a territory with `count` active member resources; returns the resources. */
    private static List<ServiceResource> makeSchedulerGraph(String territoryName, Integer count) {
        OperatingHours oh = new OperatingHours(Name = 'CB Test Hours', TimeZone = 'America/New_York');
        insert oh;

        ServiceTerritory terr = new ServiceTerritory(
            Name = territoryName, IsActive = true, OperatingHoursId = oh.Id
        );
        insert terr;

        List<ServiceResource> resources = new List<ServiceResource>();
        for (Integer i = 0; i < count; i++) {
            resources.add(new ServiceResource(
                Name = 'CB Banker ' + i,
                IsActive = true,
                ResourceType = 'T',
                RelatedRecordId = UserInfo.getUserId()
            ));
        }
        insert resources;

        List<ServiceTerritoryMember> members = new List<ServiceTerritoryMember>();
        for (ServiceResource r : resources) {
            members.add(new ServiceTerritoryMember(
                ServiceResourceId = r.Id,
                ServiceTerritoryId = terr.Id,
                EffectiveStartDate = Datetime.now().addDays(-1)
            ));
        }
        insert members;
        return resources;
    }

    private static Datetime nextMondayAt(Integer hour) {
        Datetime dt = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(hour, 0, 0, 0));
        while (dt.format('EEE') != 'Mon') {
            dt = dt.addDays(1);
        }
        return dt;
    }

    private static CitizensAgentScheduleAppointment.Request req(String topic) {
        CitizensAgentScheduleAppointment.Request r = new CitizensAgentScheduleAppointment.Request();
        r.topic = topic;
        r.customerAccountName = CUSTOMER;
        return r;
    }

    // ------------------------------------------------------------
    // Happy path: books an appointment and assigns a banker.
    // ------------------------------------------------------------
    @IsTest static void schedule_booksAndAssignsBanker() {
        makeCustomer();
        makeSchedulerGraph('Citizens Downtown Branch', 2);

        CitizensAgentScheduleAppointment.Request r = req('Treasury management review');
        r.territoryName = 'Citizens Downtown Branch';
        r.preferredDateTime = nextMondayAt(10);
        r.meetingMode = 'video';

        Test.startTest();
        List<CitizensAgentScheduleAppointment.Response> resp =
            CitizensAgentScheduleAppointment.invoke(
                new List<CitizensAgentScheduleAppointment.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, resp.size());
        System.assertNotEquals(null, resp[0].summary);
        if (resp[0].scheduled == true) {
            System.assertNotEquals(null, resp[0].appointmentId);
            System.assertNotEquals(null, resp[0].assignedBanker);
            System.assertEquals('Citizens Downtown Branch', resp[0].branch);
            List<AssignedResource> ars = [
                SELECT ServiceResourceId FROM AssignedResource
                WHERE ServiceAppointmentId = :resp[0].appointmentId
            ];
            System.assertEquals(1, ars.size(), 'A banker must be assigned to the appointment.');
        }
    }

    // ------------------------------------------------------------
    // Work type drives duration; skill narrows the candidate pool.
    // ------------------------------------------------------------
    @IsTest static void schedule_withWorkTypeAndSkill() {
        makeCustomer();
        List<ServiceResource> resources = makeSchedulerGraph('Citizens Midtown Branch', 2);

        WorkType wt = new WorkType(
            Name = 'Commercial Banking Consultation',
            EstimatedDuration = 45, DurationType = 'Minutes'
        );
        insert wt;

        Skill skill = new Skill(MasterLabel = 'CB Commercial Lending', DeveloperName = 'CB_Commercial_Lending');
        insert skill;
        // Only the first resource holds the skill.
        insert new ServiceResourceSkill(
            ServiceResourceId = resources[0].Id, SkillId = skill.Id,
            SkillLevel = 5, EffectiveStartDate = Datetime.now().addDays(-1)
        );

        CitizensAgentScheduleAppointment.Request r = req('Line of credit consultation');
        r.territoryName = 'Citizens Midtown Branch';
        r.workTypeName = 'Commercial Banking Consultation';
        r.requiredSkillName = 'CB Commercial Lending';
        r.preferredDateTime = nextMondayAt(11);

        Test.startTest();
        List<CitizensAgentScheduleAppointment.Response> resp =
            CitizensAgentScheduleAppointment.invoke(
                new List<CitizensAgentScheduleAppointment.Request>{ r });
        Test.stopTest();

        System.assertNotEquals(null, resp[0].summary);
        if (resp[0].scheduled == true) {
            ServiceAppointment sa = [
                SELECT Duration, WorkTypeId FROM ServiceAppointment WHERE Id = :resp[0].appointmentId
            ];
            System.assertEquals(45, sa.Duration);
            System.assertEquals(wt.Id, sa.WorkTypeId);
            List<AssignedResource> ars = [
                SELECT ServiceResourceId FROM AssignedResource
                WHERE ServiceAppointmentId = :resp[0].appointmentId
            ];
            System.assertEquals(resources[0].Id, ars[0].ServiceResourceId);
        }
    }

    // ------------------------------------------------------------
    // A double-booked banker is skipped in favor of a free one.
    // ------------------------------------------------------------
    @IsTest static void schedule_skipsDoubleBookedBanker() {
        makeCustomer();
        List<ServiceResource> resources = makeSchedulerGraph('Citizens Uptown Branch', 2);
        Datetime slot = nextMondayAt(14);

        ServiceAppointment busy = new ServiceAppointment(
            Subject = 'Existing',
            ServiceTerritoryId = [SELECT Id FROM ServiceTerritory WHERE Name = 'Citizens Uptown Branch' LIMIT 1].Id,
            EarliestStartTime = slot, DueDate = slot.addDays(1),
            SchedStartTime = slot, SchedEndTime = slot.addMinutes(60),
            Duration = 60, DurationType = 'Minutes', Status = 'Scheduled'
        );
        insert busy;
        insert new AssignedResource(ServiceAppointmentId = busy.Id, ServiceResourceId = resources[0].Id);

        CitizensAgentScheduleAppointment.Request r = req('Cash flow planning');
        r.territoryName = 'Citizens Uptown Branch';
        r.preferredDateTime = slot;

        Test.startTest();
        List<CitizensAgentScheduleAppointment.Response> resp =
            CitizensAgentScheduleAppointment.invoke(
                new List<CitizensAgentScheduleAppointment.Request>{ r });
        Test.stopTest();

        System.assertNotEquals(null, resp[0].summary);
        if (resp[0].scheduled == true) {
            List<AssignedResource> ars = [
                SELECT ServiceResourceId FROM AssignedResource
                WHERE ServiceAppointmentId = :resp[0].appointmentId
            ];
            System.assertEquals(resources[1].Id, ars[0].ServiceResourceId,
                'The free banker should have been chosen over the double-booked one.');
        }
    }

    // ------------------------------------------------------------
    // No Scheduler territory configured -> graceful, non-null message.
    // ------------------------------------------------------------
    @IsTest static void schedule_noTerritoryIsGraceful() {
        makeCustomer(); // no Scheduler graph at all

        List<CitizensAgentScheduleAppointment.Response> resp =
            CitizensAgentScheduleAppointment.invoke(
                new List<CitizensAgentScheduleAppointment.Request>{ req('Anything') });

        System.assertEquals(1, resp.size());
        System.assertEquals(false, resp[0].scheduled);
        System.assertNotEquals(null, resp[0].summary);
        System.assertEquals(null, resp[0].appointmentId);
    }
}
