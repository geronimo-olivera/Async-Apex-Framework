# Usage

## What this is for

`BatchApexHandler` and `QueueableApexHandler` are abstract base classes. You extend one, implement the one or two methods that actually do your work, and launch it through the framework's own `run()` static method instead of `Database.executeBatch`/`System.enqueueJob` directly — that's what makes the `Async_Job_Configuration__mdt` record (if one exists for your class) actually get applied.

Both handlers share the same configuration shape (active flag, retry count, failure email) through `AsyncJobHandlerBase` and `AsyncJobHandlerHelper`, but their retry and completion logic is deliberately **not** shared — see [Why Batch and Queueable retry differently](#why-batch-and-queueable-retry-differently) below before you assume one behaves like the other.

## Configuring a job

An `Async_Job_Configuration__mdt` record is entirely optional. With no record, a class runs active, with no retry and no batch-size override. Create one either way CMDT records normally get created:

- **Setup UI** — Setup → Custom Metadata Types → **Async Job Configuration** → Manage Records → New.
- **Source** — add a `.md-meta.xml` file under `force-app/main/default/customMetadata/` and deploy it. For example, `Async_Job_Configuration__mdt.Close_Stale_Opportunities_Batch.md-meta.xml`:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <CustomMetadata xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://soap.sforce.com/2006/04/metadata">
      <label>Close Stale Opportunities Batch</label>
      <protected>false</protected>
      <values><field>Class_Name__c</field><value xsi:type="xsd:string">CloseStaleOpportunitiesBatch</value></values>
      <values><field>Job_Type__c</field><value xsi:type="xsd:string">Batch</value></values>
      <values><field>Is_Active__c</field><value xsi:type="xsd:boolean">true</value></values>
      <values><field>Batch_Size__c</field><value xsi:type="xsd:double">100</value></values>
      <values><field>Max_Retry_Attempts__c</field><value xsi:type="xsd:double">2</value></values>
      <values><field>Retry_Delay_Minutes__c</field><value xsi:type="xsd:double">5</value></values>
      <values><field>Send_Email_On_Failure__c</field><value xsi:type="xsd:boolean">true</value></values>
      <values><field>Notification_Emails__c</field><value xsi:type="xsd:string">ops@example.com; oncall@example.com</value></values>
      <values><field>Org_Wide_Email_Address_Id__c</field><value xsi:type="xsd:string">0D8XXXXXXXXXXXXXXX</value></values>
  </CustomMetadata>
  ```

`Class_Name__c` is unique — you can't create two configuration records for the same class, so there's no ambiguity about which one applies. It's matched without regard to case. If your class overrides `toString()`, also override `getJobName()` to return the name to match, since the class name is detected from Apex's default `toString()`.

`Retry_Delay_Minutes__c` (0 to 10) waits that many minutes before each retry, instead of retrying at once. Use it when failures come from an external system that's down or rate-limiting you: an immediate retry usually fails the same way.

The configuration is read with `Async_Job_Configuration__mdt.getAll()`, not SOQL, so it costs no query and works for every user, including code that runs as a standard user in user mode.

**Finding an Organization-Wide Email Address Id**: Setup → Organization-Wide Addresses → click the address you want to send from → the Id (starts with `0D8`) is in the browser's URL. There has to be at least one verified address configured here before you can reference it — this repo doesn't create one for you, since it depends on a real, org-owned email address being verified through an email Salesforce sends to it.

## Writing a Batch job — easy example

Extend `BatchApexHandler` and implement `getQueryLocator()` (what you'd normally write in `start()`) and `executeScope()` (what you'd normally write in `execute()`):

```apex
public class CloseStaleOpportunitiesBatch extends BatchApexHandler {

    protected override Database.QueryLocator getQueryLocator() {
        return Database.getQueryLocator([
            SELECT Id, StageName
            FROM Opportunity
            WHERE IsClosed = false AND LastActivityDate < LAST_N_DAYS:90
        ]);
    }

    protected override void executeScope(List<SObject> scope) {
        List<Opportunity> staleOpportunities = (List<Opportunity>) scope;
        for (Opportunity opp : staleOpportunities) {
            opp.StageName = 'Closed Lost';
        }
        update staleOpportunities;
    }
}
```

Launch it with:

```apex
BatchApexHandler.run(new CloseStaleOpportunitiesBatch());
```

If `Async_Job_Configuration__mdt` has no record for `CloseStaleOpportunitiesBatch`, this runs with batch size 200, no retry, and no failure email — `getQueryLocator()`/`executeScope()` are all you had to write.

## Writing a Batch job — advanced example

This one takes a constructor argument, builds its query dynamically (a plain SOQL literal doesn't let you optionally add a `WHERE` clause), makes a callout (which needs `Database.AllowsCallouts` added to your own subclass — the base class doesn't declare it, since not every job needs it), and chains a second batch from `onFinish()` once it completes cleanly:

```apex
public class SyncAccountsToExternalSystemBatch extends BatchApexHandler implements Database.AllowsCallouts {

    private String industryFilter;

    public SyncAccountsToExternalSystemBatch(String industryFilter) {
        this.industryFilter = industryFilter;
    }

    protected override Database.QueryLocator getQueryLocator() {
        String query = 'SELECT Id, Name, Website FROM Account';
        if (String.isNotBlank(industryFilter)) {
            query += ' WHERE Industry = :industryFilter';
        }
        return Database.getQueryLocator(query);
    }

    protected override void executeScope(List<SObject> scope) {
        for (Account acc : (List<Account>) scope) {
            HttpRequest request = new HttpRequest();
            request.setEndpoint('callout:External_CRM/accounts/' + acc.Id);
            request.setMethod('POST');
            request.setBody(JSON.serialize(new Map<String, Object>{ 'name' => acc.Name, 'website' => acc.Website }));
            HttpResponse response = new Http().send(request);
            if (response.getStatusCode() >= 300) {
                throw new CalloutException('Sync failed for ' + acc.Id + ': ' + response.getStatus());
            }
        }
    }

    protected override void onFinish(Boolean hadErrors) {
        if (!hadErrors) {
            BatchApexHandler.run(new CreateFollowUpTasksBatch(industryFilter));
        }
    }
}
```

A dynamic SOQL string can still reference a local variable with `:variableName` the same way an inline query would — Salesforce resolves it from the enclosing scope at call time, so this isn't string concatenation and isn't a SOQL injection risk the way building the literal value into the string would be.

## Writing a Queueable job — easy example

Extend `QueueableApexHandler` and implement `executeJob()` — there's no scope/chunking concept here, unlike Batch, so get whatever data you need from your own constructor:

```apex
public class EscalateCasesQueueable extends QueueableApexHandler {

    private List<Id> caseIds;

    public EscalateCasesQueueable(List<Id> caseIds) {
        this.caseIds = caseIds;
    }

    protected override void executeJob() {
        List<Case> cases = [SELECT Id, Status FROM Case WHERE Id IN :caseIds];
        for (Case c : cases) {
            c.Status = 'Escalated';
        }
        update cases;
    }
}
```

Launch it with:

```apex
QueueableApexHandler.run(new EscalateCasesQueueable(caseIds));
```

## Writing a Queueable job — advanced example

Two things Queueable jobs commonly need that Batch doesn't: a callout, and manual self-chaining for **continuation** (processing another page of records) rather than **retry** (redoing a failure) — these are different concepts and the framework only automates the second one.

Callout:

```apex
public class SlackNotificationQueueable extends QueueableApexHandler implements Database.AllowsCallouts {

    private String message;

    public SlackNotificationQueueable(String message) {
        this.message = message;
    }

    protected override void executeJob() {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:Slack_Webhook');
        request.setMethod('POST');
        request.setBody(JSON.serialize(new Map<String, Object>{ 'text' => message }));
        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() >= 300) {
            throw new CalloutException('Slack notification failed: ' + response.getStatus());
        }
    }
}
```

Manual chaining for pagination, driven from `onFinish()` instead of the framework's built-in retry:

```apex
public class NormalizeContactEmailsQueueable extends QueueableApexHandler {

