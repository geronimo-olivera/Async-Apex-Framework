# Async Apex Framework

A metadata-driven Apex framework for Salesforce that removes the repetitive boilerplate around Batch Apex and Queueable Apex — active/inactive control, configurable batch size, automatic retry, and failure-email notifications, all driven by a single `Async_Job_Configuration__mdt` custom metadata type shared by both. Extend `BatchApexHandler` or `QueueableApexHandler`, implement the one or two methods that actually do your work, and launch it through `run()`.

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png)](https://githubsfdeploy.herokuapp.com?owner=geronimo-olivera&repo=Async-Apex-Framework&ref=master)

## Purpose

Batch and Queueable Apex classes tend to end up with the same handful of concerns copy-pasted into every one of them: an active/inactive switch so you can turn a job off without a deploy, a retry-on-failure loop, and a "notify someone if this ultimately fails" email. The goal of this framework is:

- **Configuration over code** — active flag, batch size, retry count, retry delay, and failure email all live in `Async_Job_Configuration__mdt` records, one per class. A class with no configuration record runs with sane defaults; nothing requires a record to exist.
- **One shared base, two genuinely different subclasses** — `AsyncJobHandlerBase` resolves a class's own configuration once and holds the state and `onFinish` hook both patterns need. `BatchApexHandler` and `QueueableApexHandler` each implement only the retry/completion logic that's actually different between the two — that logic is **not** unified, on purpose (see [Why Batch and Queueable handle failures differently](docs/USAGE.md#why-batch-and-queueable-handle-failures-differently) in the usage doc).
- **Built-in retry, with the cost made explicit** — either framework can automatically retry a failed job (capped at 10 attempts, regardless of what's configured), right away or after a delay of up to 10 minutes. A retry always reprocesses everything from scratch, not just what failed — see [Retry behavior and idempotency](docs/USAGE.md#retry-behavior-and-idempotency).
- **Queueable failures handled by a Transaction Finalizer** — a failed attempt is rolled back, governor limit errors are retried and reported like any other failure, and a failed job shows as Failed in Setup → Apex Jobs.
- **Works for every user** — the configuration is read with `getAll()`, so a standard user can start a job, for example by saving a record whose trigger starts it.
- **Failure emails with multiple recipients** — check a box, list one or more semicolon-separated addresses, get notified once a job (after retries) still failed.
- **Platform behavior confirmed against a real org, not assumed** — several of the less obvious facts baked into this framework's design (why a Batch subclass can't be an inner class, how a genuine retry has to be tested, and the three Queueable problems the finalizer fixes) were verified by actually deploying and running diagnostic code, not taken from documentation alone. See [docs/USAGE.md](docs/USAGE.md) for all of it, including easy and advanced worked examples for both Batch and Queueable.

## Contents

- [`force-app/main/default/classes/AsyncJobHandlerBase.cls`](force-app/main/default/classes/AsyncJobHandlerBase.cls) — shared abstract base. Resolves the concrete subclass's own `Async_Job_Configuration__mdt` record once, exposes the resolved settings and a retry counter, and declares the `onFinish` hook. Holds no retry/execution logic itself.
- [`force-app/main/default/classes/AsyncJobHandlerHelper.cls`](force-app/main/default/classes/AsyncJobHandlerHelper.cls) — static logic shared by both handlers: resolving a subclass's own class name, applying the configuration's defaults, parsing a semicolon-separated recipient list, and sending the failure email.
- [`force-app/main/default/classes/AsyncJobConfigurationService.cls`](force-app/main/default/classes/AsyncJobConfigurationService.cls) — read-only access to `Async_Job_Configuration__mdt`.
- [`force-app/main/default/classes/BatchApexHandler.cls`](force-app/main/default/classes/BatchApexHandler.cls) — extend this and implement `getQueryLocator()`/`executeScope()` instead of `Database.Batchable` directly.
- [`force-app/main/default/classes/QueueableApexHandler.cls`](force-app/main/default/classes/QueueableApexHandler.cls) — extend this and implement `executeJob()` instead of `Queueable` directly. Add `Database.AllowsCallouts` to your own subclass if it needs one. Its `CompletionFinalizer` handles success, retry and final failure.
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
| `Retry_Delay_Minutes__c` | Number | Minutes to wait before each retry, 0 to 10. Blank or 0 retries right away. Queueable retries use `System.enqueueJob` with a delay; Batch retries use `System.scheduleBatch`. |
| `Send_Email_On_Failure__c` | Checkbox | If `true`, sends a failure email once the job (after any configured retries) still failed. |
| `Notification_Emails__c` | Long Text Area | One address, or several separated by semicolons (`first@x.com; second@x.com`). Required whenever `Send_Email_On_Failure__c` is checked (enforced by a validation rule). |
| `Org_Wide_Email_Address_Id__c` | Text | Id of a verified Organization-Wide Email Address (Setup → Organization-Wide Email Addresses) to send the failure email from. Required whenever `Send_Email_On_Failure__c` is checked (enforced by a validation rule) — **the email can fail to send without it**, since without an explicit org-wide address `Messaging.sendEmail` falls back to the running user's own address, which can throw `INVALID_SENDER` in a Batch/Queueable context. |

Four validation rules enforce the dependencies above: `Batch_Size_Requires_Batch_Type`, `Send_Email_Requires_Address`, `Send_Email_Requires_Org_Wide_Address`, and `Retry_Delay_Within_Range`.

## Tests

`BatchApexHandlerTest` (plus its companion top-level class `BatchApexHandlerTestBatch`) and `QueueableApexHandlerTest` run 20 tests: success, inactive configuration, failure, retries left and exhausted, delayed retries, failure emails, the finalizer reading a success and a failure, the per-transaction enqueue limit, configuration matched by class name or `getJobName()`, a full chunk of 200 records, and a standard user starting both kinds of job. Coverage is 100% on `QueueableApexHandler`, `AsyncJobHandlerHelper` and `AsyncJobConfigurationService`, and 88% on `BatchApexHandler` (the uncovered lines wrap Salesforce's "flex queue full" error, which a test can't trigger) and `AsyncJobHandlerBase` (the default `onFinish` no-op). They pass in a clean scratch org and in an org with existing configuration.

Some things a unit test can't observe, because test code runs async jobs inside the test's own transaction: the rollback of a failed Queueable, its Failed status, a governor limit error, and real retry chains. Those were checked end to end in a scratch org instead.

### Tested end to end

Example jobs ran in a scratch org through real triggers and anonymous Apex, with retries configured and a 1-minute retry delay:

| Scenario | Result |
|---|---|
| Queueable that succeeds | Ran once, `onFinish(false)` |
| Queueable that fails once | First attempt rolled back and shown as Failed, retry succeeded, `onFinish(false)` |
| Queueable that always fails after saving data | Every attempt rolled back (nothing saved), 2 retries after 1 minute each, `onFinish(true)` |
| Queueable that hits "Too many SOQL queries" | Retried twice and reported with `onFinish(true)`. Before the finalizer, this job failed with no retry, email or `onFinish` |
| Queueable over 2,000 records | All 2,000 processed |
| Batch over 5,000 records, first chunk failing once | The failed chunk rolled back, the job retried, all 5,000 processed, `onFinish(false)` |
| Standard user saving a record that starts a Queueable | Job ran as that user, recovered from its first failure |

To run the unit tests in a scratch org:

```bash
sf org create scratch --definition-file config/project-scratch-def.json --alias async --duration-days 1 --target-dev-hub <your-dev-hub>
sf project deploy start --manifest manifest/package.xml --target-org async
sf apex run test --target-org async --test-level RunLocalTests --code-coverage --wait 20
```

See [Testing your own jobs](docs/USAGE.md#testing-your-own-jobs) in the usage doc if you're extending this framework and want to unit test your own subclass's retry or failure-email behavior.

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

- [`docs/USAGE.md`](docs/USAGE.md) — permissions, limits checked for you, creating a configuration record, easy and advanced worked examples for both Batch and Queueable (dynamic SOQL, callouts, chaining), retry behavior and why your job logic needs to be idempotent, why Batch and Queueable handle failures differently, failure emails, scheduling a job without Setup's "Schedule Apex" UI, testing your own jobs, and what to avoid.

## License

Released under the [MIT License](LICENSE).
