# Citizens Voice Scheduler

A self-contained Salesforce package that lets a **Citizens Bank Agentforce voice (or chat) agent** book a commercial-banking appointment through **Salesforce Scheduler** — and assign the *right* banker automatically.

## What it does

The agent action **`CB: Schedule Appointment`** takes a topic (and optionally a preferred time, branch, work type, required skill, or named banker) and:

1. Resolves the **work type** (which drives the appointment duration) and the **service territory** (the branch).
2. Builds the candidate pool from **active service resources that are members of that territory**, then narrows it to those holding the **required skill** when one is requested (and to a named banker when one is asked for).
3. Checks **availability** — skips any banker already booked over the requested slot — and load-balances across the rest.
4. Inserts the `ServiceAppointment` (parented to the customer Account, with the contact, territory, work type, and scheduled times) and an `AssignedResource` linking the chosen banker.

It returns a confirmation like:

> *"Booked a Treasury management review with Deanna Marsh at Citizens Downtown Branch on Tuesday, July 14 at 10:00 AM (60 min, In a Center). Confirmation SA-0791."*

If no qualified banker is free it says so and invites the customer to pick another time or branch — it never double-books.

## Components

| Metadata | Purpose |
|---|---|
| `CitizensSchedulerService` | Salesforce Scheduler domain logic — work type / territory resolution, banker candidate selection, availability check, and the `ServiceAppointment` + `AssignedResource` insert. |
| `CitizensAgentScheduleAppointment` | The Agentforce invocable action (`@InvocableMethod`, label *"CB: Schedule Appointment"*). Resolves the customer Account + Contact and delegates to the service. |
| `CitizensSchedulerServiceTest` | Tests: happy path, work-type/skill narrowing, double-booking skip, and the no-territory graceful path. |
| `Citizens_Voice_Scheduler_User` | Permission set granting access to the two Apex classes. |

## The action's inputs

| Input | Required | Notes |
|---|---|---|
| Topic | ✅ | What the meeting is about; used as the appointment subject. |
| Customer Account Name / Id | | Identifies the customer the appointment is booked for. Id wins over name. |
| Preferred Date/Time | | Defaults to the next business morning at 10:00. |
| Work Type | | Salesforce Scheduler work type; drives duration (defaults to 60 min). |
| Branch / Territory | | Defaults to the first active territory. |
| Preferred Banker | | Partial name match; ignored if that banker isn't a valid candidate. |
| Required Skill | | Narrows candidates to resources holding that Scheduler skill. |
| Meeting Mode | | `In a Center` (default) or `video`. |

## Prerequisites

- **Salesforce Scheduler must be enabled.** The Apex references the `ServiceAppointment`, `ServiceResource`, `ServiceTerritory`, `ServiceTerritoryMember`, `ServiceResourceSkill`, and `WorkType` standard objects and will not compile in an org without Scheduler.
- Scheduler data should exist: at least one active `ServiceTerritory`, active `ServiceResource` records, and (ideally) `ServiceTerritoryMember` rows linking bankers to branches. Without territory members the action falls back to any active resource so bookings still succeed.

## Deploy

```bash
# Authorize your Scheduler-enabled org first (sf org login web ...)
sf project deploy start --source-dir force-app --target-org <alias> --wait 20
sf org assign permset --name Citizens_Voice_Scheduler_User --target-org <alias>
```

## Run tests

```bash
sf apex run test --target-org <alias> --class-names CitizensSchedulerServiceTest \
  --result-format human --code-coverage --wait 10
```

The tests build their own in-org Scheduler graph (operating hours → territory → resources → membership), so they don't depend on pre-seeded data.

## Wire it into the agent

The Apex ships here, but the action still has to be **added to the agent's topic in Agent Builder** (Setup → Agentforce Studio → Agents), where it surfaces as *"CB: Schedule Appointment."* Add the same action to the agent's **voice channel** to expose it to the voice agent.