    private static final Integer PAGE_SIZE = 200;

    private Id lastProcessedId;
    private Boolean morePagesRemain = true;

    public NormalizeContactEmailsQueueable() {
        this(null);
    }

    public NormalizeContactEmailsQueueable(Id lastProcessedId) {
        this.lastProcessedId = lastProcessedId;
    }

    protected override void executeJob() {
        String query = 'SELECT Id, Email FROM Contact';
        if (lastProcessedId != null) {
            query += ' WHERE Id > :lastProcessedId';
        }
        query += ' ORDER BY Id LIMIT :PAGE_SIZE';
        List<Contact> page = Database.query(query);

        for (Contact c : page) {
            if (c.Email != null) {
                c.Email = c.Email.toLowerCase();
            }
        }
        update page;

        morePagesRemain = page.size() == PAGE_SIZE;
        if (!page.isEmpty()) {
            lastProcessedId = page[page.size() - 1].Id;
        }
    }

    protected override void onFinish(Boolean hadErrors) {
        if (!hadErrors && morePagesRemain) {
            QueueableApexHandler.run(new NormalizeContactEmailsQueueable(lastProcessedId));
        }
    }
}
```

Watch the first page carefully: `WHERE Id > :lastProcessedId` is only added once `lastProcessedId` is non-null. Comparing a field to a bind variable that's `null` doesn't mean "match everything" in SOQL — it matches zero rows, since `Id > null` isn't true for any record. Track "is there more to do" with your own boolean (`morePagesRemain` here) instead of overloading `null` to mean two different things.

## Retry behavior and idempotency

Both handlers can automatically retry a failed job, capped at 10 attempts regardless of what `Max_Retry_Attempts__c` says, optionally waiting `Retry_Delay_Minutes__c` before each one.

- **Batch**: a retry calls `getQueryLocator()` again from scratch and reprocesses **every** matching record — including the ones that already succeeded on the failed attempt. The retry check is at the whole-job level (`AsyncApexJob.NumberOfErrors > 0`), not per chunk. A failed chunk is rolled back on its own; the chunks that succeeded keep their changes.
- **Queueable**: a failed attempt is rolled back completely, so a retry never starts from half-saved data. It re-runs `executeJob()` from scratch with the same constructor state.

What isn't rolled back: callouts to other systems, emails already sent, and, in a Batch, the chunks that succeeded. So write your job logic so it's safe to run again on records it already touched:

- Prefer `upsert` keyed by an external Id over `insert`, so a repeat run updates instead of duplicating.
- Check a status field before acting (`if (record.Status__c != 'Synced') { ... }`) so an already-processed record is a no-op the second time.
- For callouts to a system you don't control, use an idempotency key if the API supports one, or make the callout itself a query-then-act pattern instead of a blind POST.

## Why Batch and Queueable handle failures differently

`BatchApexHandler.execute()` catches the subclass's exception, logs it, and **re-throws** it. That's deliberate — `AsyncApexJob.NumberOfErrors` (what `finish()` checks to decide whether to retry) only increments when an exception actually escapes `execute()`. Swallowing it there would silently disable retry. Governor limit errors in a chunk count the same way.

`QueueableApexHandler` uses a **Transaction Finalizer**. `execute()` attaches it and runs your `executeJob()` without catching anything. Salesforce runs the finalizer in its own transaction after the job ends, however it ended, and the finalizer calls `onFinish`, enqueues the retry, or sends the failure email. This replaced an earlier design that caught the exception inside `execute()`, and fixes three problems it had, all confirmed by running jobs in a real org:

1. **Half-done work was kept.** Catching the exception meant the job's DML before the failure was committed. Now the failed attempt is rolled back.
2. **Governor limit errors were lost.** No catch block can handle "Too many SOQL queries" or CPU time limits, so those jobs failed with no retry, no email and no `onFinish`. The finalizer runs for them too.
3. **Failed jobs showed as Completed.** Now they show as Failed in Setup → Apex Jobs, with the error message.

The earlier design existed because a retry enqueued in the failing transaction is rolled back with it. The finalizer enqueues the retry from its own transaction, so that's no longer a problem.

## Limits checked for you

- `QueueableApexHandler.run()` throws `AsyncJobHandlerBase.AsyncJobException` with a clear message if the transaction already enqueued as many jobs as Salesforce allows. The usual cause is starting one job per record from a trigger: pass all the records to one job instead.
- `BatchApexHandler.run()` throws the same exception, wrapping Salesforce's own error, if the flex queue already holds 100 batch jobs.

## Failure emails

Check `Send_Email_On_Failure__c`, set one or more semicolon-separated addresses in `Notification_Emails__c` (`first@x.com; second@x.com`), and set `Org_Wide_Email_Address_Id__c` to a verified Organization-Wide Email Address Id — validation rules require both of those fields whenever the checkbox is set. The email fires once, after the job (following any configured retries) still has errors. It says which user the job ran as.

**`Org_Wide_Email_Address_Id__c` is not optional in practice, even though the field itself allows blank.** `AsyncJobHandlerHelper.sendFailureEmail` only calls `setOrgWideEmailAddressId` when it's populated — leave it blank and the email falls back to sending as the running user. In a Batch or Queueable context that running user is often an automated/integration identity without a confirmed, deliverable email address, and `Messaging.sendEmail` can throw `INVALID_SENDER` in that case. The validation rule exists specifically to stop you from configuring a failure notification that looks correct but silently never arrives.

A malformed address (in either `Notification_Emails__c` or an invalid `Org_Wide_Email_Address_Id__c`) doesn't block your job from running and doesn't throw — `AsyncJobHandlerHelper.sendFailureEmail` catches that internally and only logs it (`System.debug(LoggingLevel.ERROR, 'Failed to send failure notification for ...')`), on purpose, so a typo can never take down the actual record processing. The tradeoff is that nothing else tells you the notification silently failed — if you suspect a configured email isn't arriving, check debug logs for that exact line before assuming the job itself is fine.

## Permissions

Any user can start a job: reading the configuration needs no permission, and a job's queries and DML run in system mode unless your subclass is declared `with sharing`. Jobs run as the user who started them, so a job started from a trigger runs as whoever saved the record. That's checked end to end with a standard user starting both a Queueable and a Batch by saving a record.

What can depend on that user:

- **Failure emails** — the Organization-Wide Email Address must allow that user's profile. In Setup → Organization-Wide Addresses, choose "Allow All Profiles to Use this From Address", or add the profiles that start jobs. Otherwise the email fails, and since that's only logged, nobody hears about the failure.
- **Callouts** — with Named Credentials that use an External Credential, the user who started the job needs a permission set granting access to its principal.
- **`with sharing` subclasses** — see only the records that user can see.

## Scheduling a job

Neither handler implements `Schedulable`, and that's intentional: Setup's own **Schedule Apex** UI can only launch a class that implements `Schedulable` with a public no-argument constructor, and most real Batch/Queueable subclasses take constructor arguments (a filter, a starting Id, a list of records) that UI has no way to supply. Baking `Schedulable` into the base classes would only actually work for the narrow case of a job that needs nothing at all.

Instead, write a tiny `Schedulable` wrapper per job that needs a real cron schedule, and have it call `run()` with whatever arguments that job needs:

```apex
public class NormalizeContactEmailsScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        QueueableApexHandler.run(new NormalizeContactEmailsQueueable());
    }
}
```

```apex
System.schedule('Normalize Contact Emails Nightly', '0 0 2 * * ?', new NormalizeContactEmailsScheduler());
```

This keeps the scheduling concern (when, and with what fixed inputs) separate from the job's own logic, and works identically for a Batch or a Queueable subclass.

## Testing your own jobs

If you write your own `BatchApexHandler`/`QueueableApexHandler` subclass and want to unit test its retry or failure-email path, you'll run into the same platform quirks `BatchApexHandlerTest`/`QueueableApexHandlerTest` already work around in this repo:

1. **A `Database.Batchable` implementer must be a top-level class.** If your test needs a purpose-built Batch subclass to drive a scenario, it has to be its own top-level `@isTest` class — an inner class compiles but can't be reliably executed via `Database.executeBatch`.
2. **In test context, if a Batch's only `execute()` call throws, `finish()` never runs**, and only one `Database.executeBatch` call is allowed per test method — so you can't trigger a real retry chain by making `executeScope()` throw for real. Test the retry/completion decision directly instead: `BatchApexHandler` exposes `protected void handleFinish(Integer numberOfErrors)` for exactly this — call it from a test-only subclass method, the same way `BatchApexHandlerTestBatch.invokeHandleFinishForTest` does.
3. **In a test, a Queueable's exception surfaces at `Test.stopTest()`**, and the rollback and Failed status can't be observed there. Test the completion decision directly instead: `QueueableApexHandler.handleCompletion(Boolean failed, String errorMessage)` is `@TestVisible`, and `QueueableApexHandlerTest` shows how to drive the finalizer itself with a fake `System.FinalizerContext`.
4. **A governor limit error can't be caught in a test** either, so a test can't simulate one end to end. The finalizer handles it the same way as any other failure, which is verified in a real org.

## What you should NOT do

- Don't write `executeScope()`/`executeJob()` as non-idempotent if `Max_Retry_Attempts__c` is anything above 0 — see [Retry behavior and idempotency](#retry-behavior-and-idempotency) above.
- Don't set `Max_Retry_Attempts__c` expecting more than 10 attempts — it's hard-clamped in code regardless of what the record says.
- Don't point Setup's **Schedule Apex** UI at a subclass that needs constructor arguments — it can't supply them. Use a small `Schedulable` wrapper instead.
- Don't assume `Notification_Emails__c` or `Org_Wide_Email_Address_Id__c` will tell you if either is misconfigured — a malformed address, or an org-wide address Id that doesn't correspond to a real verified address, fails silently into a debug log line, not into the job's own success/failure state.
- Don't leave `Org_Wide_Email_Address_Id__c` blank and assume `Notification_Emails__c` alone is enough — see [Failure emails](#failure-emails) above for why sending as the running user instead can fail outright in a Batch/Queueable context.
- Don't try to create a second `Async_Job_Configuration__mdt` record for the same `Class_Name__c` — the field is unique, so the save/deploy is rejected outright.
- Don't catch every exception inside your own `executeJob()` just to keep the job "green". Let it propagate: the finalizer rolls the attempt back, retries it, and reports it. Catching it keeps half-done work and hides the failure.
- Don't start one Queueable per record from a trigger. Pass all the records to one job — `run()` refuses past the per-transaction limit.
- Don't assume `finish()` is guaranteed to run in every conceivable Batch failure scenario — if an extreme majority of a real job's chunks fail, the platform itself can abort the job early. If a configured failure email doesn't show up when you expect one, check Setup → Apex Jobs for a job stuck in "Failed" status rather than assuming the framework silently swallowed it.
