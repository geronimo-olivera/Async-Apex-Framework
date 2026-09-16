/**
 * File Name   :	QueueableApexHandler.cls
 * Description :	Base class for queueable jobs. Extend it and implement executeJob instead of
 *                  Queueable directly. Configuration resolution (active flag, retry count, failure
 *                  email) and the onFinish hook come from AsyncJobHandlerBase, shared with
 *                  BatchApexHandler. Handles consistent error logging, automatic re-enqueue on failure,
 *                  and an optional email notification once a job ultimately fails.
 *                  Launch with QueueableApexHandler.run(new YourJob()) instead of System.enqueueJob, so
 *                  the active/inactive check is applied. Need callouts? Add
 *                  "implements Database.AllowsCallouts" to your subclass — this base class doesn't
 *                  declare it, since not every job needs it.
 *
 *                  execute() never re-throws, even after retries are exhausted: enqueueing a retry and
 *                  then throwing loses the retry, since System.enqueueJob is rolled back along with the
 *                  rest of a transaction that later throws (verified against a real org — a chained job
 *                  enqueued right before a throw never actually runs). So a failed job always shows as
 *                  "Completed" in Setup > Apex Jobs; failure visibility comes from debug logs and the
 *                  optional email, not from the job's own status.
 *
 *                  A retry re-runs executeJob() from scratch with the same constructor state — it must
 *                  be safe to run again after a partial failure (e.g. a callout or a DML that already
 *                  went through before the exception was thrown).
 **/
public abstract class QueueableApexHandler extends AsyncJobHandlerBase implements Queueable {

    /**
     * Enqueues a job through its own configuration instead of calling System.enqueueJob directly, so
     * Async_Job_Configuration__mdt's active flag is respected.
     * @param jobInstance The job to run.
     * @return the enqueued job's Id, or null if Is_Active__c is false for this class.
     */
    public static Id run(QueueableApexHandler jobInstance) {
        if (!jobInstance.settings.isActive) {
            System.debug(LoggingLevel.INFO, 'Async_Job_Configuration__mdt for ' + jobInstance.jobClassName + ' is inactive; skipping.');
            return null;
        }
        return System.enqueueJob(jobInstance);
    }

    /**
     * Runs the subclass's job logic. On failure, retries (re-enqueuing this same instance) while
     * attempts remain; once they're exhausted, sends the configured failure email and calls onFinish.
     * Never re-throws — see the class-level note on why.
     * @param qc The job's context. Unused directly; provided by the platform.
     */
    public void execute(QueueableContext qc) {
        try {
            executeJob();
            onFinish(false);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Queueable ' + jobClassName + ' failed: ' + ex.getMessage());
            if (retryAttempt < settings.maxRetryAttempts) {
                retryAttempt++;
                System.debug(LoggingLevel.WARN, 'Retrying ' + jobClassName + ', attempt ' + retryAttempt + ' of ' + settings.maxRetryAttempts + '.');
                System.enqueueJob(this);
            } else {
                String body = 'The queueable job ' + jobClassName + ' failed' +
                    (retryAttempt > 0 ? ' after ' + retryAttempt + ' retry attempt(s)' : '') +
                    ': ' + ex.getMessage() + '\n\nCheck debug logs for the full stack trace.';
                AsyncJobHandlerHelper.sendFailureEmail(jobClassName, settings, 'Queueable job failed: ' + jobClassName, body);
                onFinish(true);
            }
        }
    }

    /**
     * This is what you'd normally write in execute(). Get whatever data you need from your own
     * constructor arguments — there's no scope/chunking concept here, unlike batch.
     */
    protected abstract void executeJob();
}
