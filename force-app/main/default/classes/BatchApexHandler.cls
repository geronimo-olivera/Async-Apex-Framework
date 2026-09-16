/**
 * File Name   :	BatchApexHandler.cls
 * Description :	Base class for batch jobs. Extend it and implement getQueryLocator/executeScope
 *                  instead of Database.Batchable directly. Configuration resolution (batch size, active
 *                  flag, retry count, failure email) and the onFinish hook come from AsyncJobHandlerBase,
 *                  shared with QueueableApexHandler. Handles consistent error logging around each scope,
 *                  automatic re-enqueue on failure, and an optional email notification once a job
 *                  ultimately finishes with errors. Launch with BatchApexHandler.run(new YourBatch())
 *                  instead of Database.executeBatch, so the active/inactive check and configured batch
 *                  size are applied.
 *
 *                  A retry re-runs getQueryLocator() from scratch and reprocesses every matching record,
 *                  not just the ones that failed — executeScope() must be safe to run again on records it
 *                  already succeeded on (e.g. upsert by external Id, or check a status field first).
 **/
public abstract class BatchApexHandler extends AsyncJobHandlerBase implements Database.Batchable<SObject>, Database.Stateful {

    private static final Integer DEFAULT_BATCH_SIZE = 200;

    protected Integer batchSize;

    protected BatchApexHandler() {
        Integer rawBatchSize = config != null && config.Batch_Size__c != null ? Integer.valueOf(config.Batch_Size__c) : DEFAULT_BATCH_SIZE;
        batchSize = Math.min(2000, Math.max(1, rawBatchSize));
    }

    /**
     * Enqueues a batch through its own configuration instead of calling Database.executeBatch directly,
     * so Async_Job_Configuration__mdt's active flag and batch size are respected.
     * @param batchInstance The batch to run.
     * @return the enqueued job's Id, or null if Is_Active__c is false for this class.
     */
    public static Id run(BatchApexHandler batchInstance) {
        if (!batchInstance.settings.isActive) {
            System.debug(LoggingLevel.INFO, 'Async_Job_Configuration__mdt for ' + batchInstance.jobClassName + ' is inactive; skipping.');
            return null;
        }
        return Database.executeBatch(batchInstance, batchInstance.batchSize);
    }

    /**
     * @param bc The batch's context. Unused directly; provided by the platform.
     * @return the query locator this batch iterates over.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return getQueryLocator();
    }

    /**
     * Runs the subclass's scope logic, logging and re-throwing on failure so the platform's own
     * per-job error count (and this class's retry check in finish) stays accurate.
     * @param bc The batch's context. Unused directly; provided by the platform.
     * @param scope The records for this chunk.
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        try {
            executeScope(scope);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Batch ' + jobClassName + ' failed on a scope of ' + scope.size() + ' record(s): ' + ex.getMessage());
            throw ex;
        }
    }

    /**
     * @param bc The batch's context, used to look up the finished job's error count.
     */
    public void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [SELECT NumberOfErrors FROM AsyncApexJob WHERE Id = :bc.getJobId()];
        handleFinish(job.NumberOfErrors);
    }

    /**
     * Re-enqueues this same batch if the job finished with errors and retries remain; otherwise sends
     * the configured failure email and calls the subclass's onFinish hook exactly once, for the attempt
     * that actually completes. Split out from finish() so this decision logic is directly testable
     * without a live Database.BatchableContext, which test code cannot construct.
     * @param numberOfErrors The number of failed records the completed attempt reported.
     */
    protected void handleFinish(Integer numberOfErrors) {
        Boolean hadErrors = numberOfErrors > 0;
        if (hadErrors && retryAttempt < settings.maxRetryAttempts) {
            retryAttempt++;
            System.debug(LoggingLevel.WARN, 'Batch ' + jobClassName + ' finished with ' + numberOfErrors + ' error(s); retry attempt ' + retryAttempt + ' of ' + settings.maxRetryAttempts + '.');
            Database.executeBatch(this, batchSize);
            return;
        }
        if (hadErrors) {
            String body = 'The batch job ' + jobClassName + ' finished with ' + numberOfErrors + ' failed record(s)' +
                (retryAttempt > 0 ? ' after ' + retryAttempt + ' retry attempt(s).' : '.') +
                ' Check debug logs for details.';
            AsyncJobHandlerHelper.sendFailureEmail(jobClassName, settings, 'Batch job failed: ' + jobClassName, body);
        }
        onFinish(hadErrors);
    }

    /**
     * @return the query locator to iterate over. This is what you'd normally write in start().
     */
    protected abstract Database.QueryLocator getQueryLocator();

    /**
     * @param scope The records for this chunk. This is what you'd normally write in execute().
     */
    protected abstract void executeScope(List<SObject> scope);
}
