# Async Apex Framework

A metadata-driven Apex framework for Salesforce that removes the repetitive boilerplate around Batch Apex and Queueable Apex — active/inactive control, configurable batch size, automatic retry, and failure-email notifications, all driven by a single `Async_Job_Configuration__mdt` custom metadata type shared by both. Extend `BatchApexHandler` or `QueueableApexHandler`, implement the one or two methods that actually do your work, and launch it through `run()`.

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png)](https://githubsfdeploy.herokuapp.com?owner=geronimo-olivera&repo=Async-Apex-Framework&ref=master)

## Purpose

Batch and Queueable Apex classes tend to end up with the same handful of concerns copy-pasted into every one of them: an active/inactive switch so you can turn a job off without a deploy, a retry-on-failure loop, and a "notify someone if this ultimately fails" email. The goal of this framework is:

- **Configuration over code** — active flag, batch size, retry count, and failure email all live in `Async_Job_Configuration__mdt` records, one per class. A class with no configuration record runs with sane defaults; nothing requires a record to exist.
- **One shared base, two genuinely different subclasses** — `AsyncJobHandlerBase` resolves a class's own configuration once and holds the state and `onFinish` hook both patterns need. `BatchApexHandler` and `QueueableApexHandler` each implement only the retry/completion logic that's actually different between the two — that logic is **not** unified, on purpose (see [Why Batch and Queueable retry differently](docs/USAGE.md#why-batch-and-queueable-retry-differently) in the usage doc).
- **Built-in retry, with the cost made explicit** — either framework can automatically retry a failed job (capped at 10 attempts, regardless of what's configured). A retry always reprocesses everything from scratch, not just what failed — see [Retry behavior and idempotency](docs/USAGE.md#retry-behavior-and-idempotency).
- **Failure emails with multiple recipients** — check a box, list one or more semicolon-separated addresses, get notified once a job (after retries) still failed.
- **Platform behavior confirmed against a real org, not assumed** — several of the less obvious facts baked into this framework's design (why `QueueableApexHandler.execute()` never re-throws, why a Batch subclass can't be an inner class, how a genuine retry has to be tested) were verified by actually deploying and running diagnostic code, not taken from documentation alone. See [docs/USAGE.md](docs/USAGE.md) for all of it, including easy and advanced worked examples for both Batch and Queueable.

## Contents

- [`force-app/main/default/classes/AsyncJobHandlerBase.cls`](force-app/main/default/classes/AsyncJobHandlerBase.cls) — shared abstract base. Resolves the concrete subclass's own `Async_Job_Configuration__mdt` record once, exposes the resolved settings and a retry counter, and declares the `onFinish` hook. Holds no retry/execution logic itself.
- [`force-app/main/default/classes/AsyncJobHandlerHelper.cls`](force-app/main/default/classes/AsyncJobHandlerHelper.cls) — static logic shared by both handlers: resolving a subclass's own class name, applying the configuration's defaults, parsing a semicolon-separated recipient list, and sending the failure email.
- [`force-app/main/default/classes/AsyncJobConfigurationService.cls`](force-app/main/default/classes/AsyncJobConfigurationService.cls) — read-only access to `Async_Job_Configuration__mdt`.
- [`force-app/main/default/classes/BatchApexHandler.cls`](force-app/main/default/classes/BatchApexHandler.cls) — extend this and implement `getQueryLocator()`/`executeScope()` instead of `Database.Batchable` directly.
- [`force-app/main/default/classes/QueueableApexHandler.cls`](force-app/main/default/classes/QueueableApexHandler.cls) — extend this and implement `executeJob()` instead of `Queueable` directly. Add `Database.AllowsCallouts` to your own subclass if it needs one.
- [`force-app/main/default/classes/BatchApexHandlerTest.cls`](force-app/main/default/classes/BatchApexHandlerTest.cls) and [`BatchApexHandlerTestBatch.cls`](force-app/main/default/classes/BatchApexHandlerTestBatch.cls) — test coverage for `BatchApexHandler`. The second file is a one-method top-level class, not a mock — see [Tests](#tests) below for why it has to exist as its own file.
- [`force-app/main/default/classes/QueueableApexHandlerTest.cls`](force-app/main/default/classes/QueueableApexHandlerTest.cls) — test coverage for `QueueableApexHandler`, including its own test-only subclass as an inner class (Queueable, unlike Batch, has no restriction against that).
- [`force-app/main/default/objects/Async_Job_Configuration__mdt/`](force-app/main/default/objects/Async_Job_Configuration__mdt) — the custom metadata type, its fields, and its validation rules. This repo ships the type only — no records. Your jobs' configuration is your own org's setup; see [docs/USAGE.md](docs/USAGE.md) for how to create one.
- [`force-app/main/default/layouts/`](force-app/main/default/layouts) — the CMDT's page layout.

## Custom metadata: `Async_Job_Configuration__mdt`

One record per `BatchApexHandler` or `QueueableApexHandler` subclass, matched automatically at runtime by class name. Entirely optional — a class with no record runs active, with no retry and no batch-size override.

| Field | Type | Description |
|---|---|---|
| `Class_Name__c` | Text (required, unique) | API name of the `BatchApexHandler`/`QueueableApexHandler` subclass this record configures. |
| `Job_Type__c` | Picklist (required) | `Batch` or `Queueable`. Not read by either framework class at runtime — the class itself already determines that — it's here purely so Setup's list view is scannable and filterable. |
| `Is_Active__c` | Checkbox | Defaults to `true`. If `false`, `run()` skips the job instead of enqueuing it. |
| `Batch_Size__c` | Number | Only meaningful when `Job_Type__c` is `Batch`. Blank defaults to 200; always clamped to the platform's own 1–2000 range regardless of what's entered. |
| `Max_Retry_Attempts__c` | Number | How many times to automatically retry after a failure. Blank or 0 disables retry. Capped at 10 regardless of what's entered. |
| `Send_Email_On_Failure__c` | Checkbox | If `true`, sends a failure email once the job (after any configured retries) still failed. |
| `Notification_Emails__c` | Long Text Area | One address, or several separated by semicolons (`first@x.com; second@x.com`). Required whenever `Send_Email_On_Failure__c` is checked (enforced by a validation rule). |
| `Org_Wide_Email_Address_Id__c` | Text | Id of a verified Organization-Wide Email Address (Setup → Organization-Wide Email Addresses) to send the failure email from. Required whenever `Send_Email_On_Failure__c` is checked (enforced by a validation rule) — **the email can fail to send without it**, since without an explicit org-wide address `Messaging.sendEmail` falls back to the running user's own address, which can throw `INVALID_SENDER` in a Batch/Queueable context. |

Three validation rules enforce the dependencies above: `Batch_Size_Requires_Batch_Type`, `Send_Email_Requires_Address`, and `Send_Email_Requires_Org_Wide_Address`.

## Tests

`BatchApexHandlerTest` (plus its companion top-level class `BatchApexHandlerTestBatch`) and `QueueableApexHandlerTest` together reach **100% coverage on `BatchApexHandler`, `QueueableApexHandler`, `AsyncJobHandlerHelper`, and `AsyncJobConfigurationService`**, and 83% on `AsyncJobHandlerBase` (the one uncovered line is the default `onFinish` no-op body, which nothing calls without being overridden — covering it would mean shipping a subclass built only to not override a hook, which isn't worth the extra file).

Getting there required working around three real, empirically-confirmed Salesforce platform quirks, not just app logic:

1. **`Database.Batchable` can only be implemented by a top-level class.** An inner class that inherits the interface through an abstract base compiles fine but can't be reliably executed via `Database.executeBatch` at runtime. That's why `BatchApexHandlerTestBatch` exists as its own file instead of an inner class like `QueueableApexHandlerTest`'s test subclass — it's a platform constraint, not a design choice.
2. **In Apex test context, if a Batch's only `execute()` call throws an uncaught exception, `finish()` never runs at all** — confirmed directly, not assumed. Combined with the platform's own "no more than one `executeBatch` call per test method" restriction, this means a real retry chain (a second, internal `executeBatch` call triggered by `finish()`) can't be triggered by an actual failing `execute()` inside a single test method. `BatchApexHandler` exposes its retry/completion decision as a separate `handleFinish(Integer numberOfErrors)` method specifically so tests can drive it directly, without needing a live `Database.BatchableContext` (which test code can't construct anyway).
3. **A chained `System.enqueueJob(this)` retry runs in its own transaction**, with its own governor limits — a test asserting `Limits.getEmailInvocations()` after `Test.stopTest()` won't see an email sent from inside that chained transaction. `QueueableApexHandlerTest` works around this by pre-setting the retry counter so the exhausted-retry path (and its email) runs synchronously, in the same transaction as the assertion.

See [Testing your own jobs](docs/USAGE.md#testing-your-own-jobs) in the usage doc if you're extending this framework and want to unit test your own subclass's retry or failure-email behavior — you'll hit the exact same three walls.

## Deploy to an org

### One click

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png)](https://githubsfdeploy.herokuapp.com?owner=geronimo-olivera&repo=Async-Apex-Framework&ref=master)

Click the button, choose production or sandbox, and log in to the org. The deploy runs through [GitHub Salesforce Deploy](https://github.com/afawcett/githubsfdeploy), a free open-source tool by Andrew Fawcett. Try it in a sandbox first: a production deploy also runs your org's Apex tests.

### From VS Code

You need [VS Code with the Salesforce Extension Pack](https://developer.salesforce.com/tools/vscode/) and an authenticated org.

1. Clone this repo and open it in VS Code.
2. Authenticate to your target org (`SFDX: Authorize an Org`, or `sf org login web` from the CLI).
3. Right-click [`manifest/package.xml`](manifest/package.xml) and choose **SFDX: Deploy Source in Manifest to Org**.

That deploys both Apex handler base classes, `BatchApexHandler`, `QueueableApexHandler`, the shared helper and config service, both test classes, and the `Async_Job_Configuration__mdt` type with its fields, validation rules, and layout — everything except your own job classes and configuration records, which are yours to create. See [docs/USAGE.md](docs/USAGE.md) for both.

## Documentation

- [`docs/USAGE.md`](docs/USAGE.md) — creating a configuration record, easy and advanced worked examples for both Batch and Queueable (dynamic SOQL, callouts, chaining), retry behavior and why your job logic needs to be idempotent, why Batch and Queueable retry differently, failure emails, scheduling a job without Setup's "Schedule Apex" UI, testing your own jobs, and what to avoid.

## License

Released under the [MIT License](LICENSE).
