/**
 * File Name   :	QueueableApexHandler.cls
 * Description :	Base class for queueable jobs. Extend it and implement executeJob instead of
 *                  Queueable directly. Configuration resolution (active flag, retry count, retry delay, failure
 *                  email) and the onFinish hook come from AsyncJobHandlerBase, shared with BatchApexHandler.
 *                  Launch with QueueableApexHandler.run(new YourJob()) instead of System.enqueueJob, so the
 *                  active/inactive check is applied. Need callouts? Add "implements Database.AllowsCallouts" to
 *                  your subclass — this base class doesn't declare it, since not every job needs it.
 *
 *                  Failures are handled by a Transaction Finalizer, which Salesforce runs after the job ends
 *                  however it ended. That's what makes these three things work:
 *                  - A failure rolls back everything the job did, so a retry never starts from half-saved data.
 *                  - Governor limit errors (too many queries, CPU time), which no catch block can handle, are
 *                    retried and reported like any other failure.
 *                  - A failed job shows as Failed in Setup > Apex Jobs, with its error message.
 *
 *                  A retry re-runs executeJob() from scratch with the same constructor state. Callouts made before
 *                  the failure are not rolled back, so a job with callouts must still be safe to run again.
 **/
public abstract class QueueableApexHandler extends AsyncJobHandlerBase implements Queueable {

    /**
     * Enqueues a job through its own configuration instead of calling System.enqueueJob directly, so
     * Async_Job_Configuration__mdt's active flag is respected.
     * @param jobInstance The job to run.
     * @return the enqueued job's Id, or null if Is_Active__c is false for this class.
     * @throws AsyncJobException if this transaction already enqueued as many jobs as Salesforce allows.
     */
    public static Id run(QueueableApexHandler jobInstance) {
        if (!jobInstance.settings.isActive) {
            System.debug(LoggingLevel.INFO, 'Async_Job_Configuration__mdt for ' + jobInstance.jobClassName + ' is inactive; skipping.');
            return null;
        }
        return enqueue(jobInstance, 0);
    }

    /**
     * Runs the subclass's job logic under a finalizer that handles success, retry and final failure. Doesn't
     * catch anything: an exception rolls back the job's work and the finalizer takes it from there.
     * @param qc The job's context. Unused directly; provided by the platform.
     */
    public void execute(QueueableContext qc) {
        System.attachFinalizer(new CompletionFinalizer(this));
        executeJob();
    }

    /**
     * Decides what happens after an attempt: onFinish on success; another attempt while retries remain; the
     * failure email and onFinish once they're exhausted. Called by the finalizer, and directly by tests.
     * @param failed Whether the attempt ended with an unhandled exception.
     * @param errorMessage The exception's message, for the log and the email. Null on success.
     */
    @TestVisible
    private void handleCompletion(Boolean failed, String errorMessage) {
        if (!failed) {
            onFinish(false);
            return;
        }
        System.debug(LoggingLevel.ERROR, 'Queueable ' + jobClassName + ' failed: ' + errorMessage);
        if (retryAttempt < settings.maxRetryAttempts) {
            retryAttempt++;
            System.debug(LoggingLevel.WARN, 'Retrying ' + jobClassName + ', attempt ' + retryAttempt + ' of ' + settings.maxRetryAttempts + '.');
            enqueue(this, settings.retryDelayMinutes);
            return;
        }
        String body = 'The queueable job ' + jobClassName + ' failed' +
            (retryAttempt > 0 ? ' after ' + retryAttempt + ' retry attempt(s)' : '') +
            ': ' + errorMessage + '\n\nCheck Setup > Apex Jobs and the debug logs for details.';
        AsyncJobHandlerHelper.sendFailureEmail(jobClassName, settings, 'Queueable job failed: ' + jobClassName, body);
        onFinish(true);
    }

    /**
     * Enqueues the job, optionally delayed, after checking the transaction can still enqueue one.
     * @param jobInstance The job to enqueue.
     * @param delayMinutes Minutes to wait before it runs. 0 runs it as soon as possible.
     * @return the enqueued job's Id.
     */
    private static Id enqueue(QueueableApexHandler jobInstance, Integer delayMinutes) {
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            throw new AsyncJobException('Cannot enqueue ' + jobInstance.jobClassName + ': this transaction already enqueued ' +
                Limits.getQueueableJobs() + ' queueable job(s), the most Salesforce allows. Pass all the records to one job instead of starting one job per record.');
        }
        return delayMinutes > 0 ? System.enqueueJob(jobInstance, delayMinutes) : System.enqueueJob(jobInstance);
    }

    /**
     * This is what you'd normally write in execute(). Get whatever data you need from your own
     * constructor arguments — there's no scope/chunking concept here, unlike batch.
     */
    protected abstract void executeJob();

    /**
     * Runs after every attempt, in its own transaction, whether the job succeeded or threw — including errors
     * no catch block can handle, such as governor limits.
     */
    public class CompletionFinalizer implements System.Finalizer {
        private QueueableApexHandler job;

        public CompletionFinalizer(QueueableApexHandler job) {
            this.job = job;
        }

        public void execute(System.FinalizerContext context) {
            Boolean failed = context.getResult() == System.ParentJobResult.UNHANDLED_EXCEPTION;
            String errorMessage = failed && context.getException() != null ? context.getException().getMessage() : null;
            job.handleCompletion(failed, errorMessage);
        }
    }
}
