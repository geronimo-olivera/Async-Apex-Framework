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
      <values><field>Send_Email_On_Failure__c</field><value xsi:type="xsd:boolean">true</value></values>
      <values><field>Notification_Emails__c</field><value xsi:type="xsd:string">ops@example.com; oncall@example.com</value></values>
  </CustomMetadata>
  ```

`Class_Name__c` is unique — you can't create two configuration records for the same class, so there's no ambiguity about which one applies.

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

Both handlers can automatically retry a failed job, capped at 10 attempts regardless of what `Max_Retry_Attempts__c` says. What "retry" means is more aggressive than it sounds:

- **Batch**: a retry calls `getQueryLocator()` again from scratch and reprocesses **every** matching record — including the ones that already succeeded on the failed attempt. The retry check is at the whole-job level (`AsyncApexJob.NumberOfErrors > 0`), not per chunk.
- **Queueable**: a retry re-runs `executeJob()` from scratch, on the same instance, with the same constructor state it started with.

Neither one tracks "what already succeeded" for you. If `executeScope()`/`executeJob()` does anything that isn't safe to repeat — an external callout, sending an email, incrementing a counter — a retry after a partial failure can double it. Write your job logic so it's safe to run again on records it already touched:

- Prefer `upsert` keyed by an external Id over `insert`, so a repeat run updates instead of duplicating.
- Check a status field before acting (`if (record.Status__c != 'Synced') { ... }`) so an already-processed record is a no-op the second time.
- For callouts to a system you don't control, use an idempotency key if the API supports one, or make the callout itself a query-then-act pattern instead of a blind POST.

## Why Batch and Queueable retry differently

`BatchApexHandler.execute()` catches the subclass's exception, logs it, and **re-throws** it. That's deliberate — `AsyncApexJob.NumberOfErrors` (what `finish()` checks to decide whether to retry) only increments when an exception actually escapes `execute()`. Swallowing it there would silently disable retry.

`QueueableApexHandler.execute()` **never** re-throws, even after retries are exhausted — also deliberate, and verified against a real org rather than assumed: enqueueing a retry with `System.enqueueJob(this)` and then letting the original exception propagate rolls back that enqueue along with the rest of the failing transaction. A chained job enqueued right before a throw never actually runs. So a Queueable job that ultimately fails always shows as "Completed" in Setup → Apex Jobs; failure visibility comes from debug logs and the optional email, never from the job's own status.

## Failure emails

Check `Send_Email_On_Failure__c` and set one or more semicolon-separated addresses in `Notification_Emails__c` (`first@x.com; second@x.com`) — a validation rule requires the address field whenever the checkbox is set. The email fires once, after the job (following any configured retries) still has errors.

A malformed address doesn't block your job from running and doesn't throw — `AsyncJobHandlerHelper.sendFailureEmail` catches that internally and only logs it (`System.debug(LoggingLevel.ERROR, 'Failed to send failure notification for ...')`), on purpose, so a typo in a notification address can never take down the actual record processing. The tradeoff is that nothing else tells you the notification silently failed — if you suspect a configured email isn't arriving, check debug logs for that exact line before assuming the job itself is fine.

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

If you write your own `BatchApexHandler`/`QueueableApexHandler` subclass and want to unit test its retry or failure-email path, you'll run into the same three platform quirks `BatchApexHandlerTest`/`QueueableApexHandlerTest` already work around in this repo:

1. **A `Database.Batchable` implementer must be a top-level class.** If your test needs a purpose-built Batch subclass to drive a scenario, it has to be its own top-level `@isTest` class — an inner class compiles but can't be reliably executed via `Database.executeBatch`.
2. **In test context, if a Batch's only `execute()` call throws, `finish()` never runs**, and only one `Database.executeBatch` call is allowed per test method — so you can't trigger a real retry chain by making `executeScope()` throw for real. Test the retry/completion decision directly instead: `BatchApexHandler` exposes `protected void handleFinish(Integer numberOfErrors)` for exactly this — call it directly from a test-only subclass method with whatever error count you want to simulate, the same way `BatchApexHandlerTestBatch.invokeHandleFinishForTest` does.
3. **A chained `System.enqueueJob(this)` retry runs in its own transaction.** If your test needs to assert something governor-limit-based (like `Limits.getEmailInvocations()`) about the exhausted-retry path, pre-set the retry counter (expose a small test-only setter for `retryAttempt`, like `QueueableApexHandlerTest.TestQueueable.setRetryAttemptForTest` does) so the path you're testing runs synchronously in the same transaction as your assertion, instead of relying on a genuine chained failure to get there.

## What you should NOT do

- Don't write `executeScope()`/`executeJob()` as non-idempotent if `Max_Retry_Attempts__c` is anything above 0 — see [Retry behavior and idempotency](#retry-behavior-and-idempotency) above.
- Don't set `Max_Retry_Attempts__c` expecting more than 10 attempts — it's hard-clamped in code regardless of what the record says.
- Don't point Setup's **Schedule Apex** UI at a subclass that needs constructor arguments — it can't supply them. Use a small `Schedulable` wrapper instead.
- Don't assume `Notification_Emails__c` will tell you if it's misconfigured — a malformed address fails silently into a debug log line, not into the job's own success/failure state.
- Don't try to create a second `Async_Job_Configuration__mdt` record for the same `Class_Name__c` — the field is unique, so the save/deploy is rejected outright.
- Don't assume a Queueable job's Setup → Apex Jobs status reflects whether it actually failed — it always shows "Completed" by design, even after exhausting retries. Check debug logs or the failure email instead.
- Don't assume `finish()` is guaranteed to run in every conceivable Batch failure scenario — if an extreme majority of a real job's chunks fail, the platform itself can abort the job early. If a configured failure email doesn't show up when you expect one, check Setup → Apex Jobs for a job stuck in "Failed" status rather than assuming the framework silently swallowed it.
