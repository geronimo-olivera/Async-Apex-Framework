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
        jobClassName = AsyncJobHandlerHelper.resolveClassName(this);
        config = AsyncJobConfigurationService.getConfigurationByClassName(jobClassName);
        settings = AsyncJobHandlerHelper.resolveSettings(config);
    }

    /**
     * Called once, after the attempt that actually completes (the last retry, or the first attempt if
     * it succeeded or retry isn't configured). Override for cleanup, notifications, or chaining another
     * job. Default is a no-op.
     * @param hadErrors Whether the completing attempt ultimately had one or more failures.
     */
    protected virtual void onFinish(Boolean hadErrors) {
    }
}
