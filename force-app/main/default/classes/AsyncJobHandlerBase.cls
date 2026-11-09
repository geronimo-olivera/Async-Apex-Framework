/**
 * File Name   :	AsyncJobHandlerBase.cls
 * Description :	Shared setup for BatchApexHandler and QueueableApexHandler: resolves this class's own
 *                  Async_Job_Configuration__mdt record once, exposes it and the derived Settings to
 *                  subclasses, and holds the retry counter and onFinish hook both frameworks expose.
 *                  Retry and completion logic is intentionally NOT shared here — Batch and Queueable
 *                  behave differently there by design (see each subclass's header for why) — this only
 *                  removes the identical constructor/field boilerplate the two used to duplicate.
 **/
public abstract class AsyncJobHandlerBase {

    protected String jobClassName;
    protected Async_Job_Configuration__mdt config;
    protected AsyncJobHandlerHelper.Settings settings;
    protected Integer retryAttempt = 0;

    protected AsyncJobHandlerBase() {
        jobClassName = getJobName();
        config = AsyncJobConfigurationService.getConfigurationByClassName(jobClassName);
        settings = AsyncJobHandlerHelper.resolveSettings(config);
    }

    /**
     * The name this job's Async_Job_Configuration__mdt record is matched by, and the name used in logs and emails.
     * Defaults to the class name, detected from the instance. Override it if your class overrides toString(), since
     * the detection relies on Apex's default toString().
     * @return the job's name.
     */
    protected virtual String getJobName() {
        return AsyncJobHandlerHelper.resolveClassName(this);
    }

    /**
     * Called once, after the attempt that actually completes (the last retry, or the first attempt if
     * it succeeded or retry isn't configured). Override for cleanup, notifications, or chaining another
     * job. Default is a no-op.
     * @param hadErrors Whether the completing attempt ultimately had one or more failures.
     */
    protected virtual void onFinish(Boolean hadErrors) {
    }

    /**
     * Thrown when a job can't be started, with a message that says why and what to do.
     */
    public class AsyncJobException extends Exception {}
}
