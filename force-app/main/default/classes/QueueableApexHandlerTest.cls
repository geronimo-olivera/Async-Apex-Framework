@isTest
private class QueueableApexHandlerTest {

    static Integer executeCount = 0;
    static Integer failThroughAttempt = 0;
    static Boolean finishCalled = false;
    static Boolean lastHadErrors = false;

    @isTest
    static void testDefaultsWhenNoConfigExists() {
        TestQueueable job = new TestQueueable();

        Test.startTest();
        Id jobId = QueueableApexHandler.run(job);
        Test.stopTest();

        Assert.isNotNull(jobId, 'a class with no configuration record still runs');
        Assert.areEqual(1, executeCount, 'executeJob ran once');
        Assert.isTrue(finishCalled, 'onFinish ran');
        Assert.isFalse(lastHadErrors, 'no errors were simulated');
    }

    @isTest
    static void testInactiveConfigSkipsEnqueue() {
        TestQueueable job = new TestQueueable();
        job.configureForTest(false, 0, false, null, null);

        Id jobId = QueueableApexHandler.run(job);

        Assert.isNull(jobId, 'an inactive class does not get enqueued');
        Assert.areEqual(0, executeCount, 'a skipped job never reaches executeJob');
    }

    @isTest
    static void testDefaultMaxRetryIsZeroSoFailureIsImmediateAndJobStillCompletes() {
        failThroughAttempt = 1;
        TestQueueable job = new TestQueueable();

        Test.startTest();
        Id jobId = QueueableApexHandler.run(job);
        Test.stopTest();

        Assert.areEqual(1, executeCount, 'no retry is configured by default, so only the first attempt runs');
        Assert.isTrue(finishCalled, 'onFinish ran');
        Assert.isTrue(lastHadErrors, 'the simulated failure surfaces as an error');
        AsyncApexJob asyncJob = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', asyncJob.Status, 'execute() never re-throws, so the job shows Completed even though it failed internally');
    }

    @isTest
    static void testRetrySucceedsOnSecondAttempt() {
        failThroughAttempt = 1;
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 2, false, null, null);

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(2, executeCount, 'the first attempt fails, the retry succeeds');
        Assert.isTrue(finishCalled, 'onFinish ran once the retry completed');
        Assert.isFalse(lastHadErrors, 'the completing attempt had no errors');
    }

    @isTest
    static void testRetryExhaustedSendsFailureEmailToMultipleRecipients() {
        failThroughAttempt = 99;
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 1, true, 'first@example.com; second@example.com', null);
        job.setRetryAttemptForTest(1);
        Integer emailsBefore = Limits.getEmailInvocations();

        job.execute(null);

        Assert.areEqual(1, executeCount, 'the single direct call runs and fails since retries are already exhausted');
        Assert.isTrue(finishCalled, 'onFinish ran once retries were exhausted');
        Assert.isTrue(lastHadErrors, 'the completing attempt still had errors');
        Assert.areEqual(emailsBefore + 1, Limits.getEmailInvocations(), 'the configured failure email is sent exactly once');
    }

    @isTest
    static void testInvalidNotificationAddressDoesNotBreakProcessing() {
        failThroughAttempt = 99;
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 0, true, 'not-an-email', '0D8000000000000AAA');

        job.execute(null);

        Assert.isTrue(finishCalled, 'onFinish still ran even though the notification email is malformed');
        Assert.isTrue(lastHadErrors, 'the failure is still recorded correctly');
    }

    public class TestQueueable extends QueueableApexHandler {

        void configureForTest(Boolean isActive, Integer maxRetryAttempts, Boolean sendEmailOnFailure, String notificationEmail, String orgWideEmailAddressId) {
            settings.isActive = isActive;
            settings.maxRetryAttempts = maxRetryAttempts;
            settings.sendEmailOnFailure = sendEmailOnFailure;
            settings.notificationEmail = notificationEmail;
            settings.orgWideEmailAddressId = orgWideEmailAddressId;
        }

        void setRetryAttemptForTest(Integer value) {
            retryAttempt = value;
        }

        protected override void executeJob() {
            executeCount++;
            if (executeCount <= failThroughAttempt) {
                throw new DmlException('Simulated failure.');
            }
        }

        protected override void onFinish(Boolean hadErrors) {
            finishCalled = true;
            lastHadErrors = hadErrors;
        }
    }
}
